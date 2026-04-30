#!/usr/bin/env bash
# Ensure the LiteLLM proxy is running.
# Runs on every Claude Code SessionStart.
# Auto-restarts proxy if running with stale config.
# Docker-only runtime.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
EXPECTED_CONFIG_RAW="$PLUGIN_ROOT/config.yaml"
EXPECTED_CONFIG="$EXPECTED_CONFIG_RAW"
if [[ -f "$EXPECTED_CONFIG_RAW" ]]; then
  EXPECTED_CONFIG="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXPECTED_CONFIG_RAW" 2>/dev/null || echo "$EXPECTED_CONFIG_RAW")"
fi

mkdir -p "$CONFIG_HOME"

CONFIG_ENV="$CONFIG_HOME/.env"
PLUGIN_ENV="$PLUGIN_ROOT/.env"
ENV_PATCHED=0
CONFIG_HASH_FILE="$CONFIG_HOME/litellm_config_hash.txt"

_ensure_zai_api_key() {
  # If ZAI_API_KEY is missing, try to populate it from:
  #  - ZHIPU_API_KEY (backward compat)
  #  - repo-root .env (if present in this workspace)
  if [[ ! -f "$CONFIG_ENV" ]]; then
    return 0
  fi

  if grep -q '^ZAI_API_KEY=' "$CONFIG_ENV" 2>/dev/null; then
    return 0
  fi

  local val=""
  if grep -q '^ZHIPU_API_KEY=' "$CONFIG_ENV" 2>/dev/null; then
    val="$(grep '^ZHIPU_API_KEY=' "$CONFIG_ENV" | head -1 | cut -d= -f2- | tr -d '\"' | tr -d \"'\" )"
  elif [[ -f "$PLUGIN_ENV" ]] && grep -q '^ZAI_API_KEY=' "$PLUGIN_ENV" 2>/dev/null; then
    val="$(grep '^ZAI_API_KEY=' "$PLUGIN_ENV" | head -1 | cut -d= -f2- | tr -d '\"' | tr -d \"'\" )"
  fi

  if [[ -n "$val" ]]; then
    echo "ZAI_API_KEY=$val" >> "$CONFIG_ENV"
    ENV_PATCHED=1
  fi
}

_config_hash() {
  [[ -f "$EXPECTED_CONFIG" ]] || return 1
  shasum -a 256 "$EXPECTED_CONFIG" | awk '{print $1}'
}

_start_proxy() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local recreate=()
    local build=()
    if [[ "${CC_LITELLM_FORCE_RECREATE:-0}" == "1" ]]; then
      recreate=(--force-recreate)
      build=(--build)
    fi
    docker compose -f "$PLUGIN_ROOT/docker-compose.yml" \
      --env-file "$CONFIG_HOME/.env" \
      up -d --quiet-pull "${build[@]}" "${recreate[@]}" >/dev/null 2>&1
  else
    echo "[cc-litellm] Docker is required but not running; proxy not started" >> "$CONFIG_HOME/session.log"
  fi
}

_stop_proxy() {
  # Docker Desktop owns the host port-forwarding process for published ports.
  # Do not kill the process bound to :4000; use Compose to stop only our service.
  command -v docker >/dev/null 2>&1 && \
    docker compose -f "$PLUGIN_ROOT/docker-compose.yml" down >/dev/null 2>&1 || true
  # Wait for port to free
  local i=0
  while lsof -ti:4000 >/dev/null 2>&1 && (( i++ < 10 )); do sleep 0.5; done
}

# Patch env vars if needed (so glm models authenticate).
_ensure_zai_api_key

EXPECTED_CONFIG_HASH="$(_config_hash 2>/dev/null || echo '')"
LAST_CONFIG_HASH="$(cat "$CONFIG_HASH_FILE" 2>/dev/null || echo '')"

# 1. Proxy: start fresh or restart if stale config
_PROXY_PID=$(lsof -ti:4000 2>/dev/null | head -1)
if [[ -n "$_PROXY_PID" ]]; then
  # Use ps to get full args (pgrep -a truncates on macOS)
  RUNNING_CONFIG=$(ps -p "$_PROXY_PID" -o args= 2>/dev/null | grep -o '\-\-config [^ ]*' | awk '{print $2}')
  RUNNING_CONFIG_NORM="$RUNNING_CONFIG"
  # Docker uses /app/config.yaml inside the container; treat port 4000 as valid
  # when the cc-litellm compose service is running.
  if command -v docker >/dev/null 2>&1 && docker compose -f "$PLUGIN_ROOT/docker-compose.yml" ps --services --status running 2>/dev/null | grep -qx 'litellm'; then
    RUNNING_CONFIG_NORM="$EXPECTED_CONFIG"
  elif [[ -n "$RUNNING_CONFIG" && -f "$RUNNING_CONFIG" ]]; then
    RUNNING_CONFIG_NORM="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RUNNING_CONFIG" 2>/dev/null || echo "$RUNNING_CONFIG")"
  fi

  NEED_RESTART=0
  if [[ "${CC_LITELLM_FORCE_RECREATE:-0}" == "1" ]]; then
    NEED_RESTART=1
  fi
  if [[ -z "$RUNNING_CONFIG_NORM" || "$RUNNING_CONFIG_NORM" != "$EXPECTED_CONFIG" ]]; then
    NEED_RESTART=1
  fi
  # Restart when config.yaml content changes too (alias model sets, etc).
  if [[ -n "$EXPECTED_CONFIG_HASH" && "$LAST_CONFIG_HASH" != "$EXPECTED_CONFIG_HASH" ]]; then
    NEED_RESTART=1
  fi
  # Restart when we patched .env (e.g., added ZAI_API_KEY).
  if [[ "$ENV_PATCHED" == "1" ]]; then
    NEED_RESTART=1
  fi

  if [[ "$NEED_RESTART" == "1" ]]; then
    echo "[cc-litellm] stale config detected (running=${RUNNING_CONFIG_NORM:-unknown} expected=${EXPECTED_CONFIG}), restarting proxy" >> "$CONFIG_HOME/session.log"
    _stop_proxy
    _start_proxy
    if [[ -n "$EXPECTED_CONFIG_HASH" ]]; then
      echo "$EXPECTED_CONFIG_HASH" > "$CONFIG_HASH_FILE" 2>/dev/null || true
    fi
  fi
  # else already running with correct config — do nothing
else
  _start_proxy
  if [[ -n "$EXPECTED_CONFIG_HASH" ]]; then
    echo "$EXPECTED_CONFIG_HASH" > "$CONFIG_HASH_FILE" 2>/dev/null || true
  fi
fi

exit 0
