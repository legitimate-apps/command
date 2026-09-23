from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

from command.core.peers.a2a_adapter import A2AAdapter


def _adapter(
    *,
    authenticate: Callable[[str | None], object | None] | None = None,
    run_agent_turn: Callable[[str, str | None, object], tuple[str, str]] | None = None,
) -> A2AAdapter:
    return A2AAdapter(
        agent_name="Command",
        agent_description="A personal planning agent.",
        public_base_url="https://command.example",
        version="1.2.3",
        authenticate=authenticate or (lambda token: {"account": 1} if token == "valid" else None),
        run_agent_turn=run_agent_turn or (
            lambda text, context_id, principal: (f"reply: {text}", context_id or "new-context")
        ),
        skills=[
            {
                "id": "planning",
                "name": "Planning",
                "description": "Plans work and keeps notes.",
                "tags": ["planning", "notes"],
            }
        ],
    )


def _rpc(method: str, params: dict[str, Any] | None = None, request_id: Any = 1) -> bytes:
    request: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        request["params"] = params
    return json.dumps(request).encode()


def _message(text: str = "hello", *, context_id: str | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {
        "messageId": "client-message-id",
        "role": "ROLE_USER",
        "parts": [{"text": text}],
    }
    if context_id is not None:
        message["contextId"] = context_id
    return message


def test_card_has_required_fields() -> None:
    card = _adapter().card()

    assert card["name"] == "Command"
    assert card["description"] == "A personal planning agent."
    assert card["version"] == "1.2.3"
    assert card["supportedInterfaces"] == [
        {
            "url": "https://command.example/a2a",
            "protocolBinding": "JSONRPC",
            "protocolVersion": "1.0",
        }
    ]
    assert card["capabilities"] == {
        "streaming": False,
        "pushNotifications": False,
        "extendedAgentCard": False,
    }
    assert card["securitySchemes"]["bearer"]["httpAuthSecurityScheme"]["scheme"] == "Bearer"
    assert card["securityRequirements"] == [{"bearer": []}]
    assert card["defaultInputModes"] == ["text/plain"]
    assert card["defaultOutputModes"] == ["text/plain"]
    assert card["skills"]


def test_card_contains_no_pii() -> None:
    # The card is public: it may describe the app, never the person or machine running it.
    serialized = json.dumps(_adapter().card()).casefold()

    assert "@" not in serialized
    assert "/users/" not in serialized and "/home/" not in serialized


def test_rpc_auth_missing_token_401() -> None:
    status, response = _adapter().handle_rpc(_rpc("ListTasks", {}), None)

    assert status == 401
    assert response == {"error": "unauthorized"}


def test_rpc_bad_json_parse_error() -> None:
    status, response = _adapter().handle_rpc(b"{not-json", "valid")

    assert status == 200
    assert response["jsonrpc"] == "2.0"
    assert response["id"] is None
    assert response["error"]["code"] == -32700


def test_rpc_unknown_method_error() -> None:
    status, response = _adapter().handle_rpc(_rpc("NoSuchMethod", {}), "valid")

    assert status == 200
    assert response["id"] == 1
    assert response["error"]["code"] == -32601


def test_send_message_returns_direct_message_reply() -> None:
    calls: list[tuple[str, str | None, object]] = []

    def run_turn(text: str, context_id: str | None, principal: object) -> tuple[str, str]:
        calls.append((text, context_id, principal))
        return "agent reply", "existing-context"

    status, response = _adapter(run_agent_turn=run_turn).handle_rpc(
        _rpc("SendMessage", {"message": _message(context_id="existing-context")}), "valid"
    )

    assert status == 200
    reply = response["result"]["message"]
    assert reply["role"] == "ROLE_AGENT"
    assert reply["parts"] == [{"text": "agent reply"}]
    assert reply["contextId"] == "existing-context"
    assert isinstance(reply["messageId"], str) and reply["messageId"]
    assert calls == [("hello", "existing-context", {"account": 1})]


def test_streaming_method_unsupported() -> None:
    for method in ("SendStreamingMessage", "SubscribeToTask"):
        status, response = _adapter().handle_rpc(_rpc(method, {}), "valid")

        assert status == 200
        assert response["error"]["code"] == -32004


def test_gettask_and_canceltask_are_task_not_found() -> None:
    for method in ("GetTask", "CancelTask"):
        status, response = _adapter().handle_rpc(_rpc(method, {"id": "missing"}), "valid")

        assert status == 200
        assert response["error"]["code"] == -32001


def test_push_notification_methods_are_not_supported() -> None:
    methods = (
        "CreateTaskPushNotificationConfig",
        "GetTaskPushNotificationConfig",
        "ListTaskPushNotificationConfigs",
        "DeleteTaskPushNotificationConfig",
    )
    for method in methods:
        status, response = _adapter().handle_rpc(_rpc(method, {}), "valid")

        assert status == 200
        assert response["error"]["code"] == -32003


def test_list_tasks_returns_empty_list() -> None:
    status, response = _adapter().handle_rpc(_rpc("ListTasks", {}), "valid")

    assert status == 200
    assert response["result"] == {"tasks": []}


def test_send_message_rejects_non_text_parts_and_oversize_text() -> None:
    invalid_messages = (
        {**_message(), "parts": [{"data": {"value": 1}}]},
        _message("x" * (32 * 1024 + 1)),
    )
    for message in invalid_messages:
        status, response = _adapter().handle_rpc(_rpc("SendMessage", {"message": message}), "valid")

        assert status == 200
        assert response["error"]["code"] == -32602

    assert "under 32KB" in response["error"]["message"]


def test_send_message_rejects_invalid_params_shapes() -> None:
    requests = (
        _rpc("SendMessage"),
        _rpc("SendMessage", {}),
        _rpc("SendMessage", {"message": []}),
    )
    for body in requests:
        status, response = _adapter().handle_rpc(body, "valid")

        assert status == 200
        assert response["error"]["code"] == -32602


def test_runner_exception_becomes_actionable_internal_error() -> None:
    def fail(_text: str, _context_id: str | None, _principal: object) -> tuple[str, str]:
        raise RuntimeError("sensitive implementation detail")

    status, response = _adapter(run_agent_turn=fail).handle_rpc(
        _rpc("SendMessage", {"message": _message()}), "valid"
    )

    assert status == 200
    assert response["error"]["code"] == -32603
    assert "try again" in response["error"]["message"].casefold()
    assert "sensitive implementation detail" not in json.dumps(response)
