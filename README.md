# claude-code-fallback-proxy

A Claude Code plugin that automatically falls back to Azure AI when your Anthropic credits are exhausted — without losing your session or doing anything manually.

## How it works

Claude Code fires a `StopFailure` event with reason `billing_error` when your Anthropic credits run out. This plugin hooks into that event to:

1. Rewrite `~/.claude/settings.json` to route Claude Code through a local LiteLLM proxy
2. Pop a macOS notification telling you to restart Claude Code
3. On restart, the proxy transparently forwards requests to Azure AI

When you top up credits, run `bash install.sh` to reset back to direct Anthropic.

```
Normal:
  Claude Code ──► Anthropic API (direct, zero overhead)

Credits exhausted:
  StopFailure/billing_error hook fires
    ├── writes ANTHROPIC_BASE_URL to ~/.claude/settings.json
    └── macOS notification: "Credits exhausted — restart Claude Code"

After restart:
  Claude Code ──► LiteLLM proxy (localhost:4000) ──► Azure AI
```

## Requirements

- macOS (notifications via `osascript`)
- Docker Desktop
- Python 3 (stdlib only)
- [Claude Code](https://claude.ai/code)
- An Anthropic API key
- An Azure AI Services resource with a deployed chat model

## Install

### Via Claude Code plugin system (recommended)

```bash
claude plugin install https://github.com/your-username/claude-code-fallback-proxy
```

Then set up credentials:

```bash
cp .env.example .env
# edit .env with your keys
```

### Manual

```bash
git clone https://github.com/your-username/claude-code-fallback-proxy
cd claude-code-fallback-proxy
cp .env.example .env
# edit .env with your keys
bash install.sh
```

## Configuration

### `.env`

```env
ANTHROPIC_API_KEY=sk-ant-...
AZURE_AI_API_KEY=your-azure-ai-api-key
AZURE_AI_API_BASE=https://your-resource.cognitiveservices.azure.com/models
LITELLM_MASTER_KEY=sk-proxy-local   # any string — local proxy auth token
```

### `config.yaml` — change the fallback model

The default fallback model is `gpt-54-nano` via Azure AI. Replace with any model your Azure resource has deployed:

```yaml
- model_name: gpt-4o-mini           # ← your deployed model name
  litellm_params:
    model: azure_ai/gpt-4o-mini     # ← match this
    api_base: os.environ/AZURE_AI_API_BASE
    api_key: os.environ/AZURE_AI_API_KEY
```

You can find your model deployment name in Azure AI Studio → Deployments.

LiteLLM supports many providers (OpenAI, Bedrock, Vertex, Ollama). See [LiteLLM docs](https://docs.litellm.ai) for the full list.

## Files

```
├── .claude-plugin/
│   ├── plugin.json          # Claude Code plugin manifest
│   └── marketplace.json     # Marketplace metadata
├── hooks/
│   └── hooks.json           # SessionStart + StopFailure/billing_error hooks
├── scripts/
│   ├── session_start.sh     # Keeps proxy + alert server alive on session start
│   └── billing_error.sh     # Activates proxy and sends notification on credit exhaustion
├── config.yaml              # LiteLLM model list and fallback routing
├── docker-compose.yml       # LiteLLM proxy on port 4000
├── alert.py                 # Webhook server → macOS notifications (port 4001)
├── .env.example             # Credential template
└── install.sh               # Manual install fallback
```

## Ports

| Port | Service |
|------|---------|
| 4000 | LiteLLM proxy (OpenAI-compatible) |
| 4001 | Alert webhook server |

## Switching back to direct Anthropic

Once credits are topped up:

```bash
bash install.sh
```

This clears `ANTHROPIC_BASE_URL` from `~/.claude/settings.json` and resets to direct Anthropic.

## Troubleshooting

**Proxy not starting**
```bash
docker compose logs litellm
```

**Test the notification manually**
```bash
curl -s -X POST http://localhost:4001 \
  -H "Content-Type: application/json" \
  -d '{"alert_type": "budget_crossed", "message": "test"}'
```

**Check if proxy mode is active**
```bash
grep -A3 '"env"' ~/.claude/settings.json
```
If `ANTHROPIC_BASE_URL` is present → proxy mode active. Absent → direct Anthropic.
