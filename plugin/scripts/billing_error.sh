#!/usr/bin/env bash
# Fired by Claude Code's StopFailure/billing_error hook.
# Switches Claude Code to use the LiteLLM proxy and notifies the user.

SETTINGS="$HOME/.claude/settings.json"

# Inject proxy env vars into settings.json
python3 - "$SETTINGS" <<'EOF'
import sys, json

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local"
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF

# macOS notification
osascript -e 'display notification "Anthropic credits exhausted — switched to Azure AI. Restart Claude Code." with title "Claude Code — Out of Credits" sound name "Basso"'
