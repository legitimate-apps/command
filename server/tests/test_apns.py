"""APNs sender (B4) — JWT construction + config gating. No network: real sends need a device."""

from __future__ import annotations

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from command.config import get_settings
from command.core import apns


@pytest.fixture
def apns_key(tmp_path, monkeypatch):
    # A throwaway P-256 key in PKCS#8 PEM (the same shape as Apple's .p8), so the JWT signing path
    # is exercised without the real auth key.
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    p8 = tmp_path / "AuthKey_TEST12345.p8"
    p8.write_bytes(pem)
    monkeypatch.setenv("COMMAND_APNS_KEY_PATH", str(p8))
    monkeypatch.setenv("COMMAND_APNS_KEY_ID", "TEST12345")
    monkeypatch.setenv("COMMAND_APNS_TEAM_ID", "TEAM123456")
    get_settings.cache_clear()
    apns.reset_jwt_cache()
    yield key.public_key()
    get_settings.cache_clear()
    apns.reset_jwt_cache()


def test_configured_reflects_settings(monkeypatch):
    monkeypatch.delenv("COMMAND_APNS_KEY_PATH", raising=False)
    get_settings.cache_clear()
    assert apns.configured() is False
    # A no-op send when unconfigured never raises.
    r = apns.send("tok", title="t", body="b")
    assert r.ok is False and r.reason == "apns_not_configured"
    get_settings.cache_clear()


def test_bearer_jwt_has_es256_kid_iss_and_verifies(apns_key):
    assert apns.configured() is True
    token = apns._bearer()
    header = jwt.get_unverified_header(token)
    assert header["alg"] == "ES256" and header["kid"] == "TEST12345"
    # Verify the signature with the matching public key and check the issuer claim.
    claims = jwt.decode(token, apns_key, algorithms=["ES256"], options={"verify_exp": False})
    assert claims["iss"] == "TEAM123456" and "iat" in claims
    # Cached: a second call returns the identical token.
    assert apns._bearer() == token



@pytest.mark.parametrize("flatten", [False, True], ids=["pem", "newlines-escaped"])
def test_key_contents_in_env_sign_without_a_file(monkeypatch, flatten: bool) -> None:
    # Railway and similar hosts have no files to mount: COMMAND_APNS_KEY carries the .p8 itself,
    # sometimes with its newlines flattened to a literal \n by the host's variable editor.
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    monkeypatch.delenv("COMMAND_APNS_KEY_PATH", raising=False)
    monkeypatch.setenv("COMMAND_APNS_KEY", pem.replace("\n", "\\n") if flatten else pem)
    monkeypatch.setenv("COMMAND_APNS_KEY_ID", "TEST12345")
    monkeypatch.setenv("COMMAND_APNS_TEAM_ID", "TEAM123456")
    get_settings.cache_clear()
    apns.reset_jwt_cache()
    try:
        assert apns.configured() is True
        claims = jwt.decode(
            apns._bearer(), key.public_key(), algorithms=["ES256"], options={"verify_exp": False}
        )
        assert claims["iss"] == "TEAM123456"
    finally:
        get_settings.cache_clear()
        apns.reset_jwt_cache()


# --- the send path: response handling drives whether a device token is DELETED ----------------
#
# `unregistered` is load-bearing, not informational: `reminder_job` and `briefing_job` call
# `push.delete_by_token` on it. Wrong in one direction and dead tokens accumulate forever; wrong
# in the other and a live device silently stops receiving reminders. Real sends need a device, so
# the client is faked and only the response handling is under test.


class _FakeResponse:
    def __init__(self, status_code: int, payload: object = None) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> object:
        if self._payload is None:
            raise ValueError("no body")
        return self._payload


class _FakeClient:
    def __init__(self, response: object = None, raises: Exception | None = None) -> None:
        self._response = response
        self._raises = raises
        self.calls: list[tuple[str, dict]] = []

    def post(self, path: str, **kwargs: object) -> object:
        self.calls.append((path, kwargs))
        if self._raises:
            raise self._raises
        return self._response


def _with_client(monkeypatch, client: _FakeClient) -> None:
    monkeypatch.setattr(apns, "_client", lambda sandbox: client)


def test_send_is_a_no_op_when_apns_is_not_configured(monkeypatch) -> None:
    """Self-hosted instances run without push; that must not raise or pretend to succeed."""
    monkeypatch.delenv("COMMAND_APNS_KEY_PATH", raising=False)
    get_settings.cache_clear()
    result = apns.send("tok", title="t", body="b")
    assert result.ok is False and result.reason == "apns_not_configured"
    assert result.unregistered is False, "an unconfigured server must not delete anyone's token"


def test_a_200_is_a_successful_delivery(apns_key, monkeypatch) -> None:
    client = _FakeClient(_FakeResponse(200))
    _with_client(monkeypatch, client)
    result = apns.send("device-token", title="Reminder", body="Dentist")
    assert result.ok is True and result.status == 200 and result.unregistered is False
    path, kwargs = client.calls[0]
    assert path == "/3/device/device-token"
    assert kwargs["json"]["aps"]["alert"] == {"title": "Reminder", "body": "Dentist"}


def test_a_410_marks_the_token_dead(apns_key, monkeypatch) -> None:
    _with_client(monkeypatch, _FakeClient(_FakeResponse(410, {"reason": "Unregistered"})))
    result = apns.send("dead-token", title="t", body="b")
    assert result.ok is False and result.unregistered is True


@pytest.mark.parametrize("reason", ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"])
def test_apples_dead_token_reasons_all_mark_it_dead(apns_key, monkeypatch, reason: str) -> None:
    """Apple reports a dead token several ways; missing one leaks pushes forever."""
    _with_client(monkeypatch, _FakeClient(_FakeResponse(400, {"reason": reason})))
    assert apns.send("tok", title="t", body="b").unregistered is True


def test_a_transient_failure_does_not_delete_the_token(apns_key, monkeypatch) -> None:
    """The dangerous direction: a 503 must never be read as 'this device is gone'."""
    _with_client(monkeypatch, _FakeClient(_FakeResponse(503, {"reason": "TooManyRequests"})))
    result = apns.send("live-token", title="t", body="b")
    assert result.ok is False
    assert result.unregistered is False, "a transient error must not delete a live device token"


def test_a_transport_error_is_reported_not_raised(apns_key, monkeypatch) -> None:
    """The sweep walks every account; one unreachable host must not kill the whole run."""
    _with_client(monkeypatch, _FakeClient(raises=OSError("connection reset")))
    result = apns.send("tok", title="t", body="b")
    assert result.ok is False and result.status == 0
    assert result.unregistered is False
    assert "connection reset" in (result.reason or "")


def test_an_unparseable_error_body_still_yields_a_result(apns_key, monkeypatch) -> None:
    _with_client(monkeypatch, _FakeClient(_FakeResponse(500)))
    result = apns.send("tok", title="t", body="b")
    assert result.ok is False and result.status == 500 and result.unregistered is False


def test_a_collapse_id_is_sent_and_truncated_to_apples_limit(apns_key, monkeypatch) -> None:
    client = _FakeClient(_FakeResponse(200))
    _with_client(monkeypatch, client)
    apns.send("tok", title="t", body="b", collapse_id="x" * 200)
    assert len(client.calls[0][1]["headers"]["apns-collapse-id"]) == 64
