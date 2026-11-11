#!/usr/bin/env bash
# Read-only check of tassan before installing or starting anything. Changes nothing.
# Usage: bash preflight.sh
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }

echo "== tools"
for t in tmux curl python3 nvidia-smi; do
    command -v "$t" >/dev/null && ok "$t" || warn "$t missing"
done
# tmux opens a login shell, so that is where set_slot must exist.
slot=${SLOT_CMD%% *}
if [ -z "$slot" ]; then echo "  [--]   no SLOT_CMD in vllm.env"
elif bash -lic "type $slot" >/dev/null 2>&1; then ok "$slot available in a login shell (vllm.env runs: $SLOT_CMD)"
else warn "$slot not found in a login shell: servers would refuse to start. Fix SLOT_CMD in vllm.env"; fi
[ -f "$LLMBENCH/env.sh" ] && ok "Ollama env ($LLMBENCH/env.sh)" || warn "no $LLMBENCH/env.sh: Ollama from round 2 not found (only needed for Phase 1 and 3)"
[ -x "$LLMBENCH/vllm-venv/bin/vllm" ] && ok "vLLM installed" || echo "  [--]   vLLM not installed yet (setup_vllm.sh)"
[ -f "$LLMBENCH/concurrency_bench.py" ] && ok "concurrency_bench.py" || warn "concurrency_bench.py missing (deploy-tassan.ps1 copies it)"

echo "== GPUs (card $GPU is ours)"
nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader | sed 's/^/  /'
others=$(nvidia-smi -i "$GPU" --query-compute-apps=pid,process_name,used_memory --format=csv,noheader)
if [ -n "$others" ]; then warn "processes on card $GPU:"; echo "$others" | sed 's/^/    /'; else ok "card $GPU idle"; fi

echo "== disk"
df -h "$HOME" | tail -1 | sed 's/^/  /'
quota -s 2>/dev/null | tail -1 | sed 's/^/  quota: /' || true
du -sh "$LLMBENCH" 2>/dev/null | sed 's/^/  llm-bench: /'
echo "  needs ~10 GB for the vLLM venv + ~45 GB for the NVFP4 weights (~80 GB for FP8)"

echo "== network"
curl -sfI https://huggingface.co -o /dev/null --max-time 10 && ok "huggingface.co reachable" || warn "huggingface.co not reachable"
curl -sfI https://pypi.org -o /dev/null --max-time 10 && ok "pypi.org reachable" || warn "pypi.org not reachable"

echo "== servers"
tmux ls 2>/dev/null | sed 's/^/  tmux: /' || echo "  no tmux sessions"
left=$(pgrep -a -u "$USER" -f 'vllm serve|VLLM::EngineCore|ollama (serve|runner)')
[ -n "$left" ] && { warn "server processes of ours still running (stop_vllm.sh / stop_ollama.sh clean them up):"; echo "$left" | sed 's/^/    /'; }
ss -ltn 2>/dev/null | grep -E ':(8000|8010|8002|8888|11434) ' | sed 's/^/  listening: /' || true
