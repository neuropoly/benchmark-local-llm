#!/usr/bin/env bash
# One-time install of the agents' web search under ~/llm-bench: SearXNG (a self-hosted metasearch
# engine: no API key, no account) and the lab-search MCP server (search_mcp.py). No root.
# Safe to run again: it updates SearXNG and keeps its settings. Usage: bash setup_search.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
mkdir -p "$LLMBENCH"/{bin,logs,search}
export PATH=$LLMBENCH/bin:$PATH
SRC=$LLMBENCH/search/searxng            # SearXNG source (it is installed from git, as its docs do)
SX_VENV=$LLMBENCH/search/searxng-venv
MCP_VENV=$LLMBENCH/search/mcp-venv      # separate venv: SearXNG pins its own httpx
SETTINGS=$LLMBENCH/search/settings.yml

if ! command -v uv >/dev/null; then
    echo "== installing uv into $LLMBENCH/bin"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$LLMBENCH/bin" UV_NO_MODIFY_PATH=1 sh
fi

echo "== SearXNG"
if [ -d "$SRC/.git" ]; then git -C "$SRC" pull -q --ff-only; else git clone -q --depth 1 https://github.com/searxng/searxng.git "$SRC"; fi
[ -x "$SX_VENV/bin/python" ] || uv venv -q --python 3.12 "$SX_VENV"
uv pip install -q --python "$SX_VENV/bin/python" -r "$SRC/requirements.txt" -r "$SRC/requirements-server.txt" setuptools wheel
uv pip install -q --python "$SX_VENV/bin/python" --no-build-isolation -e "$SRC"

# Our settings on top of SearXNG's defaults. JSON output is off by default (the MCP needs it); the
# limiter (bot protection) is for public instances and would need a Redis/Valkey server.
if [ ! -s "$SETTINGS" ]; then
    (umask 077; cat > "$SETTINGS" <<EOF
use_default_settings: true
general:
  instance_name: "NeuroPoly lab search"
server:
  bind_address: "127.0.0.1"
  port: $SEARXNG_PORT
  secret_key: "$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  limiter: false
  public_instance: false
  image_proxy: false
search:
  safe_search: 0
  formats:
    - html
    - json
EOF
    )
    echo "Settings written to $SETTINGS"
else
    echo "Keeping $SETTINGS"
fi

echo "== MCP server"
[ -x "$MCP_VENV/bin/python" ] || uv venv -q --python 3.12 "$MCP_VENV"
uv pip install -q --python "$MCP_VENV/bin/python" "mcp>=1.10" httpx trafilatura uvicorn

[ -s "$LLMBENCH/vllm.key" ] || echo "Note: no lab key yet ($LLMBENCH/vllm.key): setup_vllm.sh creates it, the MCP server needs it."
echo "Done. Next: bash $HERE/serve_search.sh   (serve_vllm.sh also starts it)"
