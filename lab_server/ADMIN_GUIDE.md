# Running the lab model server on tassan

For whoever runs the server. Lab members only need `USER_GUIDE.md`. The full setup history and benchmarks are in `PLAN.md`.

Everything lives in the home of the account that runs it (`~/llm-bench`): no root, nothing system-wide. The server runs vLLM on **GPU 1**, inside `set_slot 1` (lab rule), listening on `127.0.0.1:8000` of tassan only, behind an API key. Users reach it through SSH tunnels.

```
~/llm-bench/
  lab_server/     the scripts below (vllm.env is the only file to edit)
  vllm-venv/      vLLM 0.31.0 + its own CUDA 13.2 compiler
  hf/             model weights
  vllm.key        the lab API key
  logs/vllm.log   server log
```

Book `gpu[1]` on the lab calendar while the server runs (see the intranet page on resource sharing).

## Day to day

```bash
cd ~/llm-bench/lab_server
bash status.sh          # is it up, GPU memory, requests running/waiting, who is on each card
bash serve_vllm.sh      # start; returns once it answers ("Ready after N s")
bash stop_vllm.sh       # stop and free GPU 1
tail -f ~/llm-bench/logs/vllm.log
```

- Run these from a tmux session of yours, not straight from SSH. The server itself runs in its own tmux session (`vllm`), so it survives your disconnection; `tmux attach -t vllm` to watch it, Ctrl+B then D to leave.
- The scripts do the `set_slot 1` and the venv activation themselves. Don't run them inside a slot.
- **After a tassan reboot**, the server is not restarted automatically: run `bash serve_vllm.sh` again.
- A normal start takes a few minutes (loading the weights, compiling, warming up).

## PDFs (the proxy in front of vLLM)

When Claude Code reads a PDF (Read tool, `@paper.pdf`, drag and drop), it sends it as an Anthropic `document` block. vLLM doesn't accept that block type (not in 0.32 nor on its main branch yet) and rejects the request with `400 ... 'document'`; the PDF stays in the history, so the whole session is stuck (issue #4). A small proxy fixes it:

```
clients --tunnel--> 127.0.0.1:8000  doc_proxy.py  --> 127.0.0.1:8010  vLLM
                    (PORT)          document blocks -> page text + page images   (VLLM_PORT)
```

- Each PDF becomes the text of its pages, plus an image of the pages that have figures, vector plots or almost no text (scans), at most 12 per PDF. Images are sent only if the model has a vision encoder (Qwen3.6-27B does, the 80B coder doesn't): `PDF_PAGE_IMAGES=auto` in `vllm.env` checks the model's `config.json`.
- Everything else goes through untouched, streaming included. A converted PDF is cached, so the same PDF coming back on every turn of a session is converted once.
- `setup_vllm.sh` installs it (its own small venv, `~/llm-bench/proxy-venv`; it reads PDFs with pypdfium2). `serve_vllm.sh` starts it in the tmux session `doc-proxy`, `stop_vllm.sh` stops it, `status.sh` shows it. Log: `~/llm-bench/logs/doc-proxy.log` (one line per converted PDF).
- Clients see no change: the tunnel still goes to port 8000.
- If the proxy itself causes trouble, `DOC_PROXY=0` in `vllm.env` and a restart put vLLM back on port 8000 directly (PDFs then fail again).

## Changing the model

```bash
cd ~/llm-bench/lab_server
bash switch_model.sh                    # the models it knows, which one is set, which one runs, which are downloaded
bash switch_model.sh qwen3-coder-next   # download if needed, stop vLLM, start it on that model, wait until it answers
bash switch_model.sh default            # back to the model in vllm.env (Qwen3.6-27B)
```

- Run it from your tmux, like `serve_vllm.sh`. Users connected at that moment lose their current request; tell them first.
- If the new model does not start, the script says so and prints the command to go back to the previous one.
- `--no-start` only records the choice, for the next `serve_vllm.sh`.
- The choice is saved in `~/llm-bench/model.env`, outside `lab_server/`, so redeploying the scripts doesn't undo it.
- Claude Code users need nothing: the launchers ask the server which model it runs. OpenCode needs the model's name in `client/opencode.json` (the models in `models.conf` are all there).

To add a model: add a line to `models.conf` (name, Hugging Face repo, tool-call parser, extra vLLM arguments, a note), add the name to `client/opencode.json`, redeploy, then `bash switch_model.sh <name>`.

Default model: Qwen3.6-27B FP8 (dense, thinking). Previous: Qwen3-Coder-Next 80B NVFP4 (faster, a bit weaker on our tasks).

## The key

- It is in `~/llm-bench/vllm.key`, created by `setup_vllm.sh`. Send it to users privately.
- To change it (someone left, it leaked): delete the file, run `bash setup_vllm.sh` (creates a new one), restart the server, send the new key.

## Settings worth knowing (`vllm.env`)

| Setting | Value | Why |
|---|---|---|
| `GPU` | 1 | the card the lab gave us; every script follows it |
| `GPU_UTIL` | 0.90 | vLLM takes 90% of the card at start-up (weights + room for users' context) |
| `MAX_MODEL_LEN` | 131072 | max context per request. The client launchers declare the same value: change both together |
| `MAX_NUM_SEQS` | 16 | max requests processed together; more wait in a queue |
| `JIT_JOBS` | 4 | parallel kernel compilations on a first start (see below) |
| `VLLM_VERSION` | 0.31.0 | pinned: a new version means new kernels to compile |

## When something goes wrong

- **`serve_vllm.sh` says the card isn't free:** someone (maybe you) has a process on GPU 1. `bash status.sh` shows who.
- **vLLM exits during start-up:** `serve_vllm.sh` prints the engine's error lines. Out of memory: lower `MAX_MODEL_LEN` or `MAX_NUM_SEQS` (lowering `GPU_UTIL` makes it worse).
- **A first start with a new model or vLLM version compiles GPU kernels** (FlashInfer): from minutes to over an hour, in `~/.cache/flashinfer`, done once. Keep `JIT_JOBS` at 4 or less: each compiler can take 5 to 7 GB of RAM and the slot has about 46 GB. With 8 jobs, the first 80B start stalled for 3 hours.
- **Compiler errors** (`CUDA compiler and CUDA toolkit headers are incompatible`, `Unsupported .version`): the CUDA compiler packages in the venv don't match the runtime. `bash setup_vllm.sh` realigns them.
- **Tool calls come back as text:** check `TOOL_PARSER` in `vllm.env`.
- **Users get `400 ... 'document'` when a PDF is read:** the PDF proxy is not running (`status.sh` says so). If `serve_vllm.sh` printed "the PDF proxy is not installed", run `bash setup_vllm.sh`, then `bash stop_vllm.sh && bash serve_vllm.sh`. A PDF that fails to convert shows as a one-line note in the conversation; details in `~/llm-bench/logs/doc-proxy.log`.

## Updating the scripts

The scripts are maintained in the `lab_server/` folder of the benchmark repo. To push new versions to tassan, from a laptop:

```bash
scp lab_server/cluster/* <login>@tassan.neuro.polymtl.ca:llm-bench/lab_server/
```
