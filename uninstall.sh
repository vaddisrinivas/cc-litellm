#!/usr/bin/env bash
# Claude-only uninstall for cc-litellm.
# Removes this plugin's hooks and proxy env from Claude settings, stops local
# helper services, and cleans global env leftovers from older versions.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"
TARGET="${1:-claude}"

case "$TARGET" in
  claude|--claude|"")
    TARGET="claude"
    ;;
  codex|--codex)
    echo "cc-litellm: Codex uninstall target is reserved for later; no Codex files were changed." >&2
    exit 2
    ;;
  *)
    echo "Usage: bash uninstall.sh [claude]" >&2
    exit 2
    ;;
esac

echo "cc-litellm: uninstalling from Claude..."

if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
cfg = json.loads(settings_path.read_text())

env = cfg.get("env", {})
if isinstance(env, dict):
    for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
        env.pop(key, None)
    if env:
        cfg["env"] = env
    else:
        cfg.pop("env", None)

def is_ours(entry):
    if not isinstance(entry, dict):
        return False
    return any(
        "session_start.sh" in (hook.get("command", "") or "")
        or "billing_error.sh" in (hook.get("command", "") or "")
        for hook in entry.get("hooks", [])
        if isinstance(hook, dict)
    )

hooks = cfg.get("hooks", {})
if isinstance(hooks, dict):
    cleaned = {}
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        kept = [entry for entry in entries if not is_ours(entry)]
        if kept:
            cleaned[event] = kept
    if cleaned:
        cfg["hooks"] = cleaned
    else:
        cfg.pop("hooks", None)

settings_path.write_text(json.dumps(cfg, indent=2) + "\n")
print("  Claude settings cleaned")
PY
else
  echo "  No Claude settings found at $SETTINGS"
fi

# Remove old LaunchAgent/runtime from previous non-Docker versions.
OLD_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.cc-litellm.proxy.plist"
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$OLD_LAUNCH_AGENT" >/dev/null 2>&1 || true
fi
rm -f "$OLD_LAUNCH_AGENT"

if command -v docker >/dev/null 2>&1; then
  docker compose -f "$PLUGIN_ROOT/docker-compose.yml" down >/dev/null 2>&1 || true
fi

# Clean leftovers written by older versions. Current install/fallback no longer
# writes global env, but removing stale values avoids proxy leakage.
ZSHENV="$HOME/.zshenv"
if [[ -f "$ZSHENV" ]]; then
  tmp="$(mktemp)"
  grep -v 'ANTHROPIC_BASE_URL\|ANTHROPIC_AUTH_TOKEN\|ANTHROPIC_API_KEY\|# cc-litellm proxy' "$ZSHENV" > "$tmp" || true
  mv "$tmp" "$ZSHENV"
fi
launchctl unsetenv ANTHROPIC_BASE_URL 2>/dev/null || true
launchctl unsetenv ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
launchctl unsetenv ANTHROPIC_API_KEY 2>/dev/null || true

rm -f "$CONFIG_HOME/plugins_backup.json" "$CONFIG_HOME/hooks_backup.json"

echo "cc-litellm: uninstalled. Credentials remain at $CONFIG_HOME/.env"
echo "Restart Claude Code so it reloads settings."
