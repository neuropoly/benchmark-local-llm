#!/usr/bin/env bash
# Claude Code on the lab model served by tassan (macOS/Linux version of claude-tassan.ps1). Opens the
# tunnel if needed and closes it on exit (tassan_lib.sh). The variables only exist for this run:
# plain `claude` stays on your normal account.
# The window limits match the server's context (else Claude Code overflows it on long tasks).
# Usage: ./claude-tassan.sh [claude args...]        (Ollama server: TASSAN_BACKEND=ollama ./claude-tassan.sh)
set -euo pipefail
source "$(dirname "$0")/tassan_lib.sh"
command -v claude >/dev/null || { echo "Claude Code is not installed: run install-mac.sh, or  curl -fsSL https://claude.ai/install.sh | bash"; exit 1; }
echo "Claude Code -> tassan ($model)"
# no exec: this script must outlive claude to close the tunnel
env -u ANTHROPIC_API_KEY \
    ANTHROPIC_BASE_URL="$base" ANTHROPIC_AUTH_TOKEN="$token" ANTHROPIC_MODEL="$model" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$model" ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" CLAUDE_CODE_SUBAGENT_MODEL="$model" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=$window CLAUDE_CODE_AUTO_COMPACT_WINDOW=$window CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384 \
    claude --model "$model" "$@"
