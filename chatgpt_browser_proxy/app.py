#!/usr/bin/env python3
"""OpenAI-compatible proxy for a logged-in ChatGPT browser tab via CodeWebChat."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any

import uvicorn
import websockets
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse


MODEL_NAME = os.getenv("CHATGPT_BROWSER_MODEL", "chatgpt-browser")
JS_MODEL_NAME = os.getenv("CHATGPT_BROWSER_JS_MODEL", "chatgpt-browser-js")
JS_UPSTREAM_MODEL = os.getenv("CHATGPT_BROWSER_JS_UPSTREAM_MODEL", "gpt-5.4-mini")
JS_API_URL = os.getenv("CHATGPT_BROWSER_JS_API_URL", "https://chatgpt.com/backend-api/codex/responses")
WS_URL = os.getenv("CHATGPT_BROWSER_WS_URL", "ws://host.docker.internal:55155")
WS_TOKEN = os.getenv("CHATGPT_BROWSER_WS_TOKEN", "gemini-coder-vscode")
BROWSER_WS_TOKEN = os.getenv("CHATGPT_BROWSER_EXTENSION_WS_TOKEN", "gemini-coder")
REQUEST_TIMEOUT = float(os.getenv("CHATGPT_BROWSER_REQUEST_TIMEOUT", "300"))
CONNECT_TIMEOUT = float(os.getenv("CHATGPT_BROWSER_CONNECT_TIMEOUT", "10"))
PING_INTERVAL = float(os.getenv("CHATGPT_BROWSER_PING_INTERVAL", "10"))
TARGET_BROWSER_ID = os.getenv("CHATGPT_BROWSER_TARGET_BROWSER_ID", "")
API_KEY = os.getenv("CHATGPT_BROWSER_API_KEY", "")
DEFAULT_NEW_SESSION = os.getenv("CHATGPT_BROWSER_NEW_SESSION_PER_REQUEST", "0").lower() not in (
    "0",
    "false",
    "no",
)
COMPACT_EVERY = int(os.getenv("CHATGPT_BROWSER_COMPACT_EVERY", "30"))
SESSION_STATE_PATH = os.getenv("CHATGPT_BROWSER_SESSION_STATE_PATH", "/data/session_state.json")

app = FastAPI(title="ChatGPT Browser OpenAI Proxy")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

browser_clients: dict[int, WebSocket] = {}
browser_locks: dict[int, asyncio.Lock] = {}
pending_responses: dict[int, tuple[int, asyncio.Future[str]]] = {}
pending_api_responses: dict[int, tuple[int, asyncio.Future[dict[str, Any]]]] = {}
browser_counter = 0
client_counter = 0
state_lock = asyncio.Lock()
ping_task: asyncio.Task[None] | None = None

# session_id -> accumulated conversation state
session_states: dict[str, dict[str, Any]] = {}


def log(message: str) -> None:
    print(f"[chatgpt-browser-proxy] {message}", flush=True)


def _auth_ok(request: Request) -> bool:
    if not API_KEY:
        return True
    header = request.headers.get("authorization", "")
    return header == f"Bearer {API_KEY}"


def _load_session_states() -> None:
    path = Path(SESSION_STATE_PATH)
    if not path.exists():
        return
    try:
        value = json.loads(path.read_text())
        states = value.get("sessions", value) if isinstance(value, dict) else {}
        if isinstance(states, dict):
            session_states.clear()
            session_states.update({str(k): v for k, v in states.items() if isinstance(v, dict)})
            log(f"loaded {len(session_states)} persisted sessions from {path}")
    except Exception as exc:
        log(f"failed to load session state from {path}: {exc}")


def _save_session_states() -> None:
    if not SESSION_STATE_PATH:
        return
    path = Path(SESSION_STATE_PATH)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps({"sessions": session_states}, ensure_ascii=False))
        tmp.replace(path)
    except Exception as exc:
        log(f"failed to save session state to {path}: {exc}")


class UnsupportedRequestError(ValueError):
    """Request uses a feature the browser provider cannot safely preserve."""


def _content_to_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if item.get("type") in ("text", "input_text"):
                    parts.append(str(item.get("text", "")))
                elif item.get("text"):
                    parts.append(str(item["text"]))
                elif item.get("type") in ("image_url", "input_image", "image"):
                    raise UnsupportedRequestError("chatgpt-browser cannot receive image inputs through this provider yet")
        return "\n".join(part for part in parts if part)
    return str(content)


def _message_to_text(message: dict[str, Any]) -> tuple[str, list[str]]:
    """Extract plain text and tool call blocks from a message."""
    role = message.get("role", "user")
    content = message.get("content")

    # Handle structured tool calls in assistant messages
    tool_blocks: list[str] = []
    if role == "assistant" and isinstance(content, list):
        text_parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text":
                    text_parts.append(str(item.get("text", "")))
                elif item.get("type") in ("tool_use", "function_call"):
                    # Anthropic/Codex format
                    name = item.get("name", "")
                    args = item.get("input") or item.get("arguments") or {}
                    tool_blocks.append(
                        json.dumps(
                            {"tool_calls": [{"name": name, "arguments": args}]},
                            ensure_ascii=False,
                        )
                    )
                elif item.get("type") == "thinking":
                    # Drop thinking blocks to save tokens
                    pass
            elif isinstance(item, str):
                text_parts.append(item)
        return "\n".join(part for part in text_parts if part), tool_blocks

    return _content_to_text(content), tool_blocks


def messages_to_prompt(messages: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for message in messages:
        role = message.get("role", "user")
        text, tool_blocks = _message_to_text(message)
        if not text and not tool_blocks:
            continue
        prefix = role.capitalize()
        if role == "system":
            prefix = "System"
        elif role == "assistant":
            prefix = "Assistant"
        elif role == "tool":
            prefix = "Tool result"
        elif role == "function":
            prefix = "Tool result"
        body = text
        if tool_blocks:
            body = body + "\n" + "\n".join(tool_blocks) if body else "\n".join(tool_blocks)
        parts.append(f"[{prefix}]\n{body}")
    return "\n\n".join(parts).strip()


def messages_to_responses_input(messages: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]]]:
    instructions: list[str] = []
    input_items: list[dict[str, Any]] = []
    for message in messages:
        role = message.get("role", "user")
        text, tool_blocks = _message_to_text(message)
        if tool_blocks:
            text = (text + "\n" if text else "") + "\n".join(tool_blocks)
        if not text:
            continue
        if role == "system":
            instructions.append(text)
            continue
        if role == "tool":
            input_items.append(
                {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": f"[Tool result]\n{text}"}],
                }
            )
            continue
        input_items.append(
            {
                "type": "message",
                "role": "assistant" if role == "assistant" else "user",
                "content": [{"type": "input_text", "text": text}],
            }
        )
    return "\n\n".join(instructions), input_items


def _normalize_tool(tool: dict[str, Any]) -> dict[str, Any]:
    if tool.get("type") == "function" and isinstance(tool.get("function"), dict):
        fn = tool["function"]
        return {
            "type": "function",
            "name": fn.get("name"),
            "description": fn.get("description", ""),
            "parameters": fn.get("parameters", {"type": "object", "properties": {}}),
        }
    return tool


def _request_extras_to_prompt(body: dict[str, Any]) -> str:
    """Preserve optional OpenAI client contracts as plain prompt context."""
    extras: list[str] = []
    if body.get("tools"):
        tool_choice = body.get("tool_choice", "auto")
        tool_choice_required = tool_choice == "required" or (
            isinstance(tool_choice, dict) and tool_choice.get("type") in {"function", "tool"}
        )
        required_text = (
            "The caller requires a tool call. Return exactly one tool call and no prose.\n"
            if tool_choice_required
            else "If a tool is needed, return a tool call and no prose. If no tool is needed, answer normally.\n"
        )
        extras.append(
            "[Tool call contract - highest priority]\n"
            f"{required_text}"
            "Never execute, simulate, or describe tool results yourself.\n"
            "Return ONLY strict JSON in this exact shape when calling tools (no markdown, no comments):\n"
            '{"tool_calls":[{"name":"tool_name","arguments":{}}]}\n'
            f"tool_choice={json.dumps(tool_choice, ensure_ascii=False)}\n"
            f"{json.dumps([_normalize_tool(t) for t in body['tools']], ensure_ascii=False)}"
        )
    if body.get("response_format"):
        extras.append(
            "[Response format]\n"
            f"{json.dumps(body['response_format'], ensure_ascii=False)}"
        )
    return "\n\n".join(extras)


def body_to_prompt(body: dict[str, Any]) -> str:
    prompt = messages_to_prompt(body.get("messages", []))
    extras = _request_extras_to_prompt(body)
    if prompt and extras:
        return f"{extras}\n\n{prompt}"
    return prompt or extras


def _compact_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Summarize old messages to keep context within token budget."""
    if len(messages) <= 4:
        return messages
    # Keep first system msg, last 2 user/assistant exchanges, summarize the rest
    result: list[dict[str, Any]] = []
    system_msgs = [m for m in messages if m.get("role") == "system"]
    if system_msgs:
        result.append(system_msgs[0])
    # Add a summary marker for dropped context
    result.append({"role": "system", "content": "[Earlier conversation summarized; referring to previous context as needed]"})
    # Keep last 3 full exchanges
    result.extend(messages[-5:])
    return result


def _extract_json_object(text: str) -> dict[str, Any] | None:
    stripped = text.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", stripped, flags=re.DOTALL | re.IGNORECASE)
    candidates = [stripped]
    if fenced:
        candidates.insert(0, fenced.group(1))
    if "{" in stripped and "}" in stripped:
        candidates.append(stripped[stripped.find("{") : stripped.rfind("}") + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            try:
                repaired = re.sub(r'\\(?!["\\/bfnrtu])', r"\\\\", candidate)
                value = json.loads(repaired)
            except json.JSONDecodeError:
                continue
        if isinstance(value, dict):
            return value
    return None


def parse_tool_calls(text: str) -> list[dict[str, Any]]:
    """Extract tool calls from an explicit top-level {"tool_calls": [...]} envelope."""
    value = _extract_json_object(text)
    if not value or "tool_calls" not in value:
        return []
    raw_calls = value["tool_calls"]
    if not isinstance(raw_calls, list):
        return []

    calls: list[dict[str, Any]] = []
    for raw in raw_calls:
        if not isinstance(raw, dict):
            continue
        fn = raw.get("function") if isinstance(raw.get("function"), dict) else raw
        name = fn.get("name")
        if not name or not isinstance(name, str):
            continue
        arguments = fn.get("arguments", {})
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError:
                arguments = {"raw": arguments}
        calls.append(
            {
                "id": raw.get("id") or f"call_{uuid.uuid4().hex}",
                "name": str(name),
                "arguments": arguments if isinstance(arguments, dict) else {"value": arguments},
            }
        )
    return calls


def clean_response_text(text: str) -> str:
    return re.sub(r"^\s*Thought for (?:a second|a couple of seconds|a few seconds|\d+ seconds?)\s*", "", text).strip()


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).lower() in ("1", "true", "yes", "y", "on")


def _stable_session_id(request: Request, body: dict[str, Any]) -> str:
    """Derive a stable browser session when Claude/LiteLLM omit one."""
    metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
    messages = body.get("messages") if isinstance(body.get("messages"), list) else []
    raw_input = body.get("input")
    if not messages and isinstance(raw_input, list):
        messages = raw_input
    elif not messages and raw_input:
        messages = [{"role": "user", "content": raw_input}]
    first_user = next((m for m in messages if isinstance(m, dict) and m.get("role") == "user"), None)
    first_user_hash = _msg_hash(first_user) if first_user else None
    seed = {
        "model": body.get("model", MODEL_NAME),
        "claude_session_id": metadata.get("claude_session_id"),
        "conversation_id": metadata.get("conversation_id"),
        "cwd": metadata.get("cwd") or metadata.get("working_directory"),
        "first_user": first_user_hash,
        "anthropic_version": request.headers.get("anthropic-version"),
        "client": request.headers.get("user-agent", ""),
    }
    seed_text = json.dumps(seed, sort_keys=True, default=str)
    return "browser-stable-" + hashlib.sha256(seed_text.encode("utf-8")).hexdigest()[:16]


def _extract_session_controls(request: Request, body: dict[str, Any]) -> tuple[str | None, bool]:
    metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
    session_id = (
        request.headers.get("x-session-id")
        or request.headers.get("x-chatgpt-browser-session-id")
        or body.get("session_id")
        or body.get("conversation_id")
        or metadata.get("session_id")
        or metadata.get("conversation_id")
        or metadata.get("claude_session_id")
    )
    session_id = str(session_id).strip() if session_id else None

    explicit_new_session = (
        request.headers.get("x-new-session")
        or request.headers.get("x-chatgpt-browser-new-session")
        or body.get("new_session")
        or metadata.get("new_session")
    )
    if explicit_new_session is not None:
        new_session = _truthy(explicit_new_session)
    else:
        new_session = DEFAULT_NEW_SESSION and session_id is None

    if session_id is None and not new_session:
        session_id = _stable_session_id(request, body)
    elif new_session and session_id is None:
        session_id = f"browser-{uuid.uuid4().hex}"

    return session_id, new_session


def _build_prompt_for_session(
    session_id: str,
    new_session: bool,
    body: dict[str, Any],
) -> tuple[str, bool]:
    """Return prompt text and whether we should do a full reset."""
    state = session_states.get(session_id)
    all_messages: list[dict[str, Any]] = list(body.get("messages", []))

    # Convert Responses API "input" to messages
    raw_input = body.get("input")
    if raw_input and not all_messages:
        all_messages = raw_input if isinstance(raw_input, list) else [{"role": "user", "content": raw_input}]

    extras = _request_extras_to_prompt(body)

    if new_session or state is None:
        # First request: send full history once
        prompt = messages_to_prompt(all_messages)
        if extras and prompt:
            prompt = f"{prompt}\n\n{extras}"
        elif extras:
            prompt = extras
        session_states[session_id] = {
            "messages": list(all_messages),
            "turn_count": 1,
            "last_responses": [],
        }
        _save_session_states()
        log(f"session {session_id[:20]}... full history ({len(prompt)} chars, {len(all_messages)} msgs)")
        return prompt, True

    # Delta: figure out what changed since last request
    prev_messages: list[dict[str, Any]] = state["messages"]
    prev_len = len(prev_messages)

    # Append assistant responses from prior turn if any
    prev_responses: list[str] = state.get("last_responses", [])
    for resp in prev_responses:
        prev_messages = prev_messages + [{"role": "assistant", "content": resp}]

    # New messages are anything after what we've seen
    if len(all_messages) > prev_len:
        new_messages = all_messages[prev_len:]
    else:
        # Claude sometimes regenerates the full history; diff by content hash
        seen_hashes = {_msg_hash(m) for m in prev_messages}
        new_messages = [m for m in all_messages if _msg_hash(m) not in seen_hashes]

    # Compaction check
    turn_count = state.get("turn_count", 1) + 1
    needs_compact = turn_count >= COMPACT_EVERY

    if needs_compact:
        compacted_messages = _compact_messages(all_messages)
        session_states[session_id]["messages"] = list(compacted_messages)
        session_states[session_id]["turn_count"] = 0
        prompt = messages_to_prompt(compacted_messages)
        if extras:
            prompt = f"{prompt}\n\n{extras}"
        _save_session_states()
        log(f"session {session_id[:20]}... COMPACT + {len(new_messages)} new msgs ({len(prompt)} chars)")
    else:
        session_states[session_id]["turn_count"] = turn_count
        if new_messages:
            session_states[session_id]["messages"].extend(new_messages)
        # For delta, send just the extras + new messages as context
        delta_prompt = messages_to_prompt(new_messages) if new_messages else "Continue."
        if extras:
            delta_prompt = f"{delta_prompt}\n\n{extras}"
        prompt = delta_prompt
        _save_session_states()
        log(f"session {session_id[:20]}... delta {len(new_messages)} new msgs ({len(prompt)} chars)")

    return prompt, False


def _msg_hash(msg: dict[str, Any]) -> str:
    """Stable hash for deduplicating messages."""
    return hashlib.sha256(json.dumps(msg, sort_keys=True, default=str).encode()).hexdigest()[:16]


def _store_response(session_id: str, response_text: str) -> None:
    state = session_states.get(session_id)
    if state is not None:
        state["last_responses"] = [response_text]
        state["messages"].append({"role": "assistant", "content": response_text})
        _save_session_states()


async def _recv_json(ws: Any, timeout: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
    return json.loads(raw)


async def _handshake(ws: Any) -> tuple[int, list[dict[str, Any]]]:
    client_id: int | None = None
    browsers: list[dict[str, Any]] = []
    saw_browser_status = False
    deadline = time.monotonic() + CONNECT_TIMEOUT

    while time.monotonic() < deadline:
        remaining = max(0.1, deadline - time.monotonic())
        data = await _recv_json(ws, remaining)
        action = data.get("action")
        if action == "client-id-assignment":
            client_id = int(data["client_id"])
        elif action == "browser-connection-status":
            saw_browser_status = True
            browsers = data.get("connected_browsers", [])
        elif action == "ping":
            continue
        if client_id is not None and saw_browser_status:
            return client_id, browsers

    if client_id is None:
        raise RuntimeError("CodeWebChat did not assign a client id")
    return client_id, browsers


def _select_browser(browsers: list[dict[str, Any]]) -> int:
    if not browsers:
        raise RuntimeError(
            "No CodeWebChat browser connected. Open chatgpt.com in Chrome with the CodeWebChat browser extension loaded."
        )
    if TARGET_BROWSER_ID:
        wanted = int(TARGET_BROWSER_ID)
        for browser in browsers:
            if int(browser.get("id", -1)) == wanted:
                return wanted
        raise RuntimeError(f"Configured browser id {wanted} is not connected")
    return int(browsers[-1]["id"])


async def query_chatgpt_external(prompt: str, session_id: str | None, new_session: bool) -> str:
    if not prompt:
        raise RuntimeError("No prompt text was supplied")

    uri = f"{WS_URL}?token={WS_TOKEN}"
    async with websockets.connect(uri, open_timeout=CONNECT_TIMEOUT) as ws:
        client_id, browsers = await _handshake(ws)
        browser_id = _select_browser(browsers)

        await ws.send(
            json.dumps(
                {
                    "action": "initialize-chat",
                    "client_id": client_id,
                    "target_browser_id": browser_id,
                    "text": prompt,
                    "url": os.getenv("CHATGPT_BROWSER_CHAT_URL", "https://chatgpt.com/"),
                    "raw_instructions": "",
                    "edit_format": "none",
                    "prompt_type": "edit-context",
                    "session_id": session_id,
                    "new_session": new_session,
                }
            )
        )

        deadline = time.monotonic() + REQUEST_TIMEOUT
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            data = await _recv_json(ws, remaining)
            action = data.get("action")
            if action == "apply-chat-response" and int(data.get("client_id", client_id)) == client_id:
                return str(data.get("response", ""))
            if action in ("ping", "browser-connection-status"):
                continue

    raise RuntimeError("Timed out waiting for ChatGPT browser response")


async def _next_client_id() -> int:
    global client_counter
    async with state_lock:
        client_counter += 1
        return client_counter


async def _select_embedded_browser() -> tuple[int, WebSocket]:
    async with state_lock:
        if not browser_clients:
            raise RuntimeError(
                "No CodeWebChat browser connected. Load the CodeWebChat browser extension and open chatgpt.com."
            )
        if TARGET_BROWSER_ID:
            wanted = int(TARGET_BROWSER_ID)
            browser = browser_clients.get(wanted)
            if browser is None:
                raise RuntimeError(f"Configured browser id {wanted} is not connected")
            return wanted, browser
        browser_id = sorted(browser_clients)[-1]
        return browser_id, browser_clients[browser_id]


def _get_browser_lock(browser_id: int) -> asyncio.Lock:
    lock = browser_locks.get(browser_id)
    if lock is None:
        lock = asyncio.Lock()
        browser_locks[browser_id] = lock
    return lock


async def query_chatgpt_embedded(prompt: str, session_id: str | None, new_session: bool) -> str:
    if not prompt:
        raise RuntimeError("No prompt text was supplied")

    browser_id, browser = await _select_embedded_browser()
    client_id = await _next_client_id()
    lock = _get_browser_lock(browser_id)
    async with lock:
        loop = asyncio.get_running_loop()
        future: asyncio.Future[str] = loop.create_future()
        pending_responses[client_id] = (browser_id, future)

        try:
            log(
                "sending initialize-chat "
                f"client_id={client_id} browser_id={browser_id} session_id={session_id or '-'} "
                f"new_session={new_session} prompt_chars={len(prompt)}"
            )
            await browser.send_text(
                json.dumps(
                    {
                        "action": "initialize-chat",
                        "client_id": client_id,
                        "target_browser_id": browser_id,
                        "text": prompt,
                        "url": os.getenv("CHATGPT_BROWSER_CHAT_URL", "https://chatgpt.com/"),
                        "raw_instructions": "",
                        "edit_format": "none",
                        "prompt_type": "edit-context",
                        "session_id": session_id,
                        "new_session": new_session,
                    }
                )
            )
            response = clean_response_text(await asyncio.wait_for(future, timeout=REQUEST_TIMEOUT))
            if not response.strip():
                raise RuntimeError("ChatGPT browser returned an empty response")
            log(f"received response client_id={client_id} response_chars={len(response)}")
            return response
        finally:
            pending_responses.pop(client_id, None)


def _codex_request_from_chat(body: dict[str, Any]) -> dict[str, Any]:
    messages = body.get("messages", [])
    if not isinstance(messages, list):
        messages = []
    instructions, input_items = messages_to_responses_input(messages)
    if not input_items:
        prompt = body.get("prompt") or body.get("input") or ""
        input_items = [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": str(prompt)}],
            }
        ]
    request_body: dict[str, Any] = {
        "model": JS_UPSTREAM_MODEL,
        "instructions": instructions or "You are a helpful coding assistant.",
        "input": input_items,
        "tools": body.get("tools") or [],
        "tool_choice": body.get("tool_choice", "auto"),
        "parallel_tool_calls": bool(body.get("parallel_tool_calls", False)),
        "store": False,
        "stream": True,
        "include": [],
    }
    if body.get("reasoning"):
        request_body["reasoning"] = body["reasoning"]
    return request_body


def _parse_codex_sse(raw: str) -> tuple[str, list[dict[str, Any]]]:
    text_parts: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    seen_tool_ids: set[str] = set()

    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            continue
        event_type = event.get("type")
        if event_type == "response.output_text.delta" and isinstance(event.get("delta"), str):
            text_parts.append(event["delta"])
        item = event.get("item") if isinstance(event.get("item"), dict) else {}
        if item.get("type") == "function_call":
            call_id = str(item.get("call_id") or item.get("id") or f"call_{uuid.uuid4().hex}")
            if call_id in seen_tool_ids:
                continue
            seen_tool_ids.add(call_id)
            raw_args = item.get("arguments", {})
            if isinstance(raw_args, str):
                try:
                    args = json.loads(raw_args) if raw_args else {}
                except json.JSONDecodeError:
                    args = {"raw": raw_args}
            elif isinstance(raw_args, dict):
                args = raw_args
            else:
                args = {}
            tool_calls.append(
                {
                    "id": call_id,
                    "name": str(item.get("name") or ""),
                    "arguments": args,
                }
            )
        if event_type == "response.output_item.done" and isinstance(item.get("content"), list):
            for content in item["content"]:
                if isinstance(content, dict) and isinstance(content.get("text"), str):
                    text_parts.append(content["text"])

    return clean_response_text("".join(text_parts)), [call for call in tool_calls if call["name"]]


async def query_chatgpt_api_embedded(body: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    browser_id, browser = await _select_embedded_browser()
    client_id = await _next_client_id()
    lock = _get_browser_lock(browser_id)
    async with lock:
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        pending_api_responses[client_id] = (browser_id, future)
        request_body = _codex_request_from_chat(body)
        try:
            log(
                "sending chatgpt-api-fetch "
                f"client_id={client_id} browser_id={browser_id} url={JS_API_URL} "
                f"body_chars={len(json.dumps(request_body, ensure_ascii=False))}"
            )
            await browser.send_text(
                json.dumps(
                    {
                        "action": "chatgpt-api-fetch",
                        "client_id": client_id,
                        "url": JS_API_URL,
                        "method": "POST",
                        "headers": {
                            "accept": "text/event-stream",
                            "content-type": "application/json",
                            "openai-beta": "responses=experimental",
                            "originator": "codex_cli_rs",
                        },
                        "body": json.dumps(request_body, ensure_ascii=False),
                    }
                )
            )
            response = await asyncio.wait_for(future, timeout=REQUEST_TIMEOUT)
            status = int(response.get("status", 0))
            raw_body = str(response.get("body", ""))
            if not response.get("ok"):
                raise RuntimeError(f"ChatGPT browser JS API returned HTTP {status}: {raw_body[:1000]}")
            text, tool_calls = _parse_codex_sse(raw_body)
            if not text and not tool_calls:
                raise RuntimeError(f"ChatGPT browser JS API returned no parseable output: {raw_body[:1000]}")
            log(
                f"received chatgpt-api-response client_id={client_id} "
                f"status={status} text_chars={len(text)} tool_calls={len(tool_calls)}"
            )
            return text, tool_calls
        finally:
            pending_api_responses.pop(client_id, None)


async def query_chatgpt(prompt: str, session_id: str | None, new_session: bool) -> str:
    if WS_URL.lower() in ("", "embedded", "internal"):
        return await query_chatgpt_embedded(prompt, session_id, new_session)
    return await query_chatgpt_external(prompt, session_id, new_session)


def _usage(prompt: str, response: str) -> dict[str, int]:
    prompt_tokens = max(1, len(prompt.split()))
    completion_tokens = max(1, len(response.split()))
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
    }


def _responses_usage(prompt: str, response: str) -> dict[str, int]:
    input_tokens = max(1, len(prompt.split()))
    output_tokens = max(1, len(response.split()))
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
    }


def _status_for_exception(exc: Exception) -> int:
    if isinstance(exc, UnsupportedRequestError):
        return 400
    if isinstance(exc, asyncio.TimeoutError):
        return 504
    msg = str(exc).lower()
    if "no codewebchat browser" in msg or "no browser connected" in msg:
        return 503
    if "timed out" in msg:
        return 504
    return 502


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "ws_url": WS_URL,
        "auth_enabled": bool(API_KEY),
        "connected_browsers": sorted(browser_clients),
        "pending_requests": len(pending_responses),
        "pending_api_requests": len(pending_api_responses),
        "active_sessions": len(session_states),
    }


@app.get("/ready")
async def ready() -> dict[str, Any]:
    if not browser_clients:
        raise HTTPException(
            status_code=503,
            detail="No CodeWebChat browser connected. Load the extension and open chatgpt.com.",
        )
    return {"status": "ready", "connected_browsers": sorted(browser_clients)}


@app.on_event("startup")
async def startup() -> None:
    global ping_task
    _load_session_states()
    if ping_task is None:
        ping_task = asyncio.create_task(_ping_browsers())


@app.on_event("shutdown")
async def shutdown() -> None:
    global ping_task
    _save_session_states()
    if ping_task is not None:
        ping_task.cancel()
        ping_task = None


async def _ping_browsers() -> None:
    while True:
        await asyncio.sleep(PING_INTERVAL)
        async with state_lock:
            clients = list(browser_clients.items())
        for browser_id, browser in clients:
            try:
                await browser.send_text(json.dumps({"action": "ping"}))
            except Exception as exc:
                log(f"browser ping failed browser_id={browser_id}: {exc}")


@app.websocket("/")
async def codewebchat_websocket(websocket: WebSocket) -> None:
    global browser_counter

    token = websocket.query_params.get("token")
    if token not in (BROWSER_WS_TOKEN, WS_TOKEN):
        await websocket.close(code=1008, reason="Invalid security token")
        return

    await websocket.accept()
    is_browser = token == BROWSER_WS_TOKEN

    if not is_browser:
        client_id = await _next_client_id()
        await websocket.send_text(json.dumps({"action": "client-id-assignment", "client_id": client_id}))
        await websocket.send_text(
            json.dumps(
                {
                    "action": "browser-connection-status",
                    "connected_browsers": [
                        {"id": bid, "version": "embedded", "user_agent": "unknown"}
                        for bid in sorted(browser_clients)
                    ],
                }
            )
        )
        return

    async with state_lock:
        browser_counter += 1
        browser_id = browser_counter
        browser_clients[browser_id] = websocket

    log(f"browser connected browser_id={browser_id}")
    await websocket.send_text(json.dumps({"action": "connected", "id": browser_id}))

    try:
        while True:
            raw = await websocket.receive_text()
            data = json.loads(raw)
            log(f"browser message action={data.get('action')} client_id={data.get('client_id')} keys={sorted(data.keys())}")
            if data.get("action") == "apply-chat-response":
                client_id = int(data.get("client_id", 0))
                pending = pending_responses.get(client_id)
                future = pending[1] if pending else None
                if future and not future.done():
                    future.set_result(str(data.get("response", "")))
            elif data.get("action") == "chatgpt-api-response":
                client_id = int(data.get("client_id", 0))
                pending = pending_api_responses.get(client_id)
                future = pending[1] if pending else None
                if future and not future.done():
                    future.set_result(data)
    except WebSocketDisconnect:
        pass
    finally:
        log(f"browser disconnected browser_id={browser_id}")
        async with state_lock:
            if browser_clients.get(browser_id) is websocket:
                browser_clients.pop(browser_id, None)
                browser_locks.pop(browser_id, None)
            for client_id, (pending_browser_id, future) in list(pending_responses.items()):
                if pending_browser_id == browser_id and not future.done():
                    future.set_exception(RuntimeError(f"Browser {browser_id} disconnected before responding"))
            for client_id, (pending_browser_id, future) in list(pending_api_responses.items()):
                if pending_browser_id == browser_id and not future.done():
                    future.set_exception(RuntimeError(f"Browser {browser_id} disconnected before API response"))


@app.get("/v1/models")
async def models(request: Request) -> JSONResponse:
    if not _auth_ok(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    return JSONResponse(
        {
            "object": "list",
            "data": [
                {
                    "id": MODEL_NAME,
                    "object": "model",
                    "created": 0,
                    "owned_by": "chatgpt-browser",
                },
                {
                    "id": JS_MODEL_NAME,
                    "object": "model",
                    "created": 0,
                    "owned_by": "chatgpt-browser-js",
                },
            ],
        }
    )


async def _handle_request(request: Request, body: dict[str, Any], is_responses_api: bool) -> dict[str, Any]:
    """Core request handling with session tracking."""
    if not _auth_ok(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    try:
        session_id, new_session = _extract_session_controls(request, body)
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

    try:
        prompt, do_new_session = _build_prompt_for_session(session_id, new_session, body)
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc
    return {
        "prompt": prompt,
        "session_id": session_id,
        "new_session": do_new_session,
    }


async def _chat_completions_impl(request: Request):
    body = await request.json()
    model = body.get("model", MODEL_NAME)
    if model == JS_MODEL_NAME:
        if not _auth_ok(request):
            raise HTTPException(status_code=401, detail="Unauthorized")
        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        try:
            response_text, tool_calls = await query_chatgpt_api_embedded(body)
        except Exception as exc:
            raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

        if body.get("stream", False):
            async def event_stream():
                if tool_calls:
                    delta = {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "index": i,
                                "id": call["id"],
                                "type": "function",
                                "function": {
                                    "name": call["name"],
                                    "arguments": json.dumps(call["arguments"], ensure_ascii=False),
                                },
                            }
                            for i, call in enumerate(tool_calls)
                        ],
                    }
                    finish_reason = "tool_calls"
                else:
                    delta = {"role": "assistant", "content": response_text}
                    finish_reason = "stop"
                yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]})}\n\n"
                yield f"data: {json.dumps({'id': completion_id, 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish_reason}]})}\n\n"
                yield "data: [DONE]\n\n"

            return StreamingResponse(event_stream(), media_type="text/event-stream")

        message: dict[str, Any] = {"role": "assistant", "content": None if tool_calls else response_text}
        finish_reason = "tool_calls" if tool_calls else "stop"
        if tool_calls:
            message["tool_calls"] = [
                {
                    "id": call["id"],
                    "type": "function",
                    "function": {
                        "name": call["name"],
                        "arguments": json.dumps(call["arguments"], ensure_ascii=False),
                    },
                }
                for call in tool_calls
            ]
        return JSONResponse(
            {
                "id": completion_id,
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
                "usage": _usage(messages_to_prompt(body.get("messages", [])), response_text),
            }
        )

    req_info = await _handle_request(request, body, is_responses_api=False)
    prompt = req_info["prompt"]
    session_id = req_info["session_id"]
    do_new_session = req_info["new_session"]

    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created = int(time.time())

    try:
        response_text = clean_response_text(await query_chatgpt(prompt, session_id, do_new_session))
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

    _store_response(session_id, response_text)
    tool_calls = parse_tool_calls(response_text)
    if tool_calls:
        log(f"parsed {len(tool_calls)} tool call(s) for chat completion session {session_id[:20]}...")

    if body.get("stream", False):
        async def event_stream():
            if tool_calls:
                delta = {
                    "role": "assistant",
                    "tool_calls": [
                        {
                            "index": i,
                            "id": call["id"],
                            "type": "function",
                            "function": {
                                "name": call["name"],
                                "arguments": json.dumps(call["arguments"], ensure_ascii=False),
                            },
                        }
                        for i, call in enumerate(tool_calls)
                    ],
                }
                finish_reason = "tool_calls"
            else:
                delta = {"role": "assistant", "content": response_text}
                finish_reason = "stop"
            first = {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "session_id": session_id,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                }
            stop = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
            }
            yield f"data: {json.dumps(first)}\n\n"
            yield f"data: {json.dumps(stop)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(event_stream(), media_type="text/event-stream")

    message: dict[str, Any] = {"role": "assistant", "content": None if tool_calls else response_text}
    finish_reason = "tool_calls" if tool_calls else "stop"
    if tool_calls:
        message["tool_calls"] = [
            {
                "id": call["id"],
                "type": "function",
                "function": {
                    "name": call["name"],
                    "arguments": json.dumps(call["arguments"], ensure_ascii=False),
                },
            }
            for call in tool_calls
        ]

    return JSONResponse(
        {
            "id": completion_id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "session_id": session_id,
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": finish_reason,
                }
            ],
            "usage": _usage(prompt, response_text),
        }
    )


@app.post("/v1/chat/completions", response_model=None)
async def chat_completions(request: Request):
    return await _chat_completions_impl(request)


@app.post("/chat/completions", response_model=None)
async def chat_completions_without_v1(request: Request):
    return await _chat_completions_impl(request)


@app.post("/v1/responses", response_model=None)
async def responses(request: Request):
    body = await request.json()

    req_info = await _handle_request(request, body, is_responses_api=True)
    prompt = req_info["prompt"]
    session_id = req_info["session_id"]
    do_new_session = req_info["new_session"]

    created = int(time.time())
    response_id = f"resp_{uuid.uuid4().hex}"

    try:
        response_text = clean_response_text(await query_chatgpt(prompt, session_id, do_new_session))
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

    _store_response(session_id, response_text)
    tool_calls = parse_tool_calls(response_text)
    if tool_calls:
        log(f"parsed {len(tool_calls)} tool call(s) for responses session {session_id[:20]}...")

    if body.get("stream", False):
        async def event_stream():
            yield f"data: {json.dumps({'type': 'response.created', 'response': {'id': response_id, 'status': 'in_progress'}})}\n\n"
            if tool_calls:
                for call in tool_calls:
                    item = {
                        "type": "function_call",
                        "call_id": call["id"],
                        "name": call["name"],
                        "arguments": json.dumps(call["arguments"], ensure_ascii=False),
                    }
                    yield f"data: {json.dumps({'type': 'response.output_item.added', 'item': item})}\n\n"
            else:
                yield f"data: {json.dumps({'type': 'response.output_text.delta', 'delta': response_text})}\n\n"
            yield f"data: {json.dumps({'type': 'response.completed', 'response': {'id': response_id, 'status': 'completed'}})}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(event_stream(), media_type="text/event-stream")

    output = [
        {
            "id": call["id"],
            "type": "function_call",
            "call_id": call["id"],
            "name": call["name"],
            "arguments": json.dumps(call["arguments"], ensure_ascii=False),
            "status": "completed",
        }
        for call in tool_calls
    ] or [
        {
            "id": f"msg_{uuid.uuid4().hex}",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": response_text}],
        }
    ]

    return JSONResponse(
        {
            "id": response_id,
            "object": "response",
            "created_at": created,
            "model": body.get("model", MODEL_NAME),
            "status": "completed",
            "session_id": session_id,
            "output": output,
            "output_text": "" if tool_calls else response_text,
            "usage": _responses_usage(prompt, response_text),
        }
    )


if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host=os.getenv("CHATGPT_BROWSER_HOST", "0.0.0.0"),
        port=int(os.getenv("CHATGPT_BROWSER_PORT", "8080")),
        log_level=os.getenv("CHATGPT_BROWSER_LOG_LEVEL", "info"),
    )
