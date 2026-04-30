#!/usr/bin/env bash
# Revert Claude Code from LiteLLM proxy back to direct Anthropic.
# Run when usage limits reset and you want native Claude again.

set -euo pipefail

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"
HISTORY="$CONFIG_HOME/history.log"
mkdir -p "$CONFIG_HOME"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HISTORY"; }

log "revert: switching back to direct Anthropic"

# 1. Remove Claude proxy env + restore plugins and hooks from backup.
python3 - "$SETTINGS" "$CONFIG_HOME" <<'EOF'
import sys, json, os
from pathlib import Path
path, config_home = sys.argv[1], sys.argv[2]
settings_path = Path(path)
if settings_path.exists():
    cfg = json.loads(settings_path.read_text())
else:
    cfg = {}

# Remove proxy env
env = cfg.get("env", {})
if isinstance(env, dict):
    for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
        env.pop(k, None)
    if env:
        cfg["env"] = env
    else:
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
    if not isinstance(hooks, dict):
        hooks = {}
    def hook_key(entry):
        return json.dumps(entry, sort_keys=True)
    for event, entries in saved_hooks.items():
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            existing = []
        seen = {hook_key(entry) for entry in existing}
        restored = [entry for entry in entries if hook_key(entry) not in seen]
        hooks[event] = restored + existing
    cfg["hooks"] = {event: entries for event, entries in hooks.items() if entries}
    if not cfg["hooks"]:
        cfg.pop("hooks", None)
    os.remove(hooks_bak)

with settings_path.open("w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
log "revert: settings.json restored (env + plugins + hooks)"

# 2. Clean old global env leftovers from earlier versions.
ZSHENV="$HOME/.zshenv"
if [[ -f "$ZSHENV" ]]; then
  grep -v 'ANTHROPIC_BASE_URL\|ANTHROPIC_AUTH_TOKEN\|ANTHROPIC_API_KEY\|# cc-litellm proxy' "$ZSHENV" > /tmp/zshenv_tmp || true
  mv /tmp/zshenv_tmp "$ZSHENV"
  log "revert: old ~/.zshenv proxy entries cleaned"
fi
launchctl unsetenv ANTHROPIC_BASE_URL 2>/dev/null || true
launchctl unsetenv ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
launchctl unsetenv ANTHROPIC_API_KEY 2>/dev/null || true
log "revert: old launchctl proxy entries cleaned"

# 3. Restart Claude to pick up direct config
osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
sleep 1
pkill -f "Claude.app/Contents/MacOS" 2>/dev/null || true
sleep 1
open -a "Claude"

log "revert: done — back on direct Anthropic"
osascript -e 'display notification "Back on direct Anthropic API." with title "Claude Code" sound name "Glass"'
