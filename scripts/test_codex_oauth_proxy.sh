#!/usr/bin/env bash
# Smoke tests for the optional chatgpt-browser-api / codex-oauth-proxy route.
set -euo pipefail

CODEX_PROXY_URL="${CODEX_PROXY_URL:-http://localhost:18889}"
CODEX_PROXY_KEY="${CHATGPT_BROWSER_API_DIRECT_KEY:-pwd}"
LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
MASTER_KEY="${LITELLM_MASTER_KEY:-sk-proxy-local}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

need curl
need jq

tmp_text="$(mktemp)"
tmp_tool="$(mktemp)"
tmp_litellm="$(mktemp)"
tmp_litellm_tool="$(mktemp)"
trap 'rm -f "$tmp_text" "$tmp_tool" "$tmp_litellm" "$tmp_litellm_tool"' EXIT

curl -fsS "$CODEX_PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $CODEX_PROXY_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Reply with exactly: codex-proxy-ok"}],"stream":false}' \
  > "$tmp_text"

[[ "$(jq -r '.choices[0].message.content // empty' "$tmp_text")" == "codex-proxy-ok" ]] || {
  echo "direct codex proxy text test failed" >&2
  cat "$tmp_text" >&2
  exit 1
}
echo "PASS direct codex proxy text"

curl -fsS "$CODEX_PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $CODEX_PROXY_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Use echo_tool to say codex-tool-ok."}],"tools":[{"type":"function","function":{"name":"echo_tool","description":"Echo a string","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}}],"tool_choice":"auto","stream":false}' \
  > "$tmp_tool"

[[ "$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' "$tmp_tool")" == "echo_tool" ]] || {
  echo "direct codex proxy tool test failed" >&2
  cat "$tmp_tool" >&2
  exit 1
}
echo "PASS direct codex proxy tool_calls"

curl -fsS "$LITELLM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt-browser-api","messages":[{"role":"user","content":"Reply with exactly: litellm-codex-proxy-ok"}],"stream":false}' \
  > "$tmp_litellm"

[[ "$(jq -r '.choices[0].message.content // empty' "$tmp_litellm")" == "litellm-codex-proxy-ok" ]] || {
  echo "LiteLLM chatgpt-browser-api test failed" >&2
  cat "$tmp_litellm" >&2
  exit 1
}
echo "PASS LiteLLM chatgpt-browser-api text"

curl -fsS "$LITELLM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt-browser-api","messages":[{"role":"user","content":"Use echo_tool to say litellm-codex-tool-ok."}],"tools":[{"type":"function","function":{"name":"echo_tool","description":"Echo a string","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}}],"tool_choice":"auto","stream":false}' \
  > "$tmp_litellm_tool"

[[ "$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' "$tmp_litellm_tool")" == "echo_tool" ]] || {
  echo "LiteLLM chatgpt-browser-api tool test failed" >&2
  cat "$tmp_litellm_tool" >&2
  exit 1
}
echo "PASS LiteLLM chatgpt-browser-api tool_calls"
