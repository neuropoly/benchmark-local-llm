#!/usr/bin/env bash
# What is running on tassan right now: servers, GPU memory, and vLLM's live request counts.
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
echo "== tmux sessions"; tmux ls 2>/dev/null || echo "none"
echo "== GPUs"; nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv
echo "== GPU processes (card, pid, user, memory, command); ours should all be on card $GPU"
# nvidia-smi gives the card per process only as a bus id: map it back to the card index.
declare -A IDX
while IFS=', ' read -r i bus; do IDX[$bus]=$i; done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader)
nvidia-smi --query-compute-apps=gpu_bus_id,pid,used_memory --format=csv,noheader | while IFS=', ' read -r bus pid mem unit; do
    printf '  card %s  %-8s %-24s %6s %s  %s\n' "${IDX[$bus]:-?}" "$pid" "$(ps -o user= -p "$pid" 2>/dev/null)" \
        "$mem" "$unit" "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-60)"
done
echo "== vLLM"
if [ -s "$LLMBENCH/vllm.key" ] && curl -sf -H "Authorization: Bearer $(cat "$LLMBENCH/vllm.key")" "http://127.0.0.1:$PORT/v1/models" -o /dev/null; then
    echo "up on 127.0.0.1:$PORT"
    curl -s "http://127.0.0.1:$PORT/metrics" | grep -E '^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|gpu_cache_usage_perc)' || true
else
    echo "down"
fi
if [ "${DOC_PROXY:-0}" = 1 ]; then
    if tmux has-session -t doc-proxy 2>/dev/null; then
        echo "PDF proxy up on 127.0.0.1:$PORT, vLLM behind it on 127.0.0.1:$VLLM_PORT (log: $LLMBENCH/logs/doc-proxy.log)"
    else
        echo "PDF proxy not running: PDFs fail (restart: bash stop_vllm.sh && bash serve_vllm.sh)"
    fi
fi
echo "== Ollama"
curl -sf http://127.0.0.1:11434/api/ps 2>/dev/null || echo "down"
