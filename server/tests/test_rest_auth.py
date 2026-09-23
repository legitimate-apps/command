from __future__ import annotations

from fastapi.testclient import TestClient


def test_health(client: TestClient) -> None:
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["service"] == "command"


def test_register_login_me_token_flow(client: TestClient) -> None:
    r = client.post(
        "/api/auth/register",
        json={"username": "jordan", "password": "supersecret", "display_name": "Jordan"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["username"] == "jordan"
    assert r.json()["timezone"] is None

    r = client.put("/api/account/timezone", json={"timezone": "America/New_York"})
    assert r.status_code == 200 and r.json() == {"timezone": "America/New_York"}
    assert client.put(
        "/api/account/timezone", json={"timezone": "America/New_York"}
    ).json() == {"timezone": "America/New_York"}

    # cookie set by register → /me works
    r = client.get("/api/auth/me")
    assert r.status_code == 200
    assert r.json()["username"] == "jordan"
    assert r.json()["timezone"] == "America/New_York"

    # access token is memorable + viewable
    r = client.get("/api/access-token")
    assert r.status_code == 200
    token = r.json()["access_token"]
    assert token.startswith("cmd_")

    # regenerate changes it
    r = client.post("/api/access-token/regenerate")
    assert r.status_code == 200
    assert r.json()["access_token"] != token

    # logout clears the session
    assert client.post("/api/auth/logout").status_code == 200
    assert client.get("/api/auth/me").status_code == 401


def test_login_wrong_password(client: TestClient) -> None:
    client.post("/api/auth/register", json={"username": "sam", "password": "password1"})
    r = client.post("/api/auth/login", json={"username": "sam", "password": "nope-nope"})
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "auth_failed"


def test_duplicate_register(open_signup_client: TestClient) -> None:
    """Still the right answer when signup IS open — a taken username is a conflict, not a
    closed door. Uses the open-signup fixture because the default is now first-user-only."""
    c = open_signup_client
    c.post("/api/auth/register", json={"username": "dup", "password": "password1"})
    r = c.post("/api/auth/register", json={"username": "dup", "password": "password2"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "conflict"


# --- first-user-only signup ---------------------------------------------------
#
# A Command server is one person's planner and is normally reachable from the internet (the
# phone has to get to it). Left open, anyone who finds the URL can register and spend the
# owner's model budget, with nothing anywhere to signal it happened.


def test_the_first_registration_is_allowed_and_claims_the_instance(client: TestClient) -> None:
    r = client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    assert r.status_code < 400, r.text


def test_a_second_registration_is_refused_by_default(client: TestClient) -> None:
    client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    r = client.post("/api/auth/register", json={"username": "stranger", "password": "password1"})
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "permission_denied"
    assert "own server" in r.json()["error"]["hint"], "the refusal must say what to do instead"


def test_the_owner_can_reopen_signup_deliberately(open_signup_client: TestClient) -> None:
    """Adding a second person is a real thing to want; it just shouldn't be the default."""
    c = open_signup_client
    assert c.post("/api/auth/register", json={"username": "one", "password": "password1"}).status_code < 400
    assert c.post("/api/auth/register", json={"username": "two", "password": "password1"}).status_code < 400


def test_a_closed_instance_still_lets_the_owner_log_in(client: TestClient) -> None:
    """Closing signup must not lock out the person who already owns the account."""
    client.post("/api/auth/register", json={"username": "owner", "password": "password1"})
    client.post("/api/auth/logout")
    r = client.post("/api/auth/login", json={"username": "owner", "password": "password1"})
    assert r.status_code < 400, r.text


def test_me_requires_auth(client: TestClient) -> None:
    assert client.get("/api/auth/me").status_code == 401
    assert client.put(
        "/api/account/timezone", json={"timezone": "UTC"}
    ).status_code == 401


def test_timezone_rejects_non_iana_name(client: TestClient) -> None:
    client.post("/api/auth/register", json={"username": "tzuser", "password": "password1"})
    response = client.put("/api/account/timezone", json={"timezone": "EST-ish"})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"


def test_access_token_is_four_words(client: TestClient) -> None:
    client.post("/api/auth/register", json={"username": "wordy", "password": "password1"})
    token = client.get("/api/access-token").json()["access_token"]
    # cmd_<w>-<w>-<w>-<w>-<NNNN> → 4 words + a 4-digit group (higher brute-force cost)
    body = token.removeprefix("cmd_")
    words = body.rsplit("-", 1)[0].split("-")
    assert len(words) == 4 and body.rsplit("-", 1)[1].isdigit()


def test_login_rate_limited_after_repeated_failures(client: TestClient) -> None:
    """After the per-username failure limit, even a would-be-correct attempt is 429ed
    (the guard trips before the credential check), protecting against online brute-force."""
    from command.config import get_settings

    client.post("/api/auth/register", json={"username": "target", "password": "rightpass1"})
    limit = get_settings().login_max_attempts
    for _ in range(limit):
        assert client.post(
            "/api/auth/login", json={"username": "target", "password": "wrong"}
        ).status_code == 401
    # the next attempt is rejected by the limiter, not the password check
    r = client.post("/api/auth/login", json={"username": "target", "password": "rightpass1"})
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "rate_limited"


def test_login_success_resets_failure_counter(client: TestClient) -> None:
    from command.config import get_settings

    client.post("/api/auth/register", json={"username": "resetme", "password": "rightpass1"})
    for _ in range(get_settings().login_max_attempts - 1):
        client.post("/api/auth/login", json={"username": "resetme", "password": "wrong"})
    # a success clears the counter, so subsequent failures start fresh (no immediate lockout)
    assert client.post(
        "/api/auth/login", json={"username": "resetme", "password": "rightpass1"}
    ).status_code == 200
    assert client.post(
        "/api/auth/login", json={"username": "resetme", "password": "wrong"}
    ).status_code == 401


def test_invite_guessing_is_bounded_even_though_every_guess_is_a_new_token(
    client: TestClient,
) -> None:
    """The per-token invite limiter cannot slow a brute-force search.

    It is keyed on the submitted token, and an attacker searching the invite space submits a
    DIFFERENT token every time — so every attempt lands on a fresh key and is allowed. (That
    keying is correct for login, where the username is held constant and the password varies;
    here the token IS the secret.) A global failure bucket is what actually bounds the search,
    and this pins that it exists: with only the per-token guard, this loop never 429s.
    """
    from command.rest import auth as auth_rest

    auth_rest._invite_global_limiter.reset(auth_rest._INVITE_GLOBAL_KEY)
    statuses = []
    for i in range(80):
        r = client.post("/api/auth/invite", json={"token": f"inv-never-issued-{i}"})
        statuses.append(r.status_code)
        if r.status_code == 429:
            break

    assert 429 in statuses, "an unbounded stream of distinct invite guesses was never throttled"
    assert statuses.count(401) >= 1, "the early guesses should fail authentication normally"
    auth_rest._invite_global_limiter.reset(auth_rest._INVITE_GLOBAL_KEY)


def test_a_real_redemption_clears_the_global_invite_bucket(client: TestClient) -> None:
    """Failed guesses must not strand the next legitimate delegatee: a success resets it."""
    from command.config import get_settings
    from command.core import delegatee_access, delegatees
    from command.db import connection
    from command.rest import auth as auth_rest

    client.post("/api/auth/register", json={"username": "boss", "password": "password1"})
    with connection(get_settings().db_path) as conn:
        account_id = conn.execute("SELECT id FROM accounts WHERE username = 'boss'").fetchone()[0]
        person, _ = delegatees.upsert(conn, account_id, name="Helper")
        raw = delegatee_access.create_invite(conn, account_id, person.id)

    for i in range(20):
        client.post("/api/auth/invite", json={"token": f"inv-wrong-{i}"})
    assert client.post("/api/auth/invite", json={"token": raw}).status_code == 200
    assert auth_rest._invite_global_limiter.allowed(auth_rest._INVITE_GLOBAL_KEY)
    auth_rest._invite_global_limiter.reset(auth_rest._INVITE_GLOBAL_KEY)
