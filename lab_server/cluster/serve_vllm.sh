#!/usr/bin/env bash
# Start the vLLM server in a detached tmux session named "vllm", then wait until it answers.
# Usage: bash serve_vllm.sh        (logs: ~/llm-bench/logs/vllm.log, attach: tmux attach -t vllm)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
source "$HERE/tmux_lib.sh"
SESSION=vllm
KEY=$LLMBENCH/vllm.key
LOG=$LLMBENCH/logs/vllm.log

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "vLLM already running (tmux session '$SESSION'). Stop it first: bash $HERE/stop_vllm.sh"
    exit 0
fi
[ -x "$LLMBENCH/vllm-venv/bin/vllm" ] || { echo "vLLM not installed, run setup_vllm.sh first"; exit 1; }
[ -s "$KEY" ] || { echo "missing $KEY, run setup_vllm.sh first"; exit 1; }

# vLLM grabs GPU_UTIL of the whole card at start-up and fails if that much is not free.
read -r free total < <(nvidia-smi -i "$GPU" --query-gpu=memory.free,memory.total --format=csv,noheader,nounits | tr -d ',')
need=$(python3 -c "print(int($GPU_UTIL * $total))")
if [ "$free" -lt "$need" ]; then
    echo "Card $GPU has $free MiB free, vLLM needs $need MiB (GPU_UTIL=$GPU_UTIL). Processes on it:"
    nvidia-smi -i "$GPU" --query-compute-apps=pid,process_name,used_memory --format=csv
    echo "If it is our Ollama server: bash $HERE/stop_ollama.sh   (or lower GPU_UTIL in vllm.env)"
    exit 1
fi

# FlashInfer compiles its Blackwell (sm_120) kernels at start-up with nvcc. The system one on tassan
# (/usr/bin/nvcc) is CUDA 12.0, too old for sm_120; use the nvcc that pip installed into the venv.
NVCC=$(ls "$LLMBENCH"/vllm-venv/lib/python3*/site-packages/nvidia/{cu*,cuda_nvcc}/bin/nvcc 2>/dev/null | head -1 || true)
[ -n "$NVCC" ] || { echo "no nvcc inside the vLLM venv (FlashInfer would fall back to /usr/bin/nvcc 12.0 and fail)"; exit 1; }
CUDA_HOME=$(dirname "$(dirname "$NVCC")")
echo "CUDA toolkit for FlashInfer: $CUDA_HOME ($("$NVCC" --version | grep -o 'release [0-9.]*'))"

CMD="export CUDA_VISIBLE_DEVICES=$GPU HF_HOME=$HF_HOME CUDA_DEVICE_ORDER=PCI_BUS_ID \
CUDA_HOME=$CUDA_HOME PATH=$CUDA_HOME/bin:\$PATH MAX_JOBS=${JIT_JOBS:-4} VLLM_API_KEY=\$(cat $KEY); source $LLMBENCH/vllm-venv/bin/activate; exec vllm serve $MODEL \
--served-model-name $SERVED_NAME --host 127.0.0.1 --port $PORT --max-model-len $MAX_MODEL_LEN \
--gpu-memory-utilization $GPU_UTIL --max-num-seqs $MAX_NUM_SEQS --enable-prefix-caching \
--enable-auto-tool-choice --tool-call-parser $TOOL_PARSER $EXTRA_ARGS"
echo "=== $(date -Is) start $MODEL as $SERVED_NAME on GPU $GPU ($SLOT_CMD)" >> "$LOG"
start_session "$SESSION" "$LOG" "$CMD"
# Ctrl+C while waiting: don't leave a half-started server behind. A dropped SSH (HUP) leaves it
# starting in tmux on purpose: the first start compiles kernels for a long time.
trap 'echo; echo "interrupted, stopping vLLM"; bash "$HERE/stop_vllm.sh"; exit 130' INT TERM

echo "Starting $MODEL on GPU $GPU, port $PORT (first start: weight loading + compilation, several minutes)"
for i in $(seq 1 $((${STARTUP_TIMEOUT:-2700} / 5))); do
    if curl -sf -H "Authorization: Bearer $(cat "$KEY")" "http://127.0.0.1:$PORT/v1/models" >/dev/null; then
        echo "Ready after $((i * 5)) s:"
        curl -s -H "Authorization: Bearer $(cat "$KEY")" "http://127.0.0.1:$PORT/v1/models"; echo
        nvidia-smi -i "$GPU" --query-gpu=index,memory.used,memory.total --format=csv
        trap - INT TERM
        # The agents' web search goes with it, if installed (setup_search.sh). Its failure doesn't stop vLLM.
        if [ -x "$LLMBENCH/search/mcp-venv/bin/python" ]; then
            bash "$HERE/serve_search.sh" || echo "Web search did not start (vLLM is fine). Retry: bash $HERE/serve_search.sh"
        fi
        exit 0
    fi
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "vLLM exited during start-up (session closed). Root cause (engine errors of this attempt):"
        # The tail of the log is only the API server's generic traceback; the cause is in EngineCore's lines.
        sed -n "$(grep -n '^=== ' "$LOG" | tail -1 | cut -d: -f1),\$p" "$LOG" \
            | grep 'ERROR' | grep -vE '^\S+ pid=[0-9]+\) ERROR .*\]\s+(File |\^|return |[a-z_]+ = )' | tail -n 25
        echo "Full log: $LOG"
        bash "$HERE/stop_vllm.sh" >/dev/null; exit 1
    fi
    sleep 5
done
echo "Still not ready after $((${STARTUP_TIMEOUT:-2700} / 60)) min (vLLM keeps starting in tmux). Check: tail -f $LOG   (stop it: bash $HERE/stop_vllm.sh)"
exit 1
