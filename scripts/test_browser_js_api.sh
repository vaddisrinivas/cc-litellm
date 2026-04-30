#!/usr/bin/env bash
# Smoke test for chatgpt-browser-js: proxy -> extension background fetch().
set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
MASTER_KEY="${LITELLM_MASTER_KEY:-sk-proxy-local}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

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
    raise SystemExit(f"unexpected response: {text!r}\n{json.dumps(data)[:1000]}")
print("PASS LiteLLM chatgpt-browser-js text")
PY
