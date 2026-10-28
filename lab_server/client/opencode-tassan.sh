#!/usr/bin/env bash
# OpenCode in the current folder, on the lab model served by tassan (macOS/Linux version of
# opencode-tassan.ps1). Opens the tunnel if needed and closes it on exit (tassan_lib.sh). Uses
# opencode.json next to this script (sharing disabled, tassan providers only) for this run only; your
# other OpenCode settings are untouched.
# Usage: cd /path/to/repo && /path/to/client/opencode-tassan.sh [opencode args...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/tassan_lib.sh"
command -v opencode >/dev/null || { echo "OpenCode is not installed: brew install opencode (or npm install -g opencode-ai)"; exit 1; }
provider=tassan; [ "${TASSAN_BACKEND:-vllm}" = ollama ] && provider=tassan-ollama
grep -q "\"$model\"" "$here/opencode.json" \
    || echo "Warning: $model is not listed in opencode.json, add it there (copy an existing model entry)."
echo "OpenCode -> tassan ($model)"
# PWD: OpenCode takes its project folder from it
export OPENCODE_CONFIG="$here/opencode.json" TASSAN_VLLM_KEY="$token" PWD="$(pwd)"
opencode "$@" --model "$provider/$model"   # no exec: this script must outlive opencode to close the tunnel
