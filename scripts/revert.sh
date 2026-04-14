#!/usr/bin/env bash
# Revert from LiteLLM proxy back to direct Anthropic.
# Run when usage limits reset and you want native Claude again.

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"
HISTORY="$CONFIG_HOME/history.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HISTORY"; }

log "revert: switching back to direct Anthropic"

# 1. Remove proxy env + restore plugins and hooks from backup
python3 - "$SETTINGS" "$CONFIG_HOME" <<'EOF'
import sys, json, os
path, config_home = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

# Remove proxy env
for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
    cfg.get("env", {}).pop(k, None)
if cfg.get("env") == {}:
    cfg.pop("env", None)

# Restore plugins from backup
plugins_bak = os.path.join(config_home, "plugins_backup.json")
if os.path.exists(plugins_bak):
    with open(plugins_bak) as f2:
        cfg["enabledPlugins"] = json.load(f2)
    os.remove(plugins_bak)

# Restore hooks from backup (merge back non-litellm hooks)
hooks_bak = os.path.join(config_home, "hooks_backup.json")
if os.path.exists(hooks_bak):
    with open(hooks_bak) as f2:
        saved_hooks = json.load(f2)
    hooks = cfg.get("hooks", {})
    for event, entries in saved_hooks.items():
        existing = hooks.get(event, [])
        hooks[event] = entries + existing
    os.remove(hooks_bak)

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
log "revert: settings.json restored (env + plugins + hooks)"

# 2. Unset launchctl env
launchctl setenv ANTHROPIC_BASE_URL ""
launchctl setenv ANTHROPIC_AUTH_TOKEN ""
log "revert: launchctl unset"

# 3. Clean ~/.zshenv
ZSHENV="$HOME/.zshenv"
if [[ -f "$ZSHENV" ]]; then
  grep -v 'ANTHROPIC_BASE_URL\|ANTHROPIC_AUTH_TOKEN\|ANTHROPIC_API_KEY\|# cc-litellm proxy' "$ZSHENV" > /tmp/zshenv_tmp || true
  mv /tmp/zshenv_tmp "$ZSHENV"
  log "revert: ~/.zshenv cleaned"
fi

# 4. Restart Claude to pick up direct config
osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
sleep 1
pkill -f "Claude.app/Contents/MacOS" 2>/dev/null || true
sleep 1
open -a "Claude"

log "revert: done — back on direct Anthropic"
osascript -e 'display notification "Back on direct Anthropic API." with title "Claude Code" sound name "Glass"'
