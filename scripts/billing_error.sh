#!/usr/bin/env bash
# Fired by Claude Code's StopFailure/billing_error hook.
# Switches Claude Code to use the LiteLLM proxy and notifies the user.

PROXY_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SETTINGS="$HOME/.claude/settings.json"

# Read master key from .env if available, otherwise use default
MASTER_KEY="sk-proxy-local"
if [[ -f "$PROXY_DIR/.env" ]]; then
  MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "$PROXY_DIR/.env" | cut -d= -f2 | tr -d '"' || echo "sk-proxy-local")
  MASTER_KEY="${MASTER_KEY:-sk-proxy-local}"
fi

# Inject proxy env vars into settings.json
python3 - "$SETTINGS" "$MASTER_KEY" <<'EOF'
import sys, json

path, master_key = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_AUTH_TOKEN": master_key
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF

# macOS notification
osascript -e 'display notification "Anthropic credits exhausted — switched to Azure AI. Restart Claude Code." with title "Claude Code — Out of Credits" sound name "Basso"'
