#!/usr/bin/env bash
# Install the proxy-fallback plugin into Claude Code settings.
# Run from anywhere — paths are resolved relative to this script.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "proxy-fallback: installing..."

python3 - "$SETTINGS" "$PLUGIN_ROOT" <<'EOF'
import sys, json

path, plugin_root = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

# Remove proxy env vars — direct Anthropic is the default.
# The billing_error hook switches to proxy on credit exhaustion.
cfg.get("env", {}).pop("ANTHROPIC_BASE_URL", None)
cfg.get("env", {}).pop("ANTHROPIC_AUTH_TOKEN", None)
if cfg.get("env") == {}:
    del cfg["env"]

# SessionStart: keep proxy + alert server alive
session_cmd = f"bash {plugin_root}/scripts/session_start.sh"
session_hooks = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
if not any(h.get("command") == session_cmd for e in session_hooks for h in e.get("hooks", [])):
    session_hooks.append({"hooks": [{"type": "command", "command": session_cmd, "timeout": 8000, "suppressOutput": True}]})

# StopFailure/billing_error: switch to proxy and notify
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

# Start services immediately
bash "$PLUGIN_ROOT/scripts/session_start.sh"

echo "proxy-fallback: done."
echo ""
echo "  Normal:           Claude Code → Anthropic (direct)"
echo "  Credits exhausted: hook fires → switches to proxy → Azure AI + notification"
echo "  Proxy:            http://localhost:4000 (standby)"
echo "  Alerts:           http://localhost:4001 (standby)"
