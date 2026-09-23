"""Self-hosting defaults: hosted PORT, and secrets a prod server generates for itself."""

from __future__ import annotations

import json
import stat

import pytest

from command.config import INSTANCE_SECRETS_FILE, Settings, get_settings


@pytest.fixture(autouse=True)
def _fresh_settings(monkeypatch: pytest.MonkeyPatch):
    for name in ("COMMAND_HTTP_PORT", "PORT", "COMMAND_PEER_TOKEN_KEY", "COMMAND_CALENDAR_EXPORT_SECRET"):
        monkeypatch.delenv(name, raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_bare_port_is_honored(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "4321")
    assert Settings().http_port == 4321


def test_explicit_command_port_beats_bare_port(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "4321")
    monkeypatch.setenv("COMMAND_HTTP_PORT", "9000")
    assert Settings().http_port == 9000


def test_prod_generates_and_persists_secrets(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "prod")
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "command.db"))

    first = get_settings()
    assert first.peer_token_key and first.peer_token_key != "dev-insecure-peer-token-key"
    assert first.calendar_export_secret

    path = tmp_path / INSTANCE_SECRETS_FILE
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(path.read_text())["peer_token_key"] == first.peer_token_key

    # A restart on the same volume must reuse them, or every stored peer token and every
    # calendar subscription URL would silently stop working.
    get_settings.cache_clear()
    second = get_settings()
    assert second.peer_token_key == first.peer_token_key
    assert second.calendar_export_secret == first.calendar_export_secret


def test_env_value_wins_over_generated(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "prod")
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "command.db"))
    monkeypatch.setenv("COMMAND_PEER_TOKEN_KEY", "from-env")
    s = get_settings()
    assert s.peer_token_key == "from-env"
    stored = json.loads((tmp_path / INSTANCE_SECRETS_FILE).read_text())
    assert "peer_token_key" not in stored
    assert stored["calendar_export_secret"] == s.calendar_export_secret


def test_dev_generates_nothing(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("COMMAND_ENVIRONMENT", "dev")
    monkeypatch.setenv("COMMAND_DB_PATH", str(tmp_path / "command.db"))
    s = get_settings()
    assert s.calendar_export_secret is None
    assert not (tmp_path / INSTANCE_SECRETS_FILE).exists()
