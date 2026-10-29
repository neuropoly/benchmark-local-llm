#!/usr/bin/env bash
# Stop the agents' web search (the MCP server and SearXNG). vLLM is not touched.
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
source "$HERE/tmux_lib.sh"
stop_session search-mcp 'search_mcp\.py'
stop_session searxng 'searx\.webapp'
echo "Web search stopped."
