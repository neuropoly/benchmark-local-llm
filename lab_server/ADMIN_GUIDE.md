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
bash serve_vllm.sh      # start; returns once it answers ("Ready after N s"); starts the web search too
bash stop_vllm.sh       # stop and free GPU 1 (the web search keeps running: stop_search.sh)
tail -f ~/llm-bench/logs/vllm.log
```

- Run these from a tmux session of yours, not straight from SSH. The server itself runs in its own tmux session (`vllm`), so it survives your disconnection; `tmux attach -t vllm` to watch it, Ctrl+B then D to leave.
- The scripts do the `set_slot 1` and the venv activation themselves. Don't run them inside a slot.
- **After a tassan reboot**, the server is not restarted automatically: run `bash serve_vllm.sh` again.
- A normal start takes a few minutes (loading the weights, compiling, warming up).

## Web search for the agents

Claude Code's own WebSearch runs on Anthropic's servers, so it can't work with the lab model (it fails with `400 ... input_schema`). Instead, tassan runs its own search, which the launchers plug into Claude Code and OpenCode through the same tunnel:

```
agent on a laptop --tunnel, port 8002--> lab-search MCP server (search_mcp.py) --> SearXNG --> Google, Bing, DuckDuckGo, Wikipedia...
                                         tools: web_search, fetch                 127.0.0.1:8888
```

- **SearXNG** is an open-source metasearch engine: no API key, no account, nothing sent to an AI company. **search_mcp.py** is our MCP server (about 170 lines): `web_search` queries SearXNG, `fetch` downloads a page from tassan and returns its text. It asks for the lab key, like vLLM, and refuses to fetch local or private addresses (so a web page can't make an agent read services that only listen on tassan).
- One-time install, no root: `bash setup_search.sh` (SearXNG from git and the MCP server, each in a venv under `~/llm-bench/search/`).
- `serve_vllm.sh` starts it too, once vLLM is ready, if it is installed. By hand: `bash serve_search.sh` / `bash stop_search.sh` (they don't touch vLLM). It runs in the tmux sessions `searxng` and `search-mcp`, logs in `~/llm-bench/logs/searxng.log` and `search-mcp.log`. `status.sh` shows whether both are up.
- The launchers check that the search answers before starting the agent; if it doesn't, the agent starts anyway, without web search, and says so.
- All the lab's searches leave from tassan's address. Under heavy use, Google or Bing may answer with CAPTCHAs; SearXNG then uses the other engines. Its settings are in `~/llm-bench/search/settings.yml` (written once by `setup_search.sh`, kept on later runs).

## Changing the model

1. In `vllm.env`, change `MODEL`, `SERVED_NAME`, `TOOL_PARSER` and `EXTRA_ARGS` together. Tested setups are listed there as comments.
2. `bash setup_vllm.sh` downloads the new weights (it skips what is already installed).
3. `bash stop_vllm.sh && bash serve_vllm.sh`
4. If `SERVED_NAME` is new, add it to `client/opencode.json` (copy an existing model entry) and send users the updated file. Claude Code needs nothing: the launchers ask the server which model it runs.

Current model: Qwen3.6-27B FP8 (dense, thinking). Previous: Qwen3-Coder-Next 80B NVFP4 (faster, a bit weaker on our tasks). Going back is a matter of swapping the lines in `vllm.env`.

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
- **The agents say "no web search this session":** `bash status.sh` shows which part is down; `bash serve_search.sh` restarts it and says which log to read. If searches return nothing, look for engine errors or CAPTCHAs in `~/llm-bench/logs/searxng.log`.

## Updating the scripts

The scripts are maintained in the `lab_server/` folder of the benchmark repo. To push new versions to tassan, from a laptop:

```bash
scp lab_server/cluster/* <login>@tassan.neuro.polymtl.ca:llm-bench/lab_server/
```
