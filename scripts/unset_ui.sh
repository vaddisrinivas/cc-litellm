#!/usr/bin/env bash
# Disable cc-litellm's Claude Code hooks + proxy env overrides.
# Also stops any local LiteLLM proxy bound to :4000.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$PLUGIN_ROOT/uninstall.sh"
