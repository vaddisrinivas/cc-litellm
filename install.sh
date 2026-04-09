#!/usr/bin/env bash
# Manual install — use this if you prefer not to use `claude plugin install`.
# Also run this after plugin install to set up your credentials.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"

echo "cc-litellm: installing..."

# 1. Set up config directory
mkdir -p "$CONFIG_HOME"
if [[ ! -f "$CONFIG_HOME/.env" ]]; then
  cp "$PLUGIN_ROOT/.env.example" "$CONFIG_HOME/.env"
  echo "  Created $CONFIG_HOME/.env — fill in your credentials"
else
  echo "  Config: $CONFIG_HOME/.env (already exists)"
fi

# 2. Patch settings.json
python3 - "$SETTINGS" "$PLUGIN_ROOT" <<'EOF'
import sys, json

path, plugin_root = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

# Remove proxy env vars — direct Anthropic is the default.
# billing_error hook re-activates the proxy when credits run out.
cfg.get("env", {}).pop("ANTHROPIC_BASE_URL", None)
cfg.get("env", {}).pop("ANTHROPIC_AUTH_TOKEN", None)
if cfg.get("env") == {}:
    del cfg["env"]

# SessionStart hook: keep proxy + alert server alive
session_cmd = f"bash {plugin_root}/scripts/session_start.sh"
session_hooks = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
if not any(h.get("command") == session_cmd for e in session_hooks for h in e.get("hooks", [])):
    session_hooks.append({"hooks": [{"type": "command", "command": session_cmd, "timeout": 8000, "suppressOutput": True}]})

# StopFailure/billing_error: switch to proxy + notify
billing_cmd = f"bash {plugin_root}/scripts/billing_error.sh"
stop_hooks = cfg["hooks"].setdefault("StopFailure", [])
if not any(h.get("command") == billing_cmd for e in stop_hooks for h in e.get("hooks", [])):
    stop_hooks.append({
        "matcher": "billing_error",
        "hooks": [{"type": "command", "command": billing_cmd, "timeout": 10000, "suppressOutput": True}]
    })

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("  settings.json updated")
EOF

# 3. Start services
bash "$PLUGIN_ROOT/scripts/session_start.sh"

echo "cc-litellm: done."
echo ""
echo "  Config:            $CONFIG_HOME/.env"
echo "  Normal:            Claude Code → Anthropic (direct)"
echo "  Credits exhausted: hook fires → Azure AI + notification"
echo "  Proxy:             http://localhost:4000 (standby)"
echo "  Alerts:            http://localhost:4001 (standby)"
