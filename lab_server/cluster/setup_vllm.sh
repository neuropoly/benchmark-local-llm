#!/usr/bin/env bash
# One-time install of vLLM + model weights under ~/llm-bench. No root, no .bashrc change.
# Usage: bash setup_vllm.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
mkdir -p "$LLMBENCH"/{bin,logs,hf}
export PATH=$LLMBENCH/bin:$PATH

if ! command -v uv >/dev/null; then
    echo "== installing uv into $LLMBENCH/bin"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$LLMBENCH/bin" UV_NO_MODIFY_PATH=1 sh
fi

VENV=$LLMBENCH/vllm-venv
if [ ! -x "$VENV/bin/vllm" ]; then
    echo "== creating $VENV and installing vllm${VLLM_VERSION:+==$VLLM_VERSION} (several GB, a few minutes)"
    uv venv --python 3.12 "$VENV"
    uv pip install --python "$VENV/bin/python" "vllm${VLLM_VERSION:+==$VLLM_VERSION}" --torch-backend=auto
fi
# FlashInfer JIT-compiles its Blackwell kernels with the venv's CUDA compiler (serve_vllm.sh sets CUDA_HOME).
# The whole compiler (nvcc + ptxas, crt headers, cicc in nvidia-nvvm) must match the CUDA runtime torch
# was built with, else "CUDA compiler and CUDA toolkit headers are incompatible" or ptxas "Unsupported
# .version". pip tends to pull newer compiler packages: align each one to the runtime.
cuda_ver() { uv pip show --python "$VENV/bin/python" "$1" 2>/dev/null | sed -n 's/^Version: \([0-9]*\.[0-9]*\).*/\1/p'; }
RT=$(cuda_ver nvidia-cuda-runtime)
FIX=()
for pkg in nvidia-cuda-nvcc nvidia-cuda-crt nvidia-nvvm; do
    v=$(cuda_ver "$pkg")
    [ -n "$RT" ] && [ -n "$v" ] && [ "$v" != "$RT" ] && FIX+=("$pkg==$RT.*") && echo "== $pkg $v does not match CUDA runtime $RT"
done
if [ ${#FIX[@]} -gt 0 ]; then
    uv pip install --python "$VENV/bin/python" "${FIX[@]}"
    rm -rf "$HOME/.cache/flashinfer"   # kernels built by the previous compiler
fi
for pkg in nvidia-cuda-runtime nvidia-cuda-nvcc nvidia-cuda-crt nvidia-nvvm; do echo "  $pkg $(cuda_ver "$pkg")"; done
"$VENV/bin/python" -c "import vllm, torch; print('vllm', vllm.__version__, '| torch', torch.__version__, '| cuda ok:', torch.cuda.is_available())"

# The PDF proxy in front of vLLM (doc_proxy.py): its own small venv. pypdfium2 reads the PDFs
# (Apache/BSD licensed, unlike PyMuPDF which is AGPL).
PROXY_VENV=$LLMBENCH/proxy-venv
echo "== PDF proxy venv ($PROXY_VENV)"
[ -x "$PROXY_VENV/bin/python" ] || uv venv -q --python 3.12 "$PROXY_VENV"
uv pip install -q --python "$PROXY_VENV/bin/python" starlette uvicorn httpx pypdfium2 pillow

echo "== downloading $MODEL into $HF_HOME"
time "$VENV/bin/hf" download "$MODEL"

KEY=$LLMBENCH/vllm.key
if [ ! -s "$KEY" ]; then
    (umask 077; python3 -c 'import secrets; print("lab-" + secrets.token_urlsafe(24))' > "$KEY")
    echo "== API key created in $KEY (share it with lab members, not publicly)"
fi

echo "== disk"
df -h "$HOME" | tail -1
quota -s 2>/dev/null | tail -1 || true
echo "Done. Next: bash $HERE/serve_vllm.sh"
