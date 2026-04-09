#!/usr/bin/env bash
# Ensure the LiteLLM proxy and alert server are running.
# Runs on every Claude Code SessionStart.

# Works whether invoked via plugin (CLAUDE_PLUGIN_ROOT set) or install.sh directly
PROXY_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# 1. Start Docker proxy if not running
if ! docker compose -f "$PROXY_DIR/docker-compose.yml" ps --quiet litellm 2>/dev/null | grep -q .; then
  docker compose -f "$PROXY_DIR/docker-compose.yml" up -d --quiet-pull >/dev/null 2>&1
fi

# 2. Start alert webhook server if not running
if ! lsof -ti:4001 >/dev/null 2>&1; then
  nohup python3 "$PROXY_DIR/alert.py" 4001 >> "$PROXY_DIR/alert.log" 2>&1 &
  disown
fi

exit 0
