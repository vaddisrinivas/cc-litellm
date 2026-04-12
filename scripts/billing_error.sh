#!/usr/bin/env bash
# Fired by Claude Code's StopFailure hook on billing/limit errors.
# Shows approval dialog — only switches to Azure proxy if user confirms.

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"

# Read master key from config, fall back to default
MASTER_KEY="sk-proxy-local"
if [[ -f "$CONFIG_HOME/.env" ]]; then
  val=$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_HOME/.env" | cut -d= -f2 | tr -d '"')
  MASTER_KEY="${val:-sk-proxy-local}"
fi

# Show approval dialog (blocks until user responds)
RESULT=$(osascript -e '
display dialog "Claude Code usage limit reached.\n\nSwitch to Azure AI (gpt-54-nano) via LiteLLM proxy?" buttons {"Cancel", "Switch to Azure"} default button "Switch to Azure" cancel button "Cancel" with title "Claude Code — Limit Reached" with icon caution giving up after 120
' 2>&1)

# Exit if user cancelled or dialog timed out with no action
if [[ $? -ne 0 ]] || [[ "$RESULT" == *"gave up:true"* ]]; then
  osascript -e 'display notification "Staying on Anthropic. Restart Claude Code when limits reset." with title "Claude Code" sound name "Pop"'
  exit 0
fi

# User approved — inject proxy env vars into settings.json
python3 - "$SETTINGS" "$MASTER_KEY" <<'PYEOF'
import sys, json

path, master_key = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_API_KEY": master_key
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF

# Confirm switch
osascript -e 'display notification "Switched to Azure AI proxy. Restart Claude Code to continue." with title "Claude Code — Azure Active" sound name "Glass"'
