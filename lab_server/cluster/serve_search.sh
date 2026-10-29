#!/usr/bin/env bash
# Start the agents' web search: SearXNG (tmux session "searxng") and the lab-search MCP server (tmux
# session "search-mcp"), each inside set_slot like vLLM, then wait until both answer.
# serve_vllm.sh runs this too. Logs: ~/llm-bench/logs/searxng.log, search-mcp.log
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
source "$HERE/tmux_lib.sh"
S=$LLMBENCH/search
KEY=$LLMBENCH/vllm.key
[ -x "$S/searxng-venv/bin/python" ] && [ -x "$S/mcp-venv/bin/python" ] || { echo "Web search not installed: bash $HERE/setup_search.sh"; exit 1; }
[ -s "$KEY" ] || { echo "missing $KEY (setup_vllm.sh creates it)"; exit 1; }

up() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$@" 2>/dev/null || true; }
searxng_up() { [ "$(up "http://127.0.0.1:$SEARXNG_PORT/healthz")" = 200 ]; }
# the MCP answers 401 without the key: that's enough to know it is up
mcp_up() { [ "$(up -X POST "http://127.0.0.1:$SEARCH_MCP_PORT/mcp")" = 401 ]; }

if ! tmux has-session -t searxng 2>/dev/null; then
    echo "=== $(date -Is) start SearXNG on 127.0.0.1:$SEARXNG_PORT" >> "$LLMBENCH/logs/searxng.log"
    start_session searxng "$LLMBENCH/logs/searxng.log" \
        "export SEARXNG_SETTINGS_PATH=$S/settings.yml; exec $S/searxng-venv/bin/python -m searx.webapp"
fi
if ! tmux has-session -t search-mcp 2>/dev/null; then
    echo "=== $(date -Is) start lab-search MCP on 127.0.0.1:$SEARCH_MCP_PORT" >> "$LLMBENCH/logs/search-mcp.log"
    start_session search-mcp "$LLMBENCH/logs/search-mcp.log" \
        "export SEARCH_MCP_PORT=$SEARCH_MCP_PORT SEARXNG_URL=http://127.0.0.1:$SEARXNG_PORT LAB_KEY_FILE=$KEY; \
exec $S/mcp-venv/bin/python $HERE/search_mcp.py"
fi

for i in $(seq 1 30); do
    if searxng_up && mcp_up; then
        echo "Web search up: MCP on 127.0.0.1:$SEARCH_MCP_PORT/mcp, SearXNG on 127.0.0.1:$SEARXNG_PORT"
        exit 0
    fi
    sleep 2
done
searxng_up || echo "SearXNG does not answer: tail $LLMBENCH/logs/searxng.log"
mcp_up || echo "The MCP server does not answer: tail $LLMBENCH/logs/search-mcp.log"
exit 1
