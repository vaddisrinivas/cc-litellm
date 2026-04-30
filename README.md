# cc-litellm

Local-only Claude Code / `claude -p` routing through LiteLLM, with Azure AI
Foundry as the main provider surface.

For now, installation is Claude-only. The scripts use an explicit target (`claude`)
so a Codex target can be added later without changing the Claude behavior.

The only thing installed locally is a Docker Compose managed LiteLLM proxy on
`localhost:4000` plus a Claude `SessionStart` hook that keeps it alive. No
global shell env, Codex config, Cursor config, LaunchAgent, or local LiteLLM
Python runtime is required.

## Routing

LiteLLM receives Claude model names and maps them to your configured local
provider policy:

- Opus-level: `claude-opus-4-6`, `gpt-5.5` -> Kimi on Azure AI Foundry
- Sonnet / Codex-level: `claude-sonnet-4-6`, `gpt-5.3-codex`, `gpt-5.4` -> GLM
- Lightweight/default routes: `claude-haiku-4-5`, `gpt-5.2`, `gpt-54-nano` -> Azure AI Foundry / Azure OpenAI `gpt-54-nano`
- Optional browser-backed provider: `chatgpt-browser` -> local OpenAI-compatible shim -> CodeWebChat -> logged-in `chatgpt.com`
- Optional browser-JS API provider: `chatgpt-browser-js` -> local shim -> CodeWebChat extension background `fetch()` -> `chatgpt.com/backend-api`
- Optional direct Codex OAuth provider: `chatgpt-browser-api` -> LiteLLM -> `codex-proxy` -> `chatgpt.com/backend-api/codex/responses`

## Requirements

- Claude Code / Claude CLI
- Docker Desktop
- Azure AI Foundry key and endpoints for Kimi and `gpt-54-nano`
- Z.ai key for GLM
- Optional for `chatgpt-browser`: CodeWebChat browser extension connected to a logged-in ChatGPT tab
- Optional for `chatgpt-browser-js`: the patched CodeWebChat browser extension connected to a logged-in ChatGPT tab
- Optional for `chatgpt-browser-api`: Codex/ChatGPT OAuth present at `~/.codex/auth.json`

## Install

```bash
bash install.sh claude
```

The install script:

1. Creates or updates `~/.config/cc-litellm/.env`
2. Ensures Docker Desktop is running
3. Writes only Claude settings in `~/.claude/settings.json`
4. Adds a Claude `SessionStart` hook to keep Docker Compose LiteLLM running
5. Starts LiteLLM on `http://localhost:4000` and the optional ChatGPT browser shim on `http://localhost:18080`

It does not write Codex config, Cursor config, `launchctl`, or shell startup files.
Plain `claude -p` uses the configured Claude default, `opus[1m]`, which maps
to Kimi. Delegation wrappers should pass `--model claude-sonnet-4-6` explicitly
when they want the faster GLM route.

## Credentials

Fill in `~/.config/cc-litellm/.env`:

```env
AZURE_AI_FOUNDRY_API_KEY=your-azure-ai-foundry-api-key
AZURE_AI_FOUNDRY_KIMI_API_BASE=https://your-resource.services.ai.azure.com/projects/your-project/deployments/kimi-k-2-6
AZURE_AI_FOUNDRY_NANO_API_BASE=https://your-resource.openai.azure.com/
AZURE_AI_FOUNDRY_API_VERSION=2025-04-01-preview
LITELLM_MASTER_KEY=sk-proxy-local
DISABLE_ADMIN_UI=true
ZAI_API_KEY=your-zai-api-key

# Optional browser provider
CHATGPT_BROWSER_API_BASE=http://chatgpt-browser-proxy:8080/v1
CHATGPT_BROWSER_API_KEY=sk-chatgpt-browser-local
CHATGPT_BROWSER_WS_URL=embedded
CHATGPT_BROWSER_WS_TOKEN=gemini-coder-vscode
CHATGPT_BROWSER_EXTENSION_WS_TOKEN=gemini-coder
CHATGPT_BROWSER_PING_INTERVAL=10
CHATGPT_BROWSER_NEW_SESSION_PER_REQUEST=0
CHATGPT_BROWSER_COMPACT_EVERY=30
CHATGPT_BROWSER_SESSION_STATE_PATH=/data/session_state.json

# Optional browser-JS API provider
CHATGPT_BROWSER_JS_MODEL=chatgpt-browser-js
CHATGPT_BROWSER_JS_API_MODE=conversation
CHATGPT_BROWSER_JS_UPSTREAM_MODEL=auto
CHATGPT_BROWSER_JS_API_URL=https://chatgpt.com/backend-api/conversation

# Optional direct API provider
CHATGPT_BROWSER_API_DIRECT_BASE=http://codex-oauth-proxy:8080/v1
CHATGPT_BROWSER_API_DIRECT_KEY=pwd
```

`LITELLM_MASTER_KEY` can be any local token. Claude uses it as
`ANTHROPIC_AUTH_TOKEN` when talking to the local LiteLLM proxy.
The LiteLLM Admin UI is disabled by default. Current LiteLLM UI login writes
admin session state through the LiteLLM database layer, and this project stays
local-only without Postgres. The OpenAI/Anthropic-compatible proxy APIs still
work normally on `http://localhost:4000`.

## Proxy

The `SessionStart` hook starts LiteLLM automatically through Docker Compose:

```bash
docker compose --env-file ~/.config/cc-litellm/.env up -d
```
Keep Docker Desktop running.

## Optional ChatGPT Browser Provider

`chatgpt-browser` is an explicit model alias. It is not the default and is not a fallback for Opus/Kimi. No model name or route resolves to `chatgpt-browser` unless the caller explicitly requests `model=chatgpt-browser`.

It uses CodeWebChat's existing browser harness:

1. Install and build CodeWebChat:

   ```bash
   bash scripts/setup_codewebchat.sh
   ```

2. Load the CodeWebChat browser extension in Chrome from:

   ```text
   ~/.config/cc-litellm/CodeWebChat/apps/browser/dist
   ```

   If you cloned CodeWebChat somewhere else, load the `apps/browser/dist`
   directory from that clone instead.

3. Open `https://chatgpt.com` and log in
4. Run `bash install.sh claude` so Docker rebuilds and starts the local shim
5. Confirm the shim is ready with `curl http://localhost:18080/ready`

The Docker shim exposes a CodeWebChat-compatible WebSocket endpoint on
`ws://localhost:55155`. In the default `CHATGPT_BROWSER_WS_URL=embedded` mode,
that endpoint is provided by this project's Docker shim, so the browser
extension connects directly here. You do not need to run CodeWebChat's original
VS Code/editor WebSocket server unless you set `CHATGPT_BROWSER_WS_URL` to an
external server.

Session behavior:

- `CHATGPT_BROWSER_REQUEST_TIMEOUT` is the maximum wait for a browser response;
  the default is 300 seconds.
- `CHATGPT_BROWSER_PING_INTERVAL` is only the WebSocket keepalive cadence for
  the browser extension; the default is 10 seconds.
- By default, requests without a session id reuse a stable derived browser
  session for the caller/model/metadata. This preserves continuity for clients
  like Claude/LiteLLM that do not always pass a custom session id.
- To resume a browser chat, pass the same session id using either
  `X-Session-Id`, `X-ChatGPT-Browser-Session-Id`, request body `session_id`,
  `conversation_id`, `metadata.session_id`, `metadata.conversation_id`, or
  `metadata.claude_session_id`.
- To force a fresh ChatGPT tab, pass `new_session: true` or
  `X-New-Session: true`. To make every request fresh, set
  `CHATGPT_BROWSER_NEW_SESSION_PER_REQUEST=1`.
- The proxy sends full history only on the first request for a browser session.
  Later requests send only new messages; every `CHATGPT_BROWSER_COMPACT_EVERY`
  turns it refreshes the browser prompt with compacted context.
- Session history is persisted in the `chatgpt_browser_state` Docker volume at
  `CHATGPT_BROWSER_SESSION_STATE_PATH`, so derived browser sessions survive
  container restarts.
- Streaming is OpenAI-compatible but currently emitted after the browser
  response completes; token-level streaming depends on deeper ChatGPT DOM
  streaming support.
- Tool calling is best-effort for this browser-backed route. The shim injects
  OpenAI tool schemas into the prompt, asks ChatGPT for a strict
  `{"tool_calls":[{"name":"...","arguments":{...}}]}` envelope, and maps a
  parseable envelope back to OpenAI-compatible `tool_calls` or Responses API
  `function_call` items. If ChatGPT returns plain text instead of that envelope,
  the shim returns the text normally with no `tool_calls`. Native Claude Code
  tool execution remains strongest on the Kimi/GLM/nano routes.

`chatgpt-browser-js` uses the same extension connection, but instead of typing
into the ChatGPT DOM it sends a WebSocket request to the extension background
service worker. The extension calls `fetch()` against
`CHATGPT_BROWSER_JS_API_URL` with `credentials: "include"`, so the request uses
the logged-in browser session. The default mode is ChatGPT's web conversation
endpoint (`/backend-api/conversation`) with `model=auto`; the proxy persists the
returned `conversation_id` and parent message id in
`CHATGPT_BROWSER_SESSION_STATE_PATH` so restart/resume can keep following the
same browser API thread. Set `CHATGPT_BROWSER_JS_API_MODE=codex` and point
`CHATGPT_BROWSER_JS_API_URL` at `/backend-api/codex/responses` only if you have
an auth path that endpoint accepts. Current ChatGPT web traffic also carries
Sentinel/conduit headers; the patched extension caches those headers from real
ChatGPT page traffic and reuses the safe subset for browser-JS fetches. After a
fresh extension reload, send one normal message in ChatGPT first if the JS route
returns `Unusual activity`. Reload the unpacked Chrome extension after running
`bash scripts/setup_codewebchat.sh`, because Manifest V3 host permissions and
background code do not hot-reload automatically.

Smoke test the local shim directly:

```bash
curl http://localhost:18080/health
curl http://localhost:18080/v1/chat/completions \
  -H 'Authorization: Bearer sk-chatgpt-browser-local' \
  -H 'Content-Type: application/json' \
  -d '{"model":"chatgpt-browser","session_id":"demo","messages":[{"role":"user","content":"Say ok"}]}'
```

Smoke test through LiteLLM:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-proxy-local' \
  -H 'Content-Type: application/json' \
  -d '{"model":"chatgpt-browser","messages":[{"role":"user","content":"Say ok"}]}'
```

## Optional Direct ChatGPT/Codex API Provider

`chatgpt-browser-api` is a separate explicit model alias. It does not use the
Chrome extension or the ChatGPT DOM. It uses
[`icebear0828/codex-proxy`](https://github.com/icebear0828/codex-proxy) inside
Docker, imports the local Codex CLI OAuth token from `~/.codex/auth.json`, and
exposes an OpenAI-compatible API to LiteLLM.

Use this route when tool calls matter. In local testing it returned native
OpenAI `tool_calls` for an OpenAI `tools` request, while the DOM-backed
`chatgpt-browser` route can only shape tool calls by prompt and parse JSON back
out of normal ChatGPT text.

Start/import:

```bash
bash scripts/import_codex_oauth.sh
docker compose --env-file ~/.config/cc-litellm/.env up -d
```

Smoke test direct:

```bash
curl http://localhost:18889/v1/chat/completions \
  -H 'Authorization: Bearer pwd' \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Reply exactly: ok"}]}'
```

Smoke test through LiteLLM:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-proxy-local' \
  -H 'Content-Type: application/json' \
  -d '{"model":"chatgpt-browser-api","messages":[{"role":"user","content":"Reply exactly: ok"}]}'
```

The `codex_oauth_proxy_data` Docker volume persists imported account state.
If the token expires or you log out of Codex, run
`bash scripts/import_codex_oauth.sh` again after refreshing Codex auth.

## Test Gates

`scripts/test_e2e.sh` is mode-based so normal validation does not burn
ChatGPT browser quota:

```bash
# No ChatGPT calls. Use this before every commit.
TEST_MODE=offline bash scripts/test_e2e.sh

# Small pre-post sanity check: direct browser, LiteLLM, Claude browser.
TEST_MODE=smoke bash scripts/test_e2e.sh

# Full launch gate after a cooldown.
TEST_MODE=launch BROWSER_TEST_DELAY_SECONDS=30 MAX_BROWSER_CALLS=20 bash scripts/test_e2e.sh
```

The default mode is `offline`. Browser modes enforce a call budget with
`MAX_BROWSER_CALLS` and skip remaining browser-heavy tests if a response looks
rate-limited.

## Privacy

Do not paste raw logs into public issues without checking them first. Docker
logs, `~/.config/cc-litellm` logs, Claude debug output, and browser-provider
responses can include local paths, session identifiers, prompts, or provider
error text. Redact personal paths, account identifiers, and tokens before
sharing.

If you want to use CodeWebChat's original editor-side WebSocket server instead
of the embedded bridge, set `CHATGPT_BROWSER_WS_URL` in
`~/.config/cc-litellm/.env` to something like
`ws://host.docker.internal:55155`.

## Uninstall

```bash
bash uninstall.sh claude
```

This removes the cc-litellm Claude hook and Claude proxy environment from
`~/.claude/settings.json`, stops the local proxy, and leaves credentials in
`~/.config/cc-litellm/.env`.

## Troubleshooting

```bash
tail -f ~/.config/cc-litellm/litellm.log
docker compose logs litellm
docker compose logs chatgpt-browser-proxy
grep -A5 '"env"' ~/.claude/settings.json
```
