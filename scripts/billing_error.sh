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

# User approved — set env vars at system level (GUI + CLI)
# launchctl: propagates to all GUI apps including Claude Code desktop
launchctl setenv ANTHROPIC_BASE_URL "http://localhost:4000"
launchctl setenv ANTHROPIC_API_KEY "$MASTER_KEY"

# zshenv: propagates to CLI sessions after restart
ZSHENV="$HOME/.zshenv"
# Remove any prior proxy lines, then append
grep -v 'ANTHROPIC_BASE_URL\|# cc-litellm proxy' "$ZSHENV" 2>/dev/null > /tmp/zshenv_tmp || true
printf '\n# cc-litellm proxy\nexport ANTHROPIC_BASE_URL=http://localhost:4000\nexport ANTHROPIC_API_KEY=%s\n' "$MASTER_KEY" >> /tmp/zshenv_tmp
mv /tmp/zshenv_tmp "$ZSHENV"

# Confirm switch
osascript -e 'display notification "Switched to Azure AI proxy. Restart Claude Code to continue." with title "Claude Code — Azure Active" sound name "Glass"'
