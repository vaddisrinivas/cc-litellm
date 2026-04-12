#!/usr/bin/env bash
# Ensure the LiteLLM proxy and alert server are running.
# Runs on every Claude Code SessionStart.
# Auto-restarts proxy if running with stale config.
# Prefers native litellm CLI; falls back to Docker if not installed.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
EXPECTED_CONFIG="$PLUGIN_ROOT/config.yaml"

mkdir -p "$CONFIG_HOME"

_start_proxy() {
  if command -v litellm >/dev/null 2>&1; then
    set -a; source "$CONFIG_HOME/.env" 2>/dev/null; set +a
    nohup litellm --config "$EXPECTED_CONFIG" --port 4000 \
      >> "$CONFIG_HOME/litellm.log" 2>&1 &
    disown
  elif command -v docker >/dev/null 2>&1; then
    docker compose -f "$PLUGIN_ROOT/docker-compose.yml" \
      --env-file "$CONFIG_HOME/.env" \
      up -d --quiet-pull >/dev/null 2>&1
  fi
}

_stop_proxy() {
  # Native
  local pid
  pid=$(pgrep -f "litellm.*--port 4000" 2>/dev/null | head -1)
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  # Docker
  command -v docker >/dev/null 2>&1 && \
    docker compose -f "$PLUGIN_ROOT/docker-compose.yml" down >/dev/null 2>&1 || true
  # Wait for port to free
  local i=0
  while lsof -ti:4000 >/dev/null 2>&1 && (( i++ < 10 )); do sleep 0.5; done
}

# 1. Proxy: start fresh or restart if stale config
if lsof -ti:4000 >/dev/null 2>&1; then
  # Check if running with correct config
  RUNNING_CONFIG=$(pgrep -af "litellm.*--port 4000" 2>/dev/null | grep -o '\-\-config [^ ]*' | awk '{print $2}')
  if [[ -n "$RUNNING_CONFIG" && "$RUNNING_CONFIG" != "$EXPECTED_CONFIG" ]]; then
    echo "[cc-litellm] stale config detected, restarting proxy" >> "$CONFIG_HOME/session.log"
    _stop_proxy
    _start_proxy
  fi
  # else already running with correct config — do nothing
else
  _start_proxy
fi

# 2. Alert webhook server
if ! lsof -ti:4001 >/dev/null 2>&1; then
  nohup python3 "$PLUGIN_ROOT/alert.py" 4001 >> "$CONFIG_HOME/alert.log" 2>&1 &
  disown
fi

exit 0
