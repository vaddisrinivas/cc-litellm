# cc-litellm Revert

Switch back from LiteLLM proxy to direct Anthropic API. Use when usage limits have reset.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/revert.sh"
```

Run the bash block above. After completion, confirm Claude is back on direct Anthropic.
