"""The health-check access lines must not drown the log — but failures must still show.

Measured on the live container 2026-08-04: 181 of 193 log lines were `GET /api/health 200`.
A log that is 94% one repeated line cannot answer "what happened before this broke", which is
the only reason to keep one.
"""

from __future__ import annotations

import logging

from command.app import HealthCheckAccessFilter

# Uvicorn's access record: '%s - "%s %s HTTP/%s" %d' with these args.
FORMAT = '%s - "%s %s HTTP/%s" %d'


def _record(path: str, status: int, method: str = "GET") -> logging.LogRecord:
    return logging.LogRecord(
        name="uvicorn.access", level=logging.INFO, pathname=__file__, lineno=1,
        msg=FORMAT, args=("127.0.0.1:9999", method, path, "1.1", status), exc_info=None,
    )


def test_successful_health_probes_are_dropped() -> None:
    f = HealthCheckAccessFilter()
    assert f.filter(_record("/api/health", 200)) is False
    assert f.filter(_record("/api/health?verbose=1", 200)) is False, "query string must not evade it"
    assert f.filter(_record("/api/health", 204)) is False


def test_a_failing_health_check_is_still_logged() -> None:
    """The whole point of the endpoint is telling you when it stops working."""
    f = HealthCheckAccessFilter()
    for status in (500, 503, 404, 401):
        assert f.filter(_record("/api/health", status)) is True, f"{status} must survive"


def test_real_traffic_is_untouched() -> None:
    f = HealthCheckAccessFilter()
    assert f.filter(_record("/api/notes", 200)) is True
    assert f.filter(_record("/api/agent/chat", 200, method="POST")) is True
    # Must match the path exactly — a route that merely starts with it is different traffic.
    assert f.filter(_record("/api/healthcheck-admin", 200)) is True
    assert f.filter(_record("/api/health/details", 200)) is True


def test_records_that_are_not_access_lines_pass_through() -> None:
    """Never guess at a record shape we don't recognise — the cost of a wrong drop is silence."""
    f = HealthCheckAccessFilter()
    plain = logging.LogRecord(
        name="command", level=logging.INFO, pathname=__file__, lineno=1,
        msg="purged %d expired session(s)", args=(3,), exc_info=None,
    )
    assert f.filter(plain) is True
    noargs = logging.LogRecord(
        name="uvicorn.access", level=logging.INFO, pathname=__file__, lineno=1,
        msg="something", args=None, exc_info=None,
    )
    assert f.filter(noargs) is True


def test_the_filter_is_actually_installed_on_the_access_logger() -> None:
    """Guard the call site: a filter nobody attached silently changes nothing."""
    from command.app import create_app

    create_app()
    installed = logging.getLogger("uvicorn.access").filters
    assert any(isinstance(f, HealthCheckAccessFilter) for f in installed), (
        "create_app must attach the filter — this is the missing-call-site failure mode"
    )
