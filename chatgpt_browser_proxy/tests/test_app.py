import json

import pytest
from fastapi.testclient import TestClient

import app as proxy


@pytest.fixture(autouse=True)
def reset_state(monkeypatch, tmp_path):
    proxy.browser_clients.clear()
    proxy.browser_locks.clear()
    proxy.pending_responses.clear()
    proxy.session_states.clear()
    monkeypatch.setattr(proxy, "API_KEY", "test-key")
    monkeypatch.setattr(proxy, "DEFAULT_NEW_SESSION", False)
    monkeypatch.setattr(proxy, "SESSION_STATE_PATH", str(tmp_path / "session_state.json"))
    yield


@pytest.fixture
def client():
    return TestClient(proxy.app)


def auth():
    return {"Authorization": "Bearer test-key"}


def test_messages_to_prompt_formats_roles():
    prompt = proxy.messages_to_prompt(
        [
            {"role": "system", "content": "be terse"},
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi"},
            {"role": "tool", "content": "tool output"},
        ]
    )
    assert "[System]\nbe terse" in prompt
    assert "hello" in prompt
    assert "[Assistant]\nhi" in prompt
    assert "[Tool result]\ntool output" in prompt


def test_image_inputs_fail_fast():
    with pytest.raises(proxy.UnsupportedRequestError):
        proxy._content_to_text([{"type": "image_url", "image_url": {"url": "https://example.com/a.png"}}])


def test_body_to_prompt_adds_tool_call_contract():
    prompt = proxy.body_to_prompt(
        {
            "messages": [{"role": "user", "content": "weather?"}],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "description": "Get weather",
                        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}},
                    },
                }
            ],
            "tool_choice": "auto",
        }
    )
    assert '"tool_calls"' in prompt
    assert "get_weather" in prompt
    assert "weather?" in prompt


def test_tool_contract_trails_messages_for_browser_attention():
    prompt, _ = proxy._build_prompt_for_session(
        "tool-contract-session",
        False,
        {
            "messages": [{"role": "user", "content": "run pwd"}],
            "tool_choice": "required",
            "tools": [{"type": "function", "function": {"name": "Bash", "parameters": {"type": "object"}}}],
        },
    )
    assert prompt.rfind("[Tool call contract - highest priority]") > prompt.rfind("run pwd")
    assert "Return exactly one tool call and no prose" in prompt


def test_parse_tool_calls_from_fenced_json():
    calls = proxy.parse_tool_calls(
        '```json\n{"tool_calls":[{"name":"Bash","arguments":{"command":"pwd"}}]}\n```'
    )
    assert calls[0]["name"] == "Bash"
    assert calls[0]["arguments"] == {"command": "pwd"}


def test_parse_tool_calls_repairs_shell_escapes():
    calls = proxy.parse_tool_calls(
        r'{"tool_calls":[{"name":"Bash","arguments":{"command":"find . \( -name package.json \) -print"}}]}'
    )
    assert calls[0]["name"] == "Bash"
    assert calls[0]["arguments"]["command"] == r"find . \( -name package.json \) -print"


def test_clean_response_text_removes_chatgpt_ui_artifact():
    assert proxy.clean_response_text("Thought for a secondexact-ok") == "exact-ok"
    assert proxy.clean_response_text(" Thought for 3 seconds\nexact-ok ") == "exact-ok"
    assert proxy.clean_response_text("Thought for a couple of secondsdone") == "done"


def test_session_state_persists_to_disk(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        return "persisted-ok"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "session_id": "persist-session",
            "messages": [{"role": "user", "content": "remember me"}],
        },
    )
    assert response.status_code == 200
    proxy.session_states.clear()
    proxy._load_session_states()
    assert proxy.session_states["persist-session"]["messages"][-1]["content"] == "persisted-ok"


def test_user_field_is_not_session_id(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        assert session_id is not None
        assert not session_id.startswith('{"device_id"')
        assert session_id.startswith("browser-stable-")
        return f"{session_id}:{new_session}"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "user": '{"device_id":"abc"}',
            "messages": [{"role": "user", "content": "hi"}],
        },
    )
    assert response.status_code == 200
    assert response.json()["session_id"].startswith("browser-stable-")


def test_missing_session_uses_stable_derived_id(client, monkeypatch):
    seen = []

    async def fake_query(prompt, session_id, new_session):
        seen.append((session_id, new_session))
        return "ok"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    payload = {"model": "chatgpt-browser", "messages": [{"role": "user", "content": "hi"}]}
    headers = {**auth(), "User-Agent": "pytest-client"}
    first = client.post("/v1/chat/completions", headers=headers, json=payload)
    second = client.post("/v1/chat/completions", headers=headers, json=payload)

    assert first.status_code == 200
    assert second.status_code == 200
    assert seen[0][0] == seen[1][0]
    assert seen[0][0].startswith("browser-stable-")
    assert seen[0][1] is True
    assert seen[1][1] is False


def test_missing_session_changes_for_unrelated_first_user(client, monkeypatch):
    seen = []

    async def fake_query(prompt, session_id, new_session):
        seen.append(session_id)
        return "ok"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    headers = {**auth(), "User-Agent": "pytest-client"}
    first = client.post(
        "/v1/chat/completions",
        headers=headers,
        json={"model": "chatgpt-browser", "messages": [{"role": "user", "content": "first task"}]},
    )
    second = client.post(
        "/v1/chat/completions",
        headers=headers,
        json={"model": "chatgpt-browser", "messages": [{"role": "user", "content": "second task"}]},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert seen[0] != seen[1]


def test_session_delta_sends_only_new_messages(client, monkeypatch):
    prompts = []

    async def fake_query(prompt, session_id, new_session):
        prompts.append((prompt, new_session))
        return "ok"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    session_id = "delta-session"
    first_messages = [
        {"role": "user", "content": "first message"},
    ]
    second_messages = [
        {"role": "user", "content": "first message"},
        {"role": "assistant", "content": "ok"},
        {"role": "user", "content": "second message"},
    ]

    first = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={"model": "chatgpt-browser", "session_id": session_id, "messages": first_messages},
    )
    second = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={"model": "chatgpt-browser", "session_id": session_id, "messages": second_messages},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert "first message" in prompts[0][0]
    assert prompts[0][1] is True
    assert "second message" in prompts[1][0]
    assert "first message" not in prompts[1][0]
    assert prompts[1][1] is False


def test_session_compaction_does_not_duplicate_new_message(client, monkeypatch):
    prompts = []

    async def fake_query(prompt, session_id, new_session):
        prompts.append(prompt)
        return "ok"

    monkeypatch.setattr(proxy, "COMPACT_EVERY", 2)
    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    session_id = "compact-session"

    client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "session_id": session_id,
            "messages": [{"role": "user", "content": "first message"}],
        },
    )
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "session_id": session_id,
            "messages": [
                {"role": "user", "content": "first message"},
                {"role": "assistant", "content": "ok"},
                {"role": "user", "content": "second message"},
            ],
        },
    )

    assert response.status_code == 200
    assert prompts[1].count("second message") == 1


def test_chat_completion_returns_tool_calls(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        return '{"tool_calls":[{"name":"Bash","arguments":{"command":"printf ok"}}]}'

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "messages": [{"role": "user", "content": "run it"}],
            "tools": [{"type": "function", "function": {"name": "Bash", "parameters": {"type": "object"}}}],
        },
    )
    body = response.json()
    assert response.status_code == 200
    assert body["choices"][0]["finish_reason"] == "tool_calls"
    assert body["choices"][0]["message"]["tool_calls"][0]["function"]["name"] == "Bash"
    assert json.loads(body["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"]) == {
        "command": "printf ok"
    }


def test_responses_returns_function_call_items(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        return '{"tool_calls":[{"name":"Bash","arguments":{"command":"pwd"}}]}'

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/responses",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "input": "run pwd",
            "tools": [{"type": "function", "name": "Bash", "parameters": {"type": "object"}}],
        },
    )
    body = response.json()
    assert response.status_code == 200
    assert body["output_text"] == ""
    assert body["output"][0]["type"] == "function_call"
    assert body["output"][0]["name"] == "Bash"
    assert body["usage"]["input_tokens"] >= 1
    assert body["usage"]["output_tokens"] >= 1
    assert "prompt_tokens" not in body["usage"]


def test_responses_parses_tool_envelope_without_tools_field(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        return '{"tool_calls":[{"name":"Bash","arguments":{"command":"pwd"}}]}'

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/responses",
        headers=auth(),
        json={"model": "chatgpt-browser", "input": "run pwd"},
    )
    body = response.json()
    assert response.status_code == 200
    assert body["output_text"] == ""
    assert body["output"][0]["type"] == "function_call"
    assert body["output"][0]["name"] == "Bash"


def test_chat_completions_keeps_chat_usage_shape(client, monkeypatch):
    async def fake_query(prompt, session_id, new_session):
        return "ok"

    monkeypatch.setattr(proxy, "query_chatgpt", fake_query)
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={"model": "chatgpt-browser", "messages": [{"role": "user", "content": "hi"}]},
    )
    body = response.json()
    assert response.status_code == 200
    assert body["usage"]["prompt_tokens"] >= 1
    assert body["usage"]["completion_tokens"] >= 1
    assert "input_tokens" not in body["usage"]


def test_unsupported_image_endpoint_returns_400(client):
    response = client.post(
        "/v1/chat/completions",
        headers=auth(),
        json={
            "model": "chatgpt-browser",
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "image_url", "image_url": {"url": "https://example.com/a.png"}}],
                }
            ],
        },
    )
    assert response.status_code == 400


def test_ready_requires_browser(client):
    response = client.get("/ready")
    assert response.status_code == 503
