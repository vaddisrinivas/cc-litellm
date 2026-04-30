#!/usr/bin/env bash
# Reusable E2E smoke tests for cc-litellm + chatgpt-browser.
#
# Usage:
#   bash scripts/test_e2e.sh
#   TEST_MODE=smoke bash scripts/test_e2e.sh
#   TEST_MODE=launch BROWSER_TEST_DELAY_SECONDS=30 bash scripts/test_e2e.sh
#   RUN_INSTALL=1 bash scripts/test_e2e.sh
#   SKIP_CLAUDE=1 bash scripts/test_e2e.sh
#
# Requirements:
# - Docker services running
# - CodeWebChat browser extension loaded/reloaded
# - chatgpt.com open and logged in
# - Claude CLI installed for Claude tests

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ENV="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}/.env"
MASTER_KEY="${LITELLM_MASTER_KEY:-sk-proxy-local}"
CHATGPT_BROWSER_KEY="${CHATGPT_BROWSER_API_KEY:-sk-chatgpt-browser-local}"
LITELLM_URL="${LITELLM_URL:-http://localhost:4000}"
BROWSER_URL="${CHATGPT_BROWSER_URL:-http://localhost:18080}"
SESSION_PREFIX="${SESSION_PREFIX:-e2e-$(date +%s)}"
SKIP_CLAUDE="${SKIP_CLAUDE:-0}"
RUN_INSTALL="${RUN_INSTALL:-0}"
COVERAGE_MIN="${COVERAGE_MIN:-45}"
TEST_MODE="${TEST_MODE:-offline}"
BROWSER_TEST_DELAY_SECONDS="${BROWSER_TEST_DELAY_SECONDS:-20}"
MAX_BROWSER_CALLS="${MAX_BROWSER_CALLS:-}"

case "$TEST_MODE" in
  offline|smoke|launch) ;;
  *)
    echo "TEST_MODE must be one of: offline, smoke, launch" >&2
    exit 2
    ;;
esac

if [[ -z "$MAX_BROWSER_CALLS" ]]; then
  case "$TEST_MODE" in
    offline) MAX_BROWSER_CALLS=0 ;;
    smoke) MAX_BROWSER_CALLS=3 ;;
    launch) MAX_BROWSER_CALLS=20 ;;
  esac
fi

pass_count=0
fail_count=0
warn_count=0
browser_call_count=0
browser_rate_limited=0
browser_ready=unknown

green=$'\033[32m'
red=$'\033[31m'
yellow=$'\033[33m'
reset=$'\033[0m'

log() { printf '%s\n' "$*"; }
pass() { pass_count=$((pass_count + 1)); log "${green}PASS${reset} $*"; }
fail() { fail_count=$((fail_count + 1)); log "${red}FAIL${reset} $*"; }
warn() { warn_count=$((warn_count + 1)); log "${yellow}WARN${reset} $*"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing command: $1"
    exit 1
  fi
}

json_get() {
  jq -r "$1 // empty" "$2" 2>/dev/null || true
}

curl_json() {
  local out="$1"
  shift
  local code
  code="$(curl -sS -w '%{http_code}' -o "$out" "$@")" || return 1
  printf '%s' "$code"
}

test_docker_config() {
  docker compose config >/tmp/cc-litellm-compose-config.yaml || {
    fail "docker compose config"
    return
  }
  pass "docker compose config"
}

before_browser_call() {
  local name="$1"
  if [[ "$browser_rate_limited" == "1" ]]; then
    warn "Skipping $name because a previous browser test detected ChatGPT rate limiting"
    return 1
  fi
  if (( browser_call_count >= MAX_BROWSER_CALLS )); then
    warn "Skipping $name because MAX_BROWSER_CALLS=$MAX_BROWSER_CALLS was reached"
    return 1
  fi
  if (( browser_call_count > 0 && BROWSER_TEST_DELAY_SECONDS > 0 )); then
    log "  waiting ${BROWSER_TEST_DELAY_SECONDS}s before browser call $((browser_call_count + 1))/${MAX_BROWSER_CALLS}: $name"
    sleep "$BROWSER_TEST_DELAY_SECONDS"
  fi
  browser_call_count=$((browser_call_count + 1))
  return 0
}

response_is_rate_limited() {
  local file="$1"
  grep -Eiq 'rate limit|rate-limited|too many requests|try again later|you.ve reached|temporarily unavailable|unusual activity' "$file"
}

handle_browser_response_issue() {
  local name="$1"
  local file="$2"
  local code="${3:-}"
  if response_is_rate_limited "$file"; then
    browser_rate_limited=1
    warn "$name hit ChatGPT rate limiting; skipping remaining browser-heavy tests"
    return 0
  fi
  return 1
}

expect_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name expected [$expected], got [$actual]"
  fi
}

expect_contains() {
  local name="$1"
  local expected="$2"
  local file="$3"
  if grep -Fq "$expected" "$file"; then
    pass "$name"
  else
    fail "$name expected file to contain [$expected]"
    sed -n '1,80p' "$file" >&2 || true
  fi
}

run_claude_json() {
  local out="$1"
  shift
  claude -p "$@" --output-format json --no-session-persistence > "$out"
}

run_claude_stream() {
  local out="$1"
  shift
  claude -p "$@" --output-format stream-json --include-partial-messages --verbose --no-session-persistence > "$out"
}

test_health() {
  local out="/tmp/cc-litellm-health.json"
  local code
  code="$(curl_json "$out" "$BROWSER_URL/health")" || {
    fail "browser proxy health request failed"
    return
  }
  if [[ "$code" != "200" ]]; then
    fail "browser proxy health HTTP $code"
    cat "$out" >&2
    return
  fi

  local browsers
  browsers="$(jq '.connected_browsers | length' "$out")"
  if [[ "$browsers" -gt 0 ]]; then
    pass "browser proxy health has connected browser(s)"
    browser_ready=1
  else
    browser_ready=0
    fail "browser proxy has no connected browser. Reload CodeWebChat extension and open chatgpt.com."
  fi

  code="$(curl_json "$out" "$BROWSER_URL/ready")" || true
  if [[ "$code" == "200" ]]; then
    browser_ready=1
    pass "browser proxy ready"
  else
    browser_ready=0
    fail "browser proxy ready HTTP $code"
  fi
}

test_static_and_unit_coverage() {
  bash -n install.sh uninstall.sh scripts/*.sh || {
    fail "shell syntax gate"
    return
  }
  pass "shell syntax gate"

  python3 -m py_compile chatgpt_browser_proxy/app.py || {
    fail "python syntax gate"
    return
  }
  pass "python syntax gate"

  PYTHONPATH=chatgpt_browser_proxy python3 -m pytest chatgpt_browser_proxy/tests \
    --cov=app --cov-report=term-missing --cov-fail-under="$COVERAGE_MIN" || {
      fail "unit tests and coverage gate"
      return
    }
  pass "unit tests and coverage gate"

  test_docker_config
}

test_models() {
  local out="/tmp/cc-litellm-models.json"
  local code
  code="$(curl_json "$out" "$LITELLM_URL/v1/models" -H "Authorization: Bearer $MASTER_KEY")" || {
    fail "LiteLLM models request failed"
    return
  }
  [[ "$code" == "200" ]] || {
    fail "LiteLLM models HTTP $code"
    cat "$out" >&2
    return
  }
  expect_contains "LiteLLM exposes chatgpt-browser" "chatgpt-browser" "$out"
  expect_contains "LiteLLM exposes opus route" "opus" "$out"
}

test_direct_chat() {
  before_browser_call "direct browser /v1/chat/completions" || return
  local out="/tmp/cc-litellm-direct-chat.json"
  local expected="direct-${SESSION_PREFIX}-ok"
  local code
  code="$(curl_json "$out" "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${SESSION_PREFIX}-direct\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ${expected}\"}]}")" || {
      fail "direct browser chat request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "direct browser /v1/chat/completions" "$out" "$code" && return
    fail "direct browser chat HTTP $code"
    cat "$out" >&2
    return
  }
  expect_eq "direct browser /v1/chat/completions" "$expected" "$(json_get '.choices[0].message.content' "$out")"
}

test_direct_responses() {
  before_browser_call "direct browser /v1/responses" || return
  local out="/tmp/cc-litellm-direct-responses.json"
  local expected="responses-${SESSION_PREFIX}-ok"
  local code
  code="$(curl_json "$out" "$BROWSER_URL/v1/responses" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"input\":\"Reply with exactly: ${expected}\",\"metadata\":{\"session_id\":\"${SESSION_PREFIX}-responses\"}}")" || {
      fail "direct browser responses request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "direct browser /v1/responses" "$out" "$code" && return
    fail "direct browser responses HTTP $code"
    cat "$out" >&2
    return
  }
  expect_eq "direct browser /v1/responses" "$expected" "$(json_get '.output_text' "$out")"
}

test_direct_stream() {
  before_browser_call "direct browser streaming" || return
  local out="/tmp/cc-litellm-direct-stream.txt"
  local expected="stream-${SESSION_PREFIX}-ok"
  curl -sS --max-time 220 "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${SESSION_PREFIX}-stream\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ${expected}\"}]}" > "$out" || {
      fail "direct browser streaming request failed"
      return
    }
  handle_browser_response_issue "direct browser streaming" "$out" && return
  expect_contains "direct browser stream emits expected content" "$expected" "$out"
  expect_contains "direct browser stream terminates" "data: [DONE]" "$out"
}

test_direct_session_resume() {
  local session="${SESSION_PREFIX}-resume"
  local out="/tmp/cc-litellm-session-resume.json"
  local code
  local word="papaya-${SESSION_PREFIX}"

  before_browser_call "session seed" || return
  code="$(curl_json "$out" "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${session}\",\"messages\":[{\"role\":\"user\",\"content\":\"Remember this codeword for the next message: ${word}. Reply exactly: saved\"}]}")" || {
      fail "session seed request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "session seed" "$out" "$code" && return
    fail "session seed HTTP $code"
    cat "$out" >&2
    return
  }

  before_browser_call "session resume" || return
  code="$(curl_json "$out" "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${session}\",\"messages\":[{\"role\":\"user\",\"content\":\"What codeword did I ask you to remember? Reply only with the codeword.\"}]}")" || {
      fail "session resume request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "session resume" "$out" "$code" && return
    fail "session resume HTTP $code"
    cat "$out" >&2
    return
  }
  expect_eq "browser session resume" "$word" "$(json_get '.choices[0].message.content' "$out")"

  before_browser_call "session reset" || return
  code="$(curl_json "$out" "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${session}\",\"new_session\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply exactly: reset-ok\"}]}")" || {
      fail "session reset request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "session reset" "$out" "$code" && return
    fail "session reset HTTP $code"
    cat "$out" >&2
    return
  }
  expect_eq "browser session reset/new chat" "reset-ok" "$(json_get '.choices[0].message.content' "$out")"
}

test_direct_tool_call_shape() {
  before_browser_call "direct browser tool-call shape" || return
  local out="/tmp/cc-litellm-tool-shape.json"
  local code
  code="$(curl_json "$out" "$BROWSER_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CHATGPT_BROWSER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"chatgpt-browser","session_id":"'"${SESSION_PREFIX}"'-tool-shape","tool_choice":"required","messages":[{"role":"user","content":"Use the Bash tool to run printf browser-tool-shape-ok. Return a tool call only."}],"tools":[{"type":"function","function":{"name":"Bash","description":"Run a shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}]}')" || {
      fail "direct tool-call shape request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "direct browser tool-call shape" "$out" "$code" && return
    fail "direct tool-call shape HTTP $code"
    cat "$out" >&2
    return
  }
  if [[ "$(json_get '.choices[0].finish_reason' "$out")" == "tool_calls" ]] &&
     [[ "$(json_get '.choices[0].message.tool_calls[0].function.name' "$out")" == "Bash" ]]; then
    pass "direct browser tool-call shape"
  else
    warn "direct browser did not return parseable tool_calls; see $out"
  fi
}

test_litellm_chat() {
  before_browser_call "LiteLLM -> chatgpt-browser" || return
  local out="/tmp/cc-litellm-chat.json"
  local expected="litellm-${SESSION_PREFIX}-ok"
  local code
  code="$(curl_json "$out" "$LITELLM_URL/v1/chat/completions" \
    -H "Authorization: Bearer $MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"chatgpt-browser\",\"session_id\":\"${SESSION_PREFIX}-litellm\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ${expected}\"}]}")" || {
      fail "LiteLLM chatgpt-browser request failed"
      return
    }
  [[ "$code" == "200" ]] || {
    handle_browser_response_issue "LiteLLM -> chatgpt-browser" "$out" "$code" && return
    fail "LiteLLM chatgpt-browser HTTP $code"
    cat "$out" >&2
    return
  }
  expect_eq "LiteLLM -> chatgpt-browser" "$expected" "$(json_get '.choices[0].message.content' "$out")"
}

test_claude_default() {
  local out="/tmp/cc-litellm-claude-default.json"
  local expected="claude-default-${SESSION_PREFIX}-ok"
  run_claude_json "$out" "Reply with exactly: ${expected}" --model 'opus[1m]' || {
    fail "Claude default route failed"
    cat "$out" >&2 || true
    return
  }
  expect_eq "Claude default opus[1m] route" "$expected" "$(json_get '.result' "$out")"
}

test_claude_browser() {
  before_browser_call "Claude explicit chatgpt-browser route" || return
  local out="/tmp/cc-litellm-claude-browser.json"
  local expected="claude-browser-${SESSION_PREFIX}-ok"
  run_claude_json "$out" "Reply with exactly: ${expected}" --model chatgpt-browser || {
    fail "Claude chatgpt-browser route failed"
    cat "$out" >&2 || true
    return
  }
  handle_browser_response_issue "Claude explicit chatgpt-browser route" "$out" && return
  expect_eq "Claude explicit chatgpt-browser route" "$expected" "$(json_get '.result' "$out")"
}

test_claude_default_tool_call() {
  local out="/tmp/cc-litellm-claude-default-tool.jsonl"
  local expected="tool-default-${SESSION_PREFIX}-ok"
  run_claude_stream "$out" "Use Bash to run: printf ${expected}. Return only the command output." --model 'opus[1m]' --tools Bash || {
    fail "Claude default tool-call route failed"
    sed -n '1,120p' "$out" >&2 || true
    return
  }
  expect_contains "Claude default route emits tool use" '"type":"tool_use"' "$out"
  expect_contains "Claude default route returns tool output" "$expected" "$out"
}

test_claude_browser_tool_fidelity() {
  before_browser_call "Claude browser tool-fidelity" || return
  local out="/tmp/cc-litellm-claude-browser-tool.jsonl"
  local expected="tool-browser-${SESSION_PREFIX}-ok"
  run_claude_stream "$out" "Use Bash to run: printf ${expected}. Return only the command output." --model chatgpt-browser --tools Bash || {
    fail "Claude browser tool-fidelity test failed"
    sed -n '1,120p' "$out" >&2 || true
    return
  }
  handle_browser_response_issue "Claude browser tool-fidelity" "$out" && return
  expect_contains "Claude browser route returns requested text" "$expected" "$out"
  if grep -Fq '"type":"tool_use"' "$out"; then
    pass "Claude browser route emitted native tool use"
  else
    warn "Claude browser route did not emit native tool_use; browser ChatGPT is working as text LLM provider, not full Claude tool-call transport"
  fi
}

test_claude_skill_context() {
  before_browser_call "Claude browser skill/context route" || return
  local out="/tmp/cc-litellm-claude-skill-context.json"
  local expected="skill-context-${SESSION_PREFIX}-ok"
  run_claude_json "$out" "Follow this temporary skill instruction: whenever asked for the marker, reply exactly ${expected}. Marker?" --model chatgpt-browser || {
    fail "Claude browser skill/context route failed"
    cat "$out" >&2 || true
    return
  }
  handle_browser_response_issue "Claude browser skill/context route" "$out" && return
  expect_contains "Claude browser skill-style context" "$expected" "$out"
}

main() {
  cd "$ROOT"
  need curl
  need jq
  need docker

  if [[ "$RUN_INSTALL" == "1" ]]; then
    bash "$ROOT/install.sh" claude
  fi

  if [[ -f "$CONFIG_ENV" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$CONFIG_ENV"
    set +a
    MASTER_KEY="${LITELLM_MASTER_KEY:-$MASTER_KEY}"
    CHATGPT_BROWSER_KEY="${CHATGPT_BROWSER_API_KEY:-$CHATGPT_BROWSER_KEY}"
  fi

  log "cc-litellm E2E tests"
  log "  LiteLLM:          $LITELLM_URL"
  log "  Browser proxy:    $BROWSER_URL"
  log "  Session prefix:   $SESSION_PREFIX"
  log "  Mode:             $TEST_MODE"
  log "  Browser calls:    max $MAX_BROWSER_CALLS, delay ${BROWSER_TEST_DELAY_SECONDS}s"
  log ""

  test_static_and_unit_coverage
  if [[ "$TEST_MODE" == "offline" ]]; then
    log "Offline mode complete; no browser or Claude API calls were made."
  else
    test_health
    test_models
    if [[ "$browser_ready" == "1" ]]; then
      case "$TEST_MODE" in
        smoke)
          test_direct_chat
          test_litellm_chat
          if [[ "$SKIP_CLAUDE" == "1" ]]; then
            warn "Skipping Claude CLI tests (SKIP_CLAUDE=1)"
          elif command -v claude >/dev/null 2>&1; then
            test_claude_browser
          else
            warn "Skipping Claude CLI tests because claude is not installed"
          fi
          ;;
        launch)
          test_direct_chat
          test_direct_responses
          test_direct_stream
          test_direct_session_resume
          test_direct_tool_call_shape
          test_litellm_chat
          if [[ "$SKIP_CLAUDE" == "1" ]]; then
            warn "Skipping Claude CLI tests (SKIP_CLAUDE=1)"
          elif command -v claude >/dev/null 2>&1; then
            test_claude_default
            test_claude_browser
            test_claude_default_tool_call
            test_claude_browser_tool_fidelity
            test_claude_skill_context
          else
            warn "Skipping Claude CLI tests because claude is not installed"
          fi
          ;;
      esac
    else
      warn "Skipping browser-dependent tests because /ready is false"
    fi
  fi

  log ""
  log "Summary: ${green}${pass_count} passed${reset}, ${yellow}${warn_count} warned${reset}, ${red}${fail_count} failed${reset}; browser calls used ${browser_call_count}/${MAX_BROWSER_CALLS}"
  [[ "$fail_count" -eq 0 ]]
}

main "$@"
