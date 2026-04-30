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
from typing import Any

import uvicorn
import websockets
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse


MODEL_NAME = os.getenv("CHATGPT_BROWSER_MODEL", "chatgpt-browser")
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
browser_counter = 0
client_counter = 0
state_lock = asyncio.Lock()
ping_task: asyncio.Task[None] | None = None


def log(message: str) -> None:
    print(f"[chatgpt-browser-proxy] {message}", flush=True)


def _auth_ok(request: Request) -> bool:
    if not API_KEY:
        return True
    header = request.headers.get("authorization", "")
    return header == f"Bearer {API_KEY}"


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


def messages_to_prompt(messages: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for message in messages:
        role = message.get("role", "user")
        content = _content_to_text(message.get("content"))
        if not content:
            continue
        if role == "system":
            parts.append(f"[System]\n{content}")
        elif role == "assistant":
            parts.append(f"[Assistant]\n{content}")
        elif role == "tool":
            parts.append(f"[Tool result]\n{content}")
        else:
            parts.append(content)
    return "\n\n".join(parts).strip()


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
    """Preserve optional OpenAI client contracts as plain prompt context.

    Browser ChatGPT does not expose a real tool-call API to us. Passing these
    fields through as explicit context is the honest compatibility fallback:
    useful for advisory calls, not equivalent to native structured tool use.
    """
    extras: list[str] = []
    if body.get("tools"):
        tool_choice = body.get("tool_choice", "auto")
        extras.append(
            "[Available tool schemas]\n"
            "The caller supplied structured tool schemas. Tool calling is handled outside ChatGPT. "
            "If a tool is needed, do not describe or simulate the result. Return only strict JSON in this shape:\n"
            '{"tool_calls":[{"name":"tool_name","arguments":{}}]}\n'
            "If no tool is needed, answer normally. "
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
            continue
        if isinstance(value, dict):
            return value
    return None


def parse_tool_calls(text: str) -> list[dict[str, Any]]:
    value = _extract_json_object(text)
    if not value:
        return []
    raw_calls = value.get("tool_calls") or value.get("tools") or []
    if isinstance(value.get("name"), str):
        raw_calls = [value]
    if not isinstance(raw_calls, list):
        return []

    calls: list[dict[str, Any]] = []
    for raw in raw_calls:
        if not isinstance(raw, dict):
            continue
        fn = raw.get("function") if isinstance(raw.get("function"), dict) else raw
        name = fn.get("name")
        arguments = fn.get("arguments", {})
        if not name:
            continue
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
    return re.sub(r"^\s*Thought for (?:a second|\d+ seconds?)\s*", "", text).strip()


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).lower() in ("1", "true", "yes", "y", "on")


def _stable_session_id(request: Request, body: dict[str, Any]) -> str:
    """Derive a stable browser session when Claude/LiteLLM omit one.

    Claude Code sends large Responses API requests without our custom
    session_id fields. Reusing one tab per caller/model/cwd-ish metadata keeps
    multi-turn continuity without using OpenAI's `user` field as identity.
    """
    metadata = body.get("metadata") if isinstance(body.get("metadata"), dict) else {}
    seed = {
        "model": body.get("model", MODEL_NAME),
        "claude_session_id": metadata.get("claude_session_id"),
        "conversation_id": metadata.get("conversation_id"),
        "cwd": metadata.get("cwd") or metadata.get("working_directory"),
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
    if ping_task is None:
        ping_task = asyncio.create_task(_ping_browsers())


@app.on_event("shutdown")
async def shutdown() -> None:
    global ping_task
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
                }
            ],
        }
    )


async def _chat_completions_impl(request: Request):
    if not _auth_ok(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    body = await request.json()
    model = body.get("model", MODEL_NAME)
    try:
        prompt = body_to_prompt(body)
        session_id, new_session = _extract_session_controls(request, body)
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc
    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created = int(time.time())

    try:
        response_text = clean_response_text(await query_chatgpt(prompt, session_id, new_session))
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

    tool_calls = parse_tool_calls(response_text) if body.get("tools") else []

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
    if not _auth_ok(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    body = await request.json()
    try:
        raw_input = body.get("input", "")
        input_body: dict[str, Any] = {
            "messages": raw_input if isinstance(raw_input, list) else [{"role": "user", "content": raw_input}]
        }
        if body.get("tools"):
            input_body["tools"] = body["tools"]
            input_body["tool_choice"] = body.get("tool_choice", "auto")
        if body.get("response_format"):
            input_body["response_format"] = body["response_format"]
        prompt = body_to_prompt(input_body)
        session_id, new_session = _extract_session_controls(request, body)
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc
    created = int(time.time())
    response_id = f"resp_{uuid.uuid4().hex}"

    try:
        response_text = clean_response_text(await query_chatgpt(prompt, session_id, new_session))
    except Exception as exc:
        raise HTTPException(status_code=_status_for_exception(exc), detail=str(exc)) from exc

    tool_calls = parse_tool_calls(response_text) if body.get("tools") else []

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
