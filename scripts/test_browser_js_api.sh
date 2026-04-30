#!/usr/bin/env bash
# Smoke test for chatgpt-browser-js: proxy -> extension background fetch().
set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
PROXY_URL="${CHATGPT_BROWSER_PROXY_URL:-http://localhost:18080}"
MASTER_KEY="${LITELLM_MASTER_KEY:-sk-proxy-local}"
PROXY_KEY="${CHATGPT_BROWSER_API_KEY:-sk-chatgpt-browser-local}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsS "$PROXY_URL/ready" >/dev/null

if ! curl -fsS "$PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $PROXY_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt-browser-js","session_id":"browser-js-smoke","messages":[{"role":"user","content":"Reply with exactly: browser-js-ok"}],"stream":false}' \
  > "$tmp"; then
  echo "Direct chatgpt-browser-js failed. Check proxy logs before retrying; LiteLLM retries can burn browser limits." >&2
  exit 1
fi

python3 - "$tmp" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
text = data.get("choices", [{}])[0].get("message", {}).get("content")
if text != "browser-js-ok":
    raise SystemExit(f"unexpected direct response: {text!r}\n{json.dumps(data)[:1000]}")
print("PASS direct chatgpt-browser-js text")
PY

curl -fsS "$LITELLM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt-browser-js","messages":[{"role":"user","content":"Reply with exactly: browser-js-ok"}],"stream":false}' \
  > "$tmp"

python3 - "$tmp" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
text = data.get("choices", [{}])[0].get("message", {}).get("content")
if text != "browser-js-ok":
    raise SystemExit(f"unexpected LiteLLM response: {text!r}\n{json.dumps(data)[:1000]}")
print("PASS LiteLLM chatgpt-browser-js text")
PY
