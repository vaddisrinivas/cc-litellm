#!/usr/bin/env bash
# Fired by Claude Code's StopFailure/billing_error hook.
# Switches Claude Code to use the LiteLLM proxy and notifies the user.

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"

# Read master key from config, fall back to default
MASTER_KEY="sk-proxy-local"
if [[ -f "$CONFIG_HOME/.env" ]]; then
  val=$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_HOME/.env" | cut -d= -f2 | tr -d '"')
  MASTER_KEY="${val:-sk-proxy-local}"
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
