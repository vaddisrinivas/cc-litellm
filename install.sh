#!/usr/bin/env bash
# Manual Claude CLI install.
# Routes Claude Code / `claude -p` through the local LiteLLM proxy only.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"
CLAUDE_DIR="$(dirname "$SETTINGS")"
TARGET="${1:-claude}"

case "$TARGET" in
  claude|--claude|"")
    TARGET="claude"
    ;;
  codex|--codex)
    echo "cc-litellm: Codex install target is reserved for later; no Codex files were changed." >&2
    echo "For now, run: bash install.sh claude" >&2
    exit 2
    ;;
  *)
    echo "Usage: bash install.sh [claude]" >&2
    exit 2
    ;;
esac

echo "cc-litellm: installing local LiteLLM routing for Claude..."

ensure_docker_runtime() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "cc-litellm: Docker is required for this install." >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      open -a Docker >/dev/null 2>&1 || true
      echo "  Waiting for Docker Desktop..."
      for _ in {1..60}; do
        docker info >/dev/null 2>&1 && break
        sleep 2
      done
    fi
  fi

  # Docker Desktop may briefly answer while applying an update, then restart.
  # Require a few consecutive successful checks before starting Compose.
  local ok=0
  for _ in {1..15}; do
    if docker info >/dev/null 2>&1; then
      ok=$((ok + 1))
      [[ "$ok" -ge 3 ]] && break
    else
      ok=0
    fi
    sleep 2
  done

  if [[ "$ok" -lt 3 ]]; then
    echo "cc-litellm: Docker is installed but the daemon is not running." >&2
    echo "Start Docker Desktop, then rerun: bash install.sh claude" >&2
    exit 1
  fi

  echo "  Runtime:           Docker Compose"
}

remove_old_launch_agent() {
  local launch_agent="$HOME/Library/LaunchAgents/com.cc-litellm.proxy.plist"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$launch_agent" >/dev/null 2>&1 || true
  fi
  rm -f "$launch_agent"
}

# 1. Set up config directory
mkdir -p "$CONFIG_HOME"
mkdir -p "$CLAUDE_DIR"
CONFIG_ENV="$CONFIG_HOME/.env"
EXAMPLE_ENV="$PLUGIN_ROOT/.env.example"
PLUGIN_ENV="$PLUGIN_ROOT/.env"

if [[ ! -f "$EXAMPLE_ENV" ]]; then
  echo "cc-litellm: missing $EXAMPLE_ENV" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_ENV" ]]; then
  cp "$EXAMPLE_ENV" "$CONFIG_ENV"
  echo "  Created $CONFIG_ENV — fill in your credentials"
else
  echo "  Config: $CONFIG_ENV (already exists)"
fi

# 1b. Merge missing env keys into CONFIG_ENV.
# - Prefer actual values from PLUGIN_ENV (if present in this workspace)
# - Else use the placeholders from EXAMPLE_ENV
# - Special cases copy older env names into the new local Azure AI Foundry names.
python3 - "$CONFIG_ENV" "$EXAMPLE_ENV" "$PLUGIN_ENV" <<'PY'
import sys, pathlib

config_path = pathlib.Path(sys.argv[1])
example_path = pathlib.Path(sys.argv[2])
plugin_path = pathlib.Path(sys.argv[3])

def parse_env(path: pathlib.Path):
    d = {}
    if path and path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, val = line.split('=', 1)
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            d[key] = val
    return d

config = parse_env(config_path)
example = parse_env(example_path)
plugin = parse_env(plugin_path)

alt_key = {
    "ZAI_API_KEY": "ZHIPU_API_KEY",
    "AZURE_AI_FOUNDRY_API_KEY": "AZURE_AI_API_KEY",
    "AZURE_AI_FOUNDRY_NANO_API_BASE": "AZURE_AI_API_BASE",
}

to_append = []
for key, example_val in example.items():
    existing = config.get(key, '')
    if existing == '':
        chosen = plugin.get(key, '')
        if not chosen:
            k_alt = alt_key.get(key)
            if k_alt:
                chosen = config.get(k_alt, '')
        if not chosen:
            chosen = example_val
        if chosen != '':
            to_append.append((key, chosen))

if to_append:
    with config_path.open('a') as f:
        for key, val in to_append:
            f.write(f"{key}={val}\n")
    print(f"  merged env keys into {config_path} ({len(to_append)} added)")
else:
    print("  env keys already present")
PY

# Prefer the embedded CodeWebChat-compatible WebSocket bridge in the Docker shim.
# Older installs used a host CodeWebChat server at host.docker.internal:55155.
if grep -q '^CHATGPT_BROWSER_WS_URL=ws://host.docker.internal:55155$' "$CONFIG_ENV" 2>/dev/null; then
  tmp="$(mktemp)"
  sed 's|^CHATGPT_BROWSER_WS_URL=ws://host\.docker\.internal:55155$|CHATGPT_BROWSER_WS_URL=embedded|' "$CONFIG_ENV" > "$tmp"
  mv "$tmp" "$CONFIG_ENV"
fi

ensure_docker_runtime
remove_old_launch_agent

# 2. Patch Claude settings.json only. Do not write launchctl, shell startup
# files, Codex config, Cursor config, or any other global environment.
MASTER_KEY="$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
MASTER_KEY="${MASTER_KEY:-sk-proxy-local}"

python3 - "$SETTINGS" "$PLUGIN_ROOT" "$MASTER_KEY" <<'EOF'
import sys, json
from pathlib import Path

path, plugin_root, master_key = sys.argv[1], sys.argv[2], sys.argv[3]
settings_path = Path(path)
if settings_path.exists():
    try:
        cfg = json.loads(settings_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid Claude settings JSON at {settings_path}: {exc}")
else:
    cfg = {}

# Route Claude only through LiteLLM. Claude CLI/`claude -p` reads these from
# settings.json, so we avoid global shell or launchctl state.
env = cfg.setdefault("env", {})
if not isinstance(env, dict):
    env = {}
env.pop("ANTHROPIC_API_KEY", None)
env["ANTHROPIC_BASE_URL"] = "http://localhost:4000"
env["ANTHROPIC_AUTH_TOKEN"] = master_key
cfg["env"] = env

# Preserve the user's Claude default model. The LiteLLM config maps Opus
# aliases (including opus[1m]) to Kimi; delegation wrappers should pass
# --model claude-sonnet-4-6 explicitly when they want the fast GLM route.
if cfg.get("model") in (None, ""):
    cfg["model"] = "opus[1m]"

# Remove ALL existing cc-litellm hooks (any version/path) then add fresh
def is_ours(entry):
    if not isinstance(entry, dict):
        return False
    return any(
        "session_start.sh" in (h.get("command", "") or "")
        or "billing_error.sh" in (h.get("command", "") or "")
        for h in entry.get("hooks", [])
        if isinstance(h, dict)
    )

hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    cfg["hooks"] = hooks

hooks["SessionStart"] = [e for e in hooks.get("SessionStart", []) if not is_ours(e)]
hooks["SessionStart"].append({"hooks": [{"type": "command", "command": f"bash {plugin_root}/scripts/session_start.sh", "timeout": 8000, "suppressOutput": True}]})

# This install is LiteLLM-only, so billing fallback hooks are intentionally not
# installed. Remove old copies if present.
if "StopFailure" in hooks:
    hooks["StopFailure"] = [e for e in hooks.get("StopFailure", []) if not is_ours(e)]
    if not hooks["StopFailure"]:
        hooks.pop("StopFailure", None)

with settings_path.open("w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("  settings.json updated")
EOF

# 3. Start services. Force-recreate so Docker picks up env/config changes from
# this install run instead of keeping a stale container.
CC_LITELLM_FORCE_RECREATE=1 bash "$PLUGIN_ROOT/scripts/session_start.sh"

if ! docker info >/dev/null 2>&1 || \
   ! docker compose -f "$PLUGIN_ROOT/docker-compose.yml" --env-file "$CONFIG_ENV" ps --services --status running 2>/dev/null | grep -qx 'litellm' || \
   ! docker compose -f "$PLUGIN_ROOT/docker-compose.yml" --env-file "$CONFIG_ENV" ps --services --status running 2>/dev/null | grep -qx 'chatgpt-browser-proxy'; then
  echo "cc-litellm: Docker Compose did not stay running after startup." >&2
  echo "Docker Desktop may be updating or restarting. Start Docker, wait until it is stable, then rerun: bash install.sh claude" >&2
  exit 1
fi

echo "cc-litellm: done."
echo ""
echo "  Config:            $CONFIG_HOME/.env"
echo "  Claude:            claude -p → local LiteLLM"
echo "  Provider policy:   Azure AI Foundry + GLM via config.yaml"
echo "  Proxy:             http://localhost:4000"
echo "  Browser provider:  chatgpt-browser via http://localhost:18080 (optional)"
echo "  Runtime:           Docker Compose"
echo "  Uninstall:         bash $PLUGIN_ROOT/uninstall.sh"
