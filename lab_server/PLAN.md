# Runbook: lab coding assistant on tassan

Goal: a coding model on one tassan card that lab members use from OpenCode or Claude Code, several at once.
Context and rationale: `../LAB_BRIEF.md`. Each phase ends with a checkpoint; don't start the next one until it passes.

```
lab_server/
  PLAN.md                this runbook
  USER_GUIDE.md          one page for lab members
  cluster/               copied to tassan:~/llm-bench/lab_server/ by deploy-tassan.ps1
    vllm.env             default model, GPU (card 1), set_slot command, port, limits
    models.conf          the models switch_model.sh can serve
    switch_model.sh      change the served model (choice saved in ~/llm-bench/model.env)
    tmux_lib.sh          start/stop a server in its own tmux session (set_slot first, session closes with the server)
    preflight.sh         read-only check: tools, set_slot, our card free, disk, network, running servers
    serve_ollama.sh      start the round-2 Ollama in tmux "ollama" on our card (+ 64k "-cc" variant)
    stop_ollama.sh       stop it
    setup_vllm.sh        one-time: uv + vLLM venv + weights + API key
    serve_vllm.sh        start in tmux "vllm", wait until it answers
    stop_vllm.sh         stop, close the tmux session, kill leftovers, give the card back
    status.sh            servers, GPU memory, live running/waiting requests
    run_concurrency.sh   Phase 3 sweep: vLLM, then Ollama NUM_PARALLEL=1 and 4
  client/                on each Windows laptop
    deploy-tassan.ps1    push cluster scripts + concurrency_bench.py; -Fetch brings results back
    tassan-tunnel.ps1    SSH tunnel (leave open)
    check-tassan.ps1     server answers + model makes a real tool call
    smoke-test.ps1       checkpoints 1/2: each agent edits a scratch repo, result is tested
    opencode-tassan.ps1  OpenCode on the tassan model
    claude-tassan.ps1    Claude Code on the tassan model
    opencode.json        OpenCode config for lab members (sharing disabled, tassan providers only)
    opencode.bench.json  same + permissions for unattended runs (edits allowed, shell allow-list)
../concurrency_bench.py  multi-user load test (stdlib only, runs on tassan)
../run_tassan_tasks.py   Phase 5: the 5 ADS tasks with OpenCode or Claude Code on the tassan model
```

Card and tmux: everything runs on GPU 1 (`GPU=1` in `vllm.env`). Each server gets its own tmux session in which the scripts type `set_slot 1; exit` (set_slot opens a new shell confined to slot 1: ~46 GB RAM, 20 cores), then, in that shell, check the slot, export `CUDA_VISIBLE_DEVICES=1` (set_slot doesn't), activate the venv and `exec` the server. So the session closes by itself when the server stops. Lab rules: https://intranet.neuro.polymtl.ca/computing-resources/neuropoly/resource-sharing.html (book `gpu[1]` on the lab calendar). The stop scripts also kill leftover processes. Setup and benchmark sessions close when the script ends; output stays in `~/llm-bench/logs/`.

Ports: tassan vLLM `127.0.0.1:8000` -> laptop `127.0.0.1:8001`; tassan Ollama `127.0.0.1:11434` -> laptop `127.0.0.1:11435`.

Status (2026-10-09): Phases 0 to 2 and 5 done, from a Mac. vLLM 0.31.0 runs on tassan GPU 1, first with Qwen3-Coder-Next 80B NVFP4, now Qwen3.6-27B FP8 (better on the 5 ADS tasks, about 3x slower per user, still fine with 8 users). Claude Code and OpenCode both work through the tunnel. Phase 3 (full sweep on tassan) and Phase 4 (lab decisions) are open. Day-to-day operation: `ADMIN_GUIDE.md`; for lab members: `USER_GUIDE.md`.

---

## Phase 0: prerequisites (10 min)

- Polytechnique VPN on. OpenCode on the laptop (`npm install -g opencode-ai`, v1.18.35 already installed).
- Optional but saves typing the password every time: an SSH key (`ssh-keygen -t ed25519`, then append `~\.ssh\id_ed25519.pub` to `~/.ssh/authorized_keys` on tassan).
- Python for the laptop-side runners: the `.venv` in `benchmark-local-llm` was built for another Windows user and doesn't start on this account. Recreate it: `uv venv --python 3.12 .venv; uv pip install --python .venv -r requirements.lock.txt`.

```powershell
cd <...>\benchmark-local-llm\lab_server\client
$env:TASSAN_USER = "you@ge.polymtl.ca"
.\deploy-tassan.ps1
```

On tassan:

```bash
cd ~/llm-bench/lab_server && bash preflight.sh
```

**Checkpoint 0:** no `[WARN]` that matters (`set_slot` found, card 1 idle, disk room, huggingface.co and pypi.org reachable).

## Phase 1: agents on the Ollama server that already exists (20 min)

Uses what was installed on 2026-09-28 (Ollama 0.34.4 + qwen3-coder-next in `~/llm-bench`). Validates the tunnel and both agents before touching vLLM.

On tassan: `bash ~/llm-bench/lab_server/serve_ollama.sh`

On the laptop, window 1 (leave open): `.\tassan-tunnel.ps1`

Window 2: `.\smoke-test.ps1 -Backend ollama`

**Checkpoint 1:** "Tool call OK", then `median PASS` (OpenCode) and `variance PASS` (Claude Code). Then try both interactively on a clone of a real repo (not your working ADS checkout) for 10 minutes and note anything odd.

If an agent answers in prose without editing and `check-tassan.ps1 -Backend ollama` shows no tool call either, the problem is the Ollama chat template, and Phase 2 (vLLM with an explicit tool parser) is the fix.

## Phase 2: switch to vLLM (about 1 h, mostly downloads)

On tassan (run setup inside tmux so a dropped SSH doesn't kill the download):

```bash
cd ~/llm-bench/lab_server
bash stop_ollama.sh                  # frees the card (serve_vllm.sh refuses to start otherwise)
tmux new -s setup 'bash setup_vllm.sh 2>&1 | tee -a ~/llm-bench/logs/setup.log'   # uv, vLLM venv (~10 GB), weights (~45 GB), API key
bash serve_vllm.sh                   # waits until the server answers (first start: several minutes)
bash status.sh
cat ~/llm-bench/vllm.key             # copy it for the laptop
```

On the laptop (tunnel still open):

```powershell
$env:TASSAN_VLLM_KEY = "<key>"
.\smoke-test.ps1
```

**Checkpoint 2:** same as Phase 1, through vLLM. Note the start-up time and the `nvidia-smi` memory in `status.sh`.

Troubleshooting:
- **NVFP4 checkpoint fails to load** (unsupported quantization or kernel on this vLLM build): in `vllm.env` switch to the FP8 line (`unsloth/Qwen3-Coder-Next-FP8-Dynamic`, ~80 GB) and lower `MAX_MODEL_LEN=65536`, `MAX_NUM_SEQS=4`. Or pin `VLLM_VERSION` to a release known to work on Blackwell and rerun `setup_vllm.sh`.
- **Out of memory at start-up:** lowering `GPU_UTIL` is NOT the fix (less room for KV cache); lower `MAX_MODEL_LEN` or `MAX_NUM_SEQS`.
- **Tool calls come back as text:** check `TOOL_PARSER=qwen3_coder` and that the server log shows `--enable-auto-tool-choice`.
- **Server log:** `tail -f ~/llm-bench/logs/vllm.log`, or `tmux attach -t vllm` (detach with Ctrl+B then D).
- **Going back to Ollama:** `bash stop_vllm.sh && bash serve_ollama.sh`.

## Phase 3: measure multi-user behaviour (1 to 2 h)

All on tassan, so network latency is out of the picture. Same prompts and sizes for every run.

```bash
tmux new -s conc 'bash ~/llm-bench/lab_server/run_concurrency.sh 2>&1 | tee -a ~/llm-bench/logs/concurrency.log'
```

It runs vLLM (1 to 16 simultaneous users, then 8 users with random arrivals), then Ollama with `NUM_PARALLEL=1` and `4`, and leaves the card free at the end, including if it is interrupted or fails. Single parts: `run_concurrency.sh vllm` or `run_concurrency.sh ollama`. If Ollama can't fit 4 x 64k with `NUM_PARALLEL=4` (it says so in `~/llm-bench/logs/ollama.log`): `NUM_CTX=32768 bash run_concurrency.sh ollama`.

Back on the laptop: `.\deploy-tassan.ps1 -Fetch` (copies `conc_*.json` into `results\`).

**Checkpoint 3:** for each server, the table printed per level. The numbers that matter for the talk: time to first token p95 at 4 and 8 users (how long someone waits), total tokens/s (how much work the card does), and errors.

## Phase 4: open it to the lab

Decisions to take with the lab first (not technical):
- Who owns the server, and whether it runs permanently on card 1 or on demand (and who stops it).
- Which model: the 80B coder (default) or Qwen3.6-35B-A3B (smaller, leaves the card mostly free, thinking model).
- Key policy: one shared key (simple, current scripts) or per-user keys (Phase 6).

Then send `USER_GUIDE.md` + the `client/` folder + the key (privately). Any tassan account can use the tunnel; nobody needs their own install on tassan.

## Phase 5: round 3 of the benchmark (half a day of mostly unattended runs)

Same 5 ADS tasks as round 1, model fixed on tassan, harness varies. vLLM running, tunnel open, `$env:TASSAN_VLLM_KEY` set. From `benchmark-local-llm\`:

```powershell
.venv\Scripts\python.exe run_tassan_tasks.py --harness opencode     # -> results\custom_<task>_opencode-tassan-vllm.json
.venv\Scripts\python.exe run_tassan_tasks.py --harness claude       # -> results\custom_<task>_claude-tassan-vllm.json
```

Each run clones the task repo at its pinned commit into `work\`, sends the prompt once, and saves the diff, time, turns and tokens. Review by hand afterwards like round 1 (`review.success` in each JSON). The task repo paths in `custom_tasks\*\task.yaml` point to `C:/Users/Youssef/...`: adjust them if the ADS checkout lives elsewhere on this machine.

The 25 polyglot exercises with the 80B, through Aider (needs Ollama, not vLLM: `bash stop_vllm.sh && bash serve_ollama.sh` on tassan):

```powershell
$env:OLLAMA_API_BASE = "http://127.0.0.1:11435"
.venv\Scripts\python.exe run_aider_benchmark.py --models qwen3-coder-next:latest
```

Use the tag exactly as `ollama list` prints it on tassan; `aider_model_settings.yml` has the entry for `qwen3-coder-next:latest` (16k context, same as round 1).

## Phase 6 (optional, later)

- **Per-user keys, quotas and usage logs:** LiteLLM proxy in front of vLLM (needs a small Postgres; podman is on tassan, rootless use not yet checked).
- **Web chat for non-coders:** Open WebUI pointing at vLLM, with lab accounts.
- **Agent running on tassan itself** (sees the cluster filesystem with the user's own permissions, nothing crosses the network): install OpenCode or Claude Code in the user's home on tassan and point it at `http://127.0.0.1:8000`.
- **Auto-restart after reboot:** a systemd user service, which needs the admins to enable lingering for the account. Discuss with the lab before leaving a server running permanently.
