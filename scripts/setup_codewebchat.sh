#!/usr/bin/env bash
# Clone and build CodeWebChat for the optional chatgpt-browser provider.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEWEBCHAT_HOME="${CODEWEBCHAT_HOME:-$HOME/.config/cc-litellm/CodeWebChat}"
CODEWEBCHAT_REPO="${CODEWEBCHAT_REPO:-https://github.com/robertpiosik/CodeWebChat.git}"

if ! command -v git >/dev/null 2>&1; then
  echo "setup_codewebchat: git is required" >&2
  exit 1
fi

PNPM=(pnpm)

if ! command -v pnpm >/dev/null 2>&1; then
  if command -v corepack >/dev/null 2>&1; then
    corepack enable pnpm >/dev/null 2>&1 || true
  fi
fi

if ! command -v pnpm >/dev/null 2>&1; then
  if command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
    PNPM=(corepack pnpm)
  else
    echo "setup_codewebchat: pnpm is required. Install Node.js/pnpm, then rerun." >&2
    exit 1
  fi
fi

if [[ ! -d "$CODEWEBCHAT_HOME/.git" ]]; then
  mkdir -p "$(dirname "$CODEWEBCHAT_HOME")"
  git clone "$CODEWEBCHAT_REPO" "$CODEWEBCHAT_HOME"
else
  git -C "$CODEWEBCHAT_HOME" pull --ff-only
fi

cd "$CODEWEBCHAT_HOME"
"${PNPM[@]}" install
"${PNPM[@]}" --dir apps/browser build
"${PNPM[@]}" --dir apps/editor build

cat <<EOF
CodeWebChat built at:
  $CODEWEBCHAT_HOME

Load the Chrome extension from:
  $CODEWEBCHAT_HOME/apps/browser/dist

Then open https://chatgpt.com and start the WebSocket server:
  CODEWEBCHAT_HOME="$CODEWEBCHAT_HOME" bash "$SCRIPT_DIR/start_codewebchat_ws.sh"
EOF
