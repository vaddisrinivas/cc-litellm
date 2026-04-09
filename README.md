# claude-code-fallback-proxy

Automatically falls back to Azure AI when your Anthropic credits are exhausted — without losing your session or manually doing anything.

## What it does

By default, Claude Code talks directly to Anthropic. When your credits run out, Claude Code fires a `StopFailure` event with reason `billing_error`. This project hooks into that event to:

1. Rewrite `~/.claude/settings.json` to point Claude Code at a local LiteLLM proxy
2. Pop a macOS notification telling you to restart Claude Code
3. On restart, the proxy transparently routes all requests to Azure AI

When you top up Anthropic credits, run `bash plugin/uninstall.sh` (or edit settings.json) to switch back.

```
Normal:            Claude Code ──► Anthropic API (direct, zero overhead)

Credits exhausted: StopFailure hook fires
                       │
                       ├── writes ANTHROPIC_BASE_URL to ~/.claude/settings.json
                       └── macOS notification: "Credits exhausted — restart Claude"

After restart:     Claude Code ──► LiteLLM proxy (localhost:4000) ──► Azure AI
```

## Requirements

- macOS (notifications via `osascript`)
- Docker Desktop
- Python 3 (standard library only — for the alert webhook)
- [Claude Code](https://claude.ai/code)
- An Anthropic API key
- An Azure AI Services resource with at least one deployed model

## Setup

### 1. Clone

```bash
git clone https://github.com/your-username/claude-code-fallback-proxy
cd claude-code-fallback-proxy
```

### 2. Configure credentials

```bash
cp .env.example .env
```

Edit `.env`:

```env
ANTHROPIC_API_KEY=sk-ant-...            # your Anthropic key (used by the proxy when active)
AZURE_AI_API_KEY=...                    # Azure AI Services key
AZURE_AI_API_BASE=https://your-resource.cognitiveservices.azure.com/models
LITELLM_MASTER_KEY=sk-proxy-local       # any string — local proxy auth token
```

### 3. Edit `config.yaml` to match your Azure deployment

The default config references `gpt-54-nano`. Replace with whatever model you have deployed:

```yaml
- model_name: gpt-54-nano          # ← change to your deployed model name
  litellm_params:
    model: azure_ai/gpt-54-nano    # ← match this too
    ...
```

You can find your model deployment name in the Azure AI Studio portal under **Deployments**.

### 4. Install

```bash
bash plugin/install.sh
```

This:
- Starts the LiteLLM proxy in Docker on port `4000`
- Starts the alert webhook server on port `4001`
- Registers two hooks in `~/.claude/settings.json`:
  - `SessionStart` — auto-restarts the proxy and alert server if they're down
  - `StopFailure/billing_error` — switches to proxy and sends notification on credit exhaustion

## Files

```
├── config.yaml                       # LiteLLM model list, fallbacks, budget config
├── docker-compose.yml                # Runs LiteLLM proxy on port 4000
├── alert.py                          # Tiny webhook server → macOS notifications (port 4001)
├── .env.example                      # Credential template (copy to .env)
└── plugin/
    ├── install.sh                    # One-shot setup script
    └── scripts/
        ├── session_start.sh          # SessionStart hook: ensures proxy + alert are running
        └── billing_error.sh          # StopFailure hook: activates proxy on credit exhaustion
```

## How the proxy works

The proxy is [LiteLLM](https://github.com/BerriAI/litellm), running in Docker. It exposes an OpenAI-compatible API on `localhost:4000` that Claude Code can talk to via `ANTHROPIC_BASE_URL`.

`config.yaml` defines:
- **Model aliases** — Claude model names (e.g. `claude-sonnet-4-6`) mapped to their actual providers
- **Fallbacks** — if a model fails, route to an alternative (e.g. `claude-sonnet-4-6` → `gpt-54-nano`)
- **Budget** — optional spend cap over a rolling period

When `billing_error.sh` activates the proxy, it sets:

```json
"env": {
  "ANTHROPIC_BASE_URL": "http://localhost:4000",
  "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local"
}
```

in `~/.claude/settings.json`. Claude Code picks this up on the next session start and routes all API calls through the proxy.

## Adding more fallback models

Edit `config.yaml` to add any provider LiteLLM supports (OpenAI, Bedrock, Vertex, Ollama, etc.):

```yaml
model_list:
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: my-fallback
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

router_settings:
  fallbacks:
    - {"claude-sonnet-4-6": ["my-fallback"]}
```

Then restart the proxy: `docker compose restart`

## Switching back to Anthropic

Once you've topped up credits, remove the proxy env vars from `~/.claude/settings.json`:

```bash
python3 -c "
import json
p = '$HOME/.claude/settings.json'
c = json.load(open(p))
c.get('env', {}).pop('ANTHROPIC_BASE_URL', None)
c.get('env', {}).pop('ANTHROPIC_AUTH_TOKEN', None)
json.dump(c, open(p,'w'), indent=2)
"
```

Or run `bash plugin/install.sh` again — it clears those keys as part of setup.

## Ports

| Port | Service |
|------|---------|
| 4000 | LiteLLM proxy (OpenAI-compatible) |
| 4001 | Alert webhook server |

## Troubleshooting

**Proxy not starting**
```bash
docker compose logs litellm
```

**Alert server not running after reboot**
The `SessionStart` hook restarts it automatically when you open Claude Code. Or run manually:
```bash
python3 alert.py 4001 &
```

**Test the notification manually**
```bash
curl -s -X POST http://localhost:4001 \
  -H "Content-Type: application/json" \
  -d '{"alert_type": "budget_crossed", "message": "test"}'
```

**Verify Claude Code is routing through the proxy**
Check `~/.claude/settings.json` for an `env` block with `ANTHROPIC_BASE_URL`. If it's absent, Claude Code is using Anthropic directly (normal state).
