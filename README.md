# cc-litellm

A Claude Code plugin that automatically falls back to Azure AI when your Anthropic credits are exhausted — without losing your session or doing anything manually.

## How it works

Claude Code fires a `StopFailure` event with reason `billing_error` when Anthropic credits run out. This plugin hooks into that event to:

1. Rewrite `~/.claude/settings.json` to route Claude Code through a local LiteLLM proxy
2. Pop a macOS notification: "Credits exhausted — restart Claude Code"
3. On restart, the proxy transparently forwards requests to Azure AI

When you top up credits, run `bash install.sh` to reset back to direct Anthropic.

```
Normal:
  Claude Code ──► Anthropic API (direct, zero overhead)

Credits exhausted:
  StopFailure/billing_error hook fires
    ├── writes ANTHROPIC_BASE_URL → ~/.claude/settings.json
    └── macOS notification: "Credits exhausted — restart Claude Code"

After restart:
  Claude Code ──► LiteLLM proxy (localhost:4000) ──► Azure AI
```

## Requirements

- macOS (notifications via `osascript`)
- Python 3 (stdlib only — for the alert webhook)
- [Claude Code](https://claude.ai/code)
- An Anthropic API key
- An Azure AI Services resource with a deployed chat model
- LiteLLM **or** Docker (to run the proxy — see [Proxy Setup](#proxy-setup))

## Install

### Via Claude Code plugin system

```bash
claude plugin install https://github.com/your-username/cc-litellm
bash ~/.claude/plugins/cache/your-username-cc-litellm/cc-litellm/*/install.sh
```

The second command sets up your credentials in `~/.config/cc-litellm/.env`.

### Manual

```bash
git clone https://github.com/your-username/cc-litellm
cd cc-litellm
bash install.sh
```

## Credentials

Fill in `~/.config/cc-litellm/.env` (created by `install.sh`):

```env
ANTHROPIC_API_KEY=sk-ant-...
AZURE_AI_API_KEY=your-azure-ai-api-key
AZURE_AI_API_BASE=https://your-resource.cognitiveservices.azure.com/models
LITELLM_MASTER_KEY=sk-proxy-local   # any string — local proxy auth token
```

Credentials live in `~/.config/cc-litellm/` — separate from the plugin code, never committed.

## Proxy Setup

The proxy runs on `localhost:4000`. You need one of:

### Option A — LiteLLM CLI (no Docker)

```bash
pip install 'litellm[proxy]'
```

The `SessionStart` hook starts the proxy automatically on each Claude Code session.

### Option B — Docker

```bash
# Docker Desktop must be running
# The SessionStart hook handles the rest
```

The hook prefers the native LiteLLM CLI if installed; falls back to Docker otherwise.

## Fallback Model

Edit `config.yaml` to set your Azure model:

```yaml
- model_name: your-model       # ← deployed model name in Azure AI Studio
  litellm_params:
    model: azure_ai/your-model
    api_base: os.environ/AZURE_AI_API_BASE
    api_key: os.environ/AZURE_AI_API_KEY
```

LiteLLM supports many other providers too (OpenAI, Bedrock, Vertex, Ollama). See [LiteLLM docs](https://docs.litellm.ai) for the full list.

## Files

```
├── .claude-plugin/
│   ├── plugin.json          # Claude Code plugin manifest
│   └── marketplace.json     # Marketplace metadata
├── hooks/
│   └── hooks.json           # SessionStart + StopFailure/billing_error hooks
├── scripts/
│   ├── session_start.sh     # Keeps proxy + alert server alive on session start
│   └── billing_error.sh     # Activates proxy + sends notification on credit exhaustion
├── config.yaml              # LiteLLM model list and fallback routing
├── docker-compose.yml       # Optional: run LiteLLM via Docker
├── alert.py                 # Webhook server → macOS notifications (port 4001)
├── .env.example             # Credential template (copied to ~/.config/cc-litellm/.env)
└── install.sh               # Setup script
```

## Switching back to direct Anthropic

Once credits are topped up:

```bash
bash install.sh
```

This clears `ANTHROPIC_BASE_URL` from `~/.claude/settings.json`.

## Troubleshooting

**Check proxy logs**
```bash
# LiteLLM CLI
tail -f ~/.config/cc-litellm/litellm.log

# Docker
docker compose logs litellm
```

**Test the notification**
```bash
curl -s -X POST http://localhost:4001 \
  -H "Content-Type: application/json" \
  -d '{"alert_type": "budget_crossed", "message": "test"}'
```

**Check if proxy mode is active**
```bash
grep -A3 '"env"' ~/.claude/settings.json
```
`ANTHROPIC_BASE_URL` present → proxy mode. Absent → direct Anthropic (normal).
