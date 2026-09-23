"""Typed domain errors shared by the REST and MCP surfaces.

`core/` raises these; the REST layer maps them to HTTP status + an
`{"error": {...}}` body, and the MCP layer maps them to `isError` tool results.
Each carries an LLM/agent-friendly `message` and optional `hint` (the next step).
Errors carry a code, a human message and an actionable hint.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel


class ErrorEnvelope(BaseModel):
    """Wire shape every CommandError serializes into."""

    code: str
    message: str
    hint: str | None = None
    details: dict[str, Any] | None = None


class CommandError(Exception):
    """Base for every domain error. `status` is the HTTP status the REST layer uses."""

    code: str = "error"
    status: int = 400

    def __init__(
        self,
        message: str,
        *,
        hint: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.hint = hint
        self.details = details

    def to_envelope(self) -> ErrorEnvelope:
        return ErrorEnvelope(code=self.code, message=self.message, hint=self.hint, details=self.details)


class ValidationError(CommandError):
    code = "validation_error"
    status = 422


class InvalidTimezone(ValidationError):
    """The pinned account-timezone REST contract treats an unknown IANA name as HTTP 400."""

    status = 400


class AuthFailed(CommandError):
    code = "auth_failed"
    status = 401


class PermissionDenied(CommandError):
    code = "permission_denied"
    status = 403


class NotesImmutable(PermissionDenied):
    """Special-cased: notes can never be deleted or destructively edited via MCP.

    This is enforced in `core/` regardless of the settings permission matrix
    (Hard Rule 1) — a settings bug must never make notes destructible.
    """

    code = "notes_immutable"


class NotFound(CommandError):
    code = "not_found"
    status = 404


class Conflict(CommandError):
    code = "conflict"
    status = 409


class ConfirmRequired(CommandError):
    """A destructive op needs a confirm-token handshake (MCP). Carries the plan + token."""

    code = "confirm_required"
    status = 409


class RateLimited(CommandError):
    code = "rate_limited"
    status = 429
