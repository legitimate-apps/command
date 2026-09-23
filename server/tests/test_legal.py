"""Public legal/support pages: reachable without auth, real HTML, key terms present."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.mark.parametrize("path", ["/privacy", "/terms", "/support"])
def test_legal_pages_public_html(client: TestClient, path: str) -> None:
    r = client.get(path)
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Legitimate LLC" in r.text
    assert "info@legitimateapps.com" in r.text


def test_terms_states_subscription_terms(client: TestClient) -> None:
    body = client.get("/terms").text
    assert "$19.99" in body and "7-day free trial" in body
    assert "auto-renew" in body.lower()


def test_privacy_discloses_third_party_ai(client: TestClient) -> None:
    body = client.get("/privacy").text
    assert "OpenRouter" in body and "consent" in body.lower()
