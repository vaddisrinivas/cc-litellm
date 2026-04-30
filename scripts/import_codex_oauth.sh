#!/usr/bin/env bash
# Import local Codex CLI OAuth credentials into the optional codex-oauth-proxy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ENV="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}/.env"
CODEX_PROXY_URL="${CODEX_PROXY_URL:-http://localhost:18889}"
CODEX_SOURCE_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_OAUTH_HOME="${CODEX_OAUTH_HOME:-${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}/codex-oauth}"

if [[ -f "$CONFIG_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_ENV"
  set +a
fi

CODEX_PROXY_KEY="${CHATGPT_BROWSER_API_DIRECT_KEY:-pwd}"
CODEX_SOURCE_HOME="${CODEX_HOME:-$CODEX_SOURCE_HOME}"
CODEX_OAUTH_HOME="${CODEX_OAUTH_HOME:-${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}/codex-oauth}"

if [[ ! -f "$CODEX_SOURCE_HOME/auth.json" ]]; then
  echo "Codex auth not found at $CODEX_SOURCE_HOME/auth.json" >&2
  echo "Run Codex login first, then retry." >&2
  exit 1
fi

mkdir -p "$CODEX_OAUTH_HOME"
python3 - "$CODEX_SOURCE_HOME/auth.json" "$CODEX_OAUTH_HOME/auth.json" <<'PY'
import json
import pathlib
import sys

src = json.loads(pathlib.Path(sys.argv[1]).read_text())
tokens = src.get("tokens") if isinstance(src.get("tokens"), dict) else src
out = {
    "access_token": tokens.get("access_token"),
    "refresh_token": tokens.get("refresh_token"),
    "id_token": tokens.get("id_token"),
    "account_id": tokens.get("account_id"),
}
if not out["access_token"]:
    raise SystemExit("Codex auth does not contain access_token")
dest = pathlib.Path(sys.argv[2])
dest.write_text(json.dumps(out, indent=2) + "\n")
dest.chmod(0o600)
PY

export CODEX_OAUTH_HOME
docker compose -f "$ROOT/docker-compose.yml" --env-file "$CONFIG_ENV" up -d codex-oauth-proxy

for _ in {1..30}; do
  if curl -fsS "$CODEX_PROXY_URL/v1/models" -H "Authorization: Bearer $CODEX_PROXY_KEY" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

cookie_file="$(mktemp)"
trap 'rm -f "$cookie_file" /tmp/cc-litellm-codex-import.json' EXIT

curl -fsS -c "$cookie_file" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$CODEX_PROXY_KEY\"}" \
  "$CODEX_PROXY_URL/auth/dashboard-login" >/dev/null

curl -fsS -b "$cookie_file" -X POST "$CODEX_PROXY_URL/auth/import-cli" >/tmp/cc-litellm-codex-import.json

if grep -q '"success":true' /tmp/cc-litellm-codex-import.json; then
  echo "Imported Codex OAuth credentials into codex-oauth-proxy."
else
  cat /tmp/cc-litellm-codex-import.json >&2
  exit 1
fi
