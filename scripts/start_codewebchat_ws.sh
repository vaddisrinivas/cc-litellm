#!/usr/bin/env bash
# Start CodeWebChat's local WebSocket server for the chatgpt-browser provider.

set -euo pipefail

CODEWEBCHAT_HOME="${CODEWEBCHAT_HOME:-$HOME/.config/cc-litellm/CodeWebChat}"
SERVER_JS="$CODEWEBCHAT_HOME/apps/editor/dist/services/websocket-server-process.js"
SERVER_OUT_JS="$CODEWEBCHAT_HOME/apps/editor/out/websocket-server-process.js"
SERVER_TS="$CODEWEBCHAT_HOME/apps/editor/src/services/websocket-server-process.ts"

if [[ -f "$SERVER_JS" ]]; then
  exec node "$SERVER_JS"
fi

if [[ -f "$SERVER_OUT_JS" ]]; then
  exec node "$SERVER_OUT_JS"
fi

if [[ -f "$SERVER_TS" ]]; then
  cd "$CODEWEBCHAT_HOME/apps/editor"
  exec npx ts-node "$SERVER_TS"
fi

echo "start_codewebchat_ws: CodeWebChat server not built at $CODEWEBCHAT_HOME" >&2
echo "Run: bash $(cd "$(dirname "$0")" && pwd)/setup_codewebchat.sh" >&2
exit 1
