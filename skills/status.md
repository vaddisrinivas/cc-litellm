# cc-litellm Status

Check the cc-litellm proxy status, history, and Azure connectivity. Run the following checks and report results:

```bash
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
PLUGIN_ROOT=$(ls -d ~/.claude/plugins/cache/cc-litellm/cc-litellm/*/  2>/dev/null | sort -V | tail -1)

echo "=== PROXY ==="
if lsof -ti:4000 >/dev/null 2>&1; then
  CONFIG=$(pgrep -af "litellm.*--port 4000" 2>/dev/null | grep -o '\-\-config [^ ]*' | awk '{print $2}')
  echo "running — config: ${CONFIG:-docker/unknown}"
else
  echo "NOT running"
fi

echo ""
echo "=== ENV ==="
echo "ANTHROPIC_BASE_URL (launchctl): $(launchctl getenv ANTHROPIC_BASE_URL 2>/dev/null || echo 'not set')"
echo "ANTHROPIC_BASE_URL (shell):     ${ANTHROPIC_BASE_URL:-not set}"

echo ""
echo "=== AZURE TEST ==="
MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_HOME/.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
MASTER_KEY="${MASTER_KEY:-sk-proxy-local}"
RESP=$(curl -s --max-time 5 \
  -H "x-api-key: $MASTER_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  http://localhost:4000/v1/messages 2>&1)
if echo "$RESP" | grep -q '"content"'; then
  echo "OK — $(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null)"
else
  echo "FAIL — $RESP"
fi

echo ""
echo "=== HISTORY (last 10) ==="
tail -10 "$CONFIG_HOME/history.log" 2>/dev/null || echo "no history yet"

echo ""
echo "=== SESSION LOG (last 5) ==="
tail -5 "$CONFIG_HOME/session.log" 2>/dev/null || echo "no session log yet"
```

Run the bash block above using the Bash tool and present results clearly.
