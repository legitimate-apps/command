"""Dependency-free A2A v1.0 JSON-RPC adapter.

Copy this file into any app; implement the ``authenticate`` and
``run_agent_turn`` hooks and supply the card fields to :class:`A2AAdapter`.

Wire constants were checked against the official A2A v1.0 specification on
2026-07-17:

* Methods are ``SendMessage``, ``SendStreamingMessage``, ``GetTask``,
  ``ListTasks``, ``CancelTask``, ``SubscribeToTask``, the four
  ``*TaskPushNotificationConfig*`` methods, and ``GetExtendedAgentCard``.
  Source: https://a2a-protocol.org/latest/specification/#53-method-mapping-reference
* A v1.0 text Part is ``{"text": "..."}``; the legacy ``kind`` discriminator
  was removed and no ``type`` discriminator replaced it. Roles use ProtoJSON
  values ``ROLE_USER`` and ``ROLE_AGENT``.
  Sources: https://a2a-protocol.org/latest/specification/#416-part and
  https://a2a-protocol.org/latest/specification/#a21-breaking-change-kind-discriminator-removed
* ``TaskNotFoundError`` is -32001,
  ``PushNotificationNotSupportedError`` is -32003, and
  ``UnsupportedOperationError`` is -32004.
  Source: https://a2a-protocol.org/latest/specification/#54-error-code-mappings
* An Agent Card requires ``name``, ``description``, ``supportedInterfaces``,
  ``version``, ``capabilities``, both default mode fields, and ``skills``.
  ``protocolVersion`` belongs to an interface and is ``"1.0"`` here; the
  binding identifier is ``JSONRPC``. This corrects the legacy top-level
  ``url``/``protocolVersion`` shape in the implementation plan.
  Sources: https://a2a-protocol.org/latest/specification/#441-agentcard and
  https://a2a-protocol.org/latest/specification/#446-agentinterface
* ``SendMessage`` returns a ``SendMessageResponse`` whose result contains
  exactly one of ``message`` or ``task``. This adapter uses direct-Message mode.
  Source: https://a2a-protocol.org/latest/specification/#941-sendmessage
"""

from __future__ import annotations

import copy
import json
import uuid
from collections.abc import Callable
from typing import Any

PROTOCOL_VERSION = "1.0"
MAX_TEXT_BYTES = 32 * 1024

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
TASK_NOT_FOUND = -32001
PUSH_NOT_SUPPORTED = -32003
UNSUPPORTED_OPERATION = -32004

_STREAMING_METHODS = frozenset({"SendStreamingMessage", "SubscribeToTask"})
_TASK_METHODS = frozenset({"GetTask", "CancelTask"})
_PUSH_METHODS = frozenset(
    {
        "CreateTaskPushNotificationConfig",
        "GetTaskPushNotificationConfig",
        "ListTaskPushNotificationConfigs",
        "DeleteTaskPushNotificationConfig",
    }
)

Authenticate = Callable[[str | None], object | None]
RunAgentTurn = Callable[[str, str | None, object], tuple[str, str]]


class A2ATurnError(Exception):
    """Raised by ``run_agent_turn`` to surface a SAFE, actionable message to the
    calling peer (rate limit, busy, credits exhausted). Any other exception is
    masked as a generic internal error."""


class A2AAdapter:
    """Serve an Agent Card and synchronous A2A JSON-RPC requests."""

    def __init__(
        self,
        *,
        agent_name: str,
        agent_description: str,
        public_base_url: str,
        version: str,
        authenticate: Authenticate,
        run_agent_turn: RunAgentTurn,
        skills: list[dict[str, Any]],
    ) -> None:
        self._agent_name = agent_name
        self._agent_description = agent_description
        self._endpoint_url = f"{public_base_url.rstrip('/')}/a2a"
        self._version = version
        self._authenticate = authenticate
        self._run_agent_turn = run_agent_turn
        self._skills = copy.deepcopy(skills)

    def card(self) -> dict[str, Any]:
        """Return a new A2A v1.0 Agent Card object."""

        return {
            "name": self._agent_name,
            "description": self._agent_description,
            "supportedInterfaces": [
                {
                    "url": self._endpoint_url,
                    "protocolBinding": "JSONRPC",
                    "protocolVersion": PROTOCOL_VERSION,
                }
            ],
            "version": self._version,
            "capabilities": {
                "streaming": False,
                "pushNotifications": False,
                "extendedAgentCard": False,
            },
            "securitySchemes": {
                "bearer": {"httpAuthSecurityScheme": {"scheme": "Bearer"}}
            },
            "securityRequirements": [{"bearer": []}],
            "defaultInputModes": ["text/plain"],
            "defaultOutputModes": ["text/plain"],
            "skills": copy.deepcopy(self._skills),
        }

    def handle_rpc(self, body: bytes, bearer_token: str | None) -> tuple[int, dict[str, Any]]:
        """Handle one authenticated JSON-RPC request without raising exceptions."""

        try:
            principal = self._authenticate(bearer_token)
            if principal is None:
                return 401, {"error": "unauthorized"}
            return 200, self._dispatch(body, principal)
        except Exception:
            return 200, _error(None, INTERNAL_ERROR, "Internal error — try again later")

    def authenticate(self, bearer_token: str | None) -> object | None:
        """Resolve the caller BEFORE its body is read, so an unauthenticated request never
        makes the server buffer (or parse) anything. Never raises; None means reject."""
        try:
            return self._authenticate(bearer_token)
        except Exception:
            return None

    def handle_authenticated(self, body: bytes, principal: object) -> dict[str, Any]:
        """`handle_rpc` for a caller `authenticate` already accepted. Never raises."""
        try:
            return self._dispatch(body, principal)
        except Exception:
            return _error(None, INTERNAL_ERROR, "Internal error — try again later")

    def _dispatch(self, body: bytes, principal: object) -> dict[str, Any]:
        try:
            request = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return _error(None, PARSE_ERROR, "Parse error — send a valid JSON object")

        if not isinstance(request, dict):
            return _error(None, INVALID_REQUEST, "Invalid request — send a JSON-RPC object")

        request_id = request.get("id")
        if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            return _error(request_id, INVALID_REQUEST, "Invalid request — expected JSON-RPC 2.0")

        method = request["method"]
        params = request.get("params", {})
        if not isinstance(params, dict):
            return _error(request_id, INVALID_PARAMS, "Invalid params — expected an object")

        if method == "SendMessage":
            return self._send_message(request_id, params, principal)
        if method == "ListTasks":
            return _success(request_id, {"tasks": []})
        if method in _TASK_METHODS:
            return _error(request_id, TASK_NOT_FOUND, "Task not found")
        if method in _STREAMING_METHODS or method == "GetExtendedAgentCard":
            return _error(request_id, UNSUPPORTED_OPERATION, "Operation not supported by this agent")
        if method in _PUSH_METHODS:
            return _error(
                request_id,
                PUSH_NOT_SUPPORTED,
                "Push notifications are not supported by this agent",
            )
        return _error(request_id, METHOD_NOT_FOUND, f"Method not found: {method}")

    def _send_message(
        self, request_id: Any, params: dict[str, Any], principal: object
    ) -> dict[str, Any]:
        message = params.get("message")
        validation_error = _validate_message(message)
        if validation_error is not None:
            return _error(request_id, INVALID_PARAMS, validation_error)

        assert isinstance(message, dict)
        parts = message["parts"]
        text = "\n".join(part["text"] for part in parts)
        context_id = message.get("contextId")
        try:
            reply_text, reply_context_id = self._run_agent_turn(text, context_id, principal)
            if not isinstance(reply_text, str) or not isinstance(reply_context_id, str):
                raise TypeError("run_agent_turn must return two strings")
        except A2ATurnError as exc:
            return _error(request_id, INTERNAL_ERROR, str(exc))
        except Exception:
            return _error(request_id, INTERNAL_ERROR, "Internal error — try again later")

        reply = {
            "messageId": str(uuid.uuid4()),
            "contextId": reply_context_id,
            "role": "ROLE_AGENT",
            "parts": [{"text": reply_text}],
        }
        return _success(request_id, {"message": reply})


def _validate_message(message: Any) -> str | None:
    if not isinstance(message, dict):
        return "Invalid params — message must be an object"
    if not isinstance(message.get("messageId"), str) or not message["messageId"]:
        return "Invalid params — message.messageId is required"
    if message.get("role") != "ROLE_USER":
        return "Invalid params — message.role must be ROLE_USER"
    context_id = message.get("contextId")
    if context_id is not None and not isinstance(context_id, str):
        return "Invalid params — message.contextId must be a string"
    parts = message.get("parts")
    if not isinstance(parts, list) or not parts:
        return "Invalid params — message.parts must contain text"

    total_bytes = 0
    for part in parts:
        if not isinstance(part, dict) or not isinstance(part.get("text"), str):
            return "Invalid params — only text parts are supported"
        if any(key in part for key in ("raw", "url", "data", "kind", "type")):
            return "Invalid params — only A2A v1.0 text parts are supported"
        total_bytes += len(part["text"].encode("utf-8"))
        if total_bytes > MAX_TEXT_BYTES:
            return "Message too large — send under 32KB of text"
    return None


def _success(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
