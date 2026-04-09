#!/usr/bin/env bash
# Ensure the LiteLLM proxy and alert server are running.
# Runs on every Claude Code SessionStart.
# Prefers native litellm CLI; falls back to Docker if not installed.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"

mkdir -p "$CONFIG_HOME"

# 1. Start LiteLLM proxy if not already listening on port 4000
if ! lsof -ti:4000 >/dev/null 2>&1; then
  if command -v litellm >/dev/null 2>&1; then
    # Native: use litellm CLI directly
    set -a; source "$CONFIG_HOME/.env" 2>/dev/null; set +a
    nohup litellm --config "$PLUGIN_ROOT/config.yaml" --port 4000 \
      >> "$CONFIG_HOME/litellm.log" 2>&1 &
    disown
  elif command -v docker >/dev/null 2>&1; then
    # Docker fallback
    docker compose -f "$PLUGIN_ROOT/docker-compose.yml" \
      --env-file "$CONFIG_HOME/.env" \
      up -d --quiet-pull >/dev/null 2>&1
  fi
  # else: neither available — proxy won't start, but hooks still work
fi

# 2. Start alert webhook server if not running
if ! lsof -ti:4001 >/dev/null 2>&1; then
  nohup python3 "$PLUGIN_ROOT/alert.py" 4001 >> "$CONFIG_HOME/alert.log" 2>&1 &
  disown
fi

exit 0
