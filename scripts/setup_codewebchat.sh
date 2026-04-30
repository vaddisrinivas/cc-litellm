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

CHATGPT_ADAPTER="$CODEWEBCHAT_HOME/apps/browser/src/content-scripts/send-prompt-content-script/chatbots/chatgpt.ts"
if [[ -f "$CHATGPT_ADAPTER" ]]; then
  perl -0pi -e 's/if \(!copy_button\) \{\n\s*report_initialization_error\(\{\n\s*function_name: '\''chatgpt\.perform_copy'\'',\n\s*log_message: '\''Copy button not found'\''\n\s*\}\)\n\s*return\n\s*\}\n\s*copy_button\.click\(\)/copy_button?.click()/s' "$CHATGPT_ADAPTER"
fi

python3 - "$CODEWEBCHAT_HOME" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])

types = root / "packages/shared/src/types/websocket-message.ts"
text = types.read_text()
if "ChatGPTApiFetchMessage" not in text:
    text = text.replace(
        "export type ClientIdAssignmentMessage = {\n  action: 'client-id-assignment'\n  client_id: number\n}\n",
        "export type ClientIdAssignmentMessage = {\n  action: 'client-id-assignment'\n  client_id: number\n}\n\n"
        "export type ChatGPTApiFetchMessage = {\n"
        "  action: 'chatgpt-api-fetch'\n"
        "  client_id: number\n"
        "  url: string\n"
        "  method?: string\n"
        "  headers?: Record<string, string>\n"
        "  body?: string\n"
        "}\n\n"
        "export type ChatGPTApiResponseMessage = {\n"
        "  action: 'chatgpt-api-response'\n"
        "  client_id: number\n"
        "  ok: boolean\n"
        "  status: number\n"
        "  status_text: string\n"
        "  content_type?: string\n"
        "  body: string\n"
        "}\n",
    )
    text = text.replace(
        "  | ClientIdAssignmentMessage\n  | ApplyChatResponseMessage",
        "  | ClientIdAssignmentMessage\n  | ApplyChatResponseMessage\n  | ChatGPTApiFetchMessage\n  | ChatGPTApiResponseMessage",
    )
    types.write_text(text)

handler = root / "apps/browser/src/background/message-handler.ts"
text = handler.read_text()
if "ChatGPTApiFetchMessage" not in text:
    text = text.replace(
        "  InitializeChatMessage,\n  ApplyChatResponseMessage\n} from '@shared/types/websocket-message'",
        "  InitializeChatMessage,\n  ApplyChatResponseMessage,\n  ChatGPTApiFetchMessage,\n  ChatGPTApiResponseMessage\n} from '@shared/types/websocket-message'",
    )
    text = text.replace(
        "  if (message.action == 'initialize-chat') {\n    handle_initialize_chat_message(message as InitializeChatMessage)\n  }\n}\n",
        "  if (message.action == 'initialize-chat') {\n"
        "    handle_initialize_chat_message(message as InitializeChatMessage)\n"
        "  } else if (message.action == 'chatgpt-api-fetch') {\n"
        "    handle_chatgpt_api_fetch_message(message as ChatGPTApiFetchMessage)\n"
        "  }\n"
        "}\n\n"
        "const handle_chatgpt_api_fetch_message = async (\n"
        "  message: ChatGPTApiFetchMessage\n"
        ") => {\n"
        "  const headers = new Headers(message.headers || {})\n"
        "  try {\n"
        "    const response = await fetch(message.url, {\n"
        "      method: message.method || 'POST',\n"
        "      headers,\n"
        "      body: message.body,\n"
        "      credentials: 'include'\n"
        "    })\n"
        "    const body = await response.text()\n"
        "    send_message_to_server({\n"
        "      action: 'chatgpt-api-response',\n"
        "      client_id: message.client_id,\n"
        "      ok: response.ok,\n"
        "      status: response.status,\n"
        "      status_text: response.statusText,\n"
        "      content_type: response.headers.get('content-type') || undefined,\n"
        "      body\n"
        "    } as ChatGPTApiResponseMessage)\n"
        "  } catch (error) {\n"
        "    send_message_to_server({\n"
        "      action: 'chatgpt-api-response',\n"
        "      client_id: message.client_id,\n"
        "      ok: false,\n"
        "      status: 0,\n"
        "      status_text: error instanceof Error ? error.message : String(error),\n"
        "      body: ''\n"
        "    } as ChatGPTApiResponseMessage)\n"
        "  }\n"
        "}\n",
    )
    handler.write_text(text)
text = handler.read_text()
if "last_chatgpt_api_headers" not in text:
    text = text.replace(
        "const session_tabs: Record<string, number> = {}\n",
        "const session_tabs: Record<string, number> = {}\n"
        "let last_chatgpt_api_headers: Record<string, string> = {}\n",
    )
text = text.replace(
    "  const headers = new Headers(message.headers || {})\n",
    "  const headers = new Headers({\n"
    "    ...last_chatgpt_api_headers,\n"
    "    ...(message.headers || {})\n"
    "  })\n",
)
if "capture_chatgpt_request_headers" not in text:
    text = text.replace(
        "const generate_alphanumeric_id = async (\n",
        "const capture_chatgpt_request_headers = (\n"
        "  details: browser.WebRequest.OnBeforeSendHeadersDetailsType\n"
        ") => {\n"
        "  const headers: Record<string, string> = {}\n"
        "  for (const header of details.requestHeaders || []) {\n"
        "    const name = header.name.toLowerCase()\n"
        "    const value = header.value\n"
        "    if (!value) continue\n"
        "    if (\n"
        "      name.startsWith('openai-sentinel-') ||\n"
        "      name.startsWith('x-openai-') ||\n"
        "      name == 'x-conduit-token' ||\n"
        "      name.startsWith('oai-')\n"
        "    ) {\n"
        "      headers[header.name] = value\n"
        "    }\n"
        "  }\n"
        "  if (Object.keys(headers).length > 0) {\n"
        "    last_chatgpt_api_headers = headers\n"
        "    browser.storage.local.set({ cwc_chatgpt_api_headers: headers })\n"
        "  }\n"
        "}\n\n"
        "const generate_alphanumeric_id = async (\n",
    )
if "onBeforeSendHeaders.addListener" not in text:
    text = text.replace(
        "export const setup_message_listeners = () => {\n",
        "export const setup_message_listeners = () => {\n"
        "  browser.storage.local.get('cwc_chatgpt_api_headers').then((stored) => {\n"
        "    const headers = stored.cwc_chatgpt_api_headers\n"
        "    if (headers && typeof headers == 'object') {\n"
        "      last_chatgpt_api_headers = headers as Record<string, string>\n"
        "    }\n"
        "  })\n\n"
        "  browser.webRequest.onBeforeSendHeaders.addListener(\n"
        "    capture_chatgpt_request_headers,\n"
        "    {\n"
        "      urls: [\n"
        "        'https://chatgpt.com/backend-api/conversation*',\n"
        "        'https://chatgpt.com/backend-api/f/conversation*',\n"
        "        'https://chatgpt.com/backend-anon/f/conversation*'\n"
        "      ]\n"
        "    },\n"
        "    ['requestHeaders', 'extraHeaders']\n"
        "  )\n\n",
    )
handler.write_text(text)

manifest = root / "apps/browser/src/manifest.json"
data = json.loads(manifest.read_text())
permissions = data.setdefault("permissions", [])
for permission in ["webRequest"]:
    if permission not in permissions:
        permissions.append(permission)
hosts = data.setdefault("host_permissions", [])
for host in ["https://chatgpt.com/*"]:
    if host not in hosts:
        hosts.append(host)
manifest.write_text(json.dumps(data, indent=2) + "\n")
PY

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
