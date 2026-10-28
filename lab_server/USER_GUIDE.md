# Using the lab coding assistant (tassan)

A coding model runs on GPU 1 of the lab station tassan. You use it **from your laptop** with an AI coding agent (Claude Code or OpenCode) that reads and edits your files and runs commands, or directly from your own Python code. Prompts and code stay inside Polytechnique's network, and it costs nothing per use. The GPU is shared with the rest of the lab.

**The model:** Qwen3.6-27B, a "thinking" model (it reasons before answering). On 5 real tasks from the AxonDeepSeg codebase (add a feature, fix a bug, refactor across 5 files, write a test module, explain a pipeline), it did as well as Claude Sonnet: all tests passing, no regressions. It is slower than a cloud model: expect **2 to 12 minutes for a real task**, and about 45 tokens per second when it writes (a token is a word or a piece of one).

**Everything in this guide runs on your laptop.** You never need to install or run anything on tassan: the server is already running there. Your tassan login is only used to open the tunnel.

## How it fits together

```
your laptop                                            tassan
  Claude Code / OpenCode / your script
        |  http://127.0.0.1:8001  + lab key
        v
  SSH tunnel (tassan-tunnel.sh) ===== VPN + SSH =====>  model server on 127.0.0.1:8000 (GPU 1)
```

- The **tunnel** forwards port 8001 on your laptop to the server on tassan. It must stay open while you work.
- The **lab key** is a password shared by the lab: the server refuses requests without it.
- The **launchers** (`claude-tassan.sh`, `opencode-tassan.sh`) start the agent pointed at the tunnel, with the key and the right settings, for that session only.

## What you need

- The **Polytechnique VPN**, and a **login on tassan** (the one you use for training jobs, e.g. `you@ge.polymtl.ca`).
- **The lab key** (ask Youssef; he sends it privately).
- On your laptop: `git`, and on macOS / Linux `python3` and `curl` (already there on macOS); on Windows, PowerShell.

## Mac: the quick way

With the VPN on, paste this in a terminal and answer its questions (your tassan login, the lab key, your tassan password once):

```bash
curl -fsSL https://raw.githubusercontent.com/yolaatar/benchmark-local-llm/main/lab_server/client/install-mac.sh | bash
```

It installs the scripts and Claude Code, sets up the tunnel so it needs no password, adds the `claude-lab` / `opencode-lab` shortcuts and runs a check. Then, in a new terminal, from any project: `claude-lab`. It opens the tunnel by itself and closes it when you quit, so on a Mac you can skip the rest of this setup and step 2 of "Every time". Running the installer again is safe (it updates the scripts).

## One-time setup (on your laptop)

### 1. Get the scripts

```bash
git clone https://github.com/yolaatar/benchmark-local-llm.git ~/benchmark-local-llm
```

The scripts you need are in `~/benchmark-local-llm/lab_server/client/`. Later, `git pull` in that folder gets updates.

### 2. Save the lab key

Save it once in a file in your home folder; every script reads it from there. Replace `PASTE-THE-KEY-HERE` with the key you received (it starts with `lab-`), keep the quotes:

- macOS / Linux:
  ```bash
  (umask 077; printf '%s' 'PASTE-THE-KEY-HERE' > ~/.tassan_vllm_key)
  cat ~/.tassan_vllm_key        # check: prints the key, nothing else
  ```
- Windows (PowerShell):
  ```powershell
  Set-Content -NoNewline "$HOME\.tassan_vllm_key" 'PASTE-THE-KEY-HERE'
  Get-Content "$HOME\.tassan_vllm_key"
  ```

The file stays on your laptop. Never commit it, paste it in a chat channel, or share it in a screenshot.

### 3. Install an agent

One is enough; both work with the lab model.

- **Claude Code**
  - macOS / Linux: `curl -fsSL https://claude.ai/install.sh | bash` (or `brew install --cask claude-code`)
  - Windows (PowerShell): `irm https://claude.ai/install.ps1 | iex`
  - With the lab launcher it talks only to the lab server: no Anthropic subscription is used, and you shouldn't have to log in.
- **OpenCode** (open source)
  - macOS: `brew install opencode`
  - Linux / Windows: install Node.js, then `npm install -g opencode-ai`

Check: `claude --version` or `opencode --version`.

### 4. Shortcuts (recommended, macOS / Linux)

So you can type `claude-lab` in any project instead of the full path. Add to `~/.zshrc` (or `~/.bashrc`), then open a new terminal:

```bash
export TASSAN_USER=you@ge.polymtl.ca                       # your tassan login
alias tassan-tunnel=~/benchmark-local-llm/lab_server/client/tassan-tunnel.sh
alias tassan-check=~/benchmark-local-llm/lab_server/client/check-tassan.sh
alias claude-lab=~/benchmark-local-llm/lab_server/client/claude-tassan.sh
alias opencode-lab=~/benchmark-local-llm/lab_server/client/opencode-tassan.sh
```

On Windows, run the scripts from the `client` folder as shown below, and if PowerShell refuses to run them, run once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 5. Optional: no password for the tunnel

```bash
ssh-keygen -t ed25519                                     # press Enter at each question
ssh-copy-id you@ge.polymtl.ca@tassan.neuro.polymtl.ca     # asks your tassan password one last time
```

(On Windows, append the content of `~\.ssh\id_ed25519.pub` to `~/.ssh/authorized_keys` on tassan.)

## Every time you want to use it

1. **Connect the VPN.**
2. **Open the tunnel** in a terminal, and leave that terminal open while you work. It prints `Tunnel to tassan... open`, asks for your tassan password (unless you did step 5), then stays silent: that's normal, it's working.
   - macOS / Linux: nothing to do, `claude-lab`, `opencode-lab` and `tassan-check` open it themselves (and close it when the last one quits). `tassan-tunnel` still opens one by hand, for your own scripts; `tassan-tunnel status` / `stop` check or close the background one.
   - Windows: `cd <...>\lab_server\client; .\tassan-tunnel.ps1 -User "you@ge.polymtl.ca"`
3. **Check** in a second terminal (optional, but it saves guessing):
   - macOS / Linux: `tassan-check`
   - Windows: `.\check-tassan.ps1`

   Expected: `Server answers, model: qwen3.6-27b`, then `Tool call OK in N s`.
4. **Start an agent in your project:**
   ```bash
   cd ~/path/to/your/repo
   claude-lab              # or: opencode-lab
   ```
   Windows: `& "<...>\lab_server\client\claude-tassan.ps1"` (or `opencode-tassan.ps1`) from your project folder.

   It prints `Claude Code -> tassan (qwen3.6-27b)` and opens the agent. On the very first start, Claude Code asks a few setup questions (theme, whether you trust the folder): answer them once.
5. **Give it a task** in plain language, for example:
   > There's a bug in `apply_model.py`: with 3-class models the axonmyelin mask is never written. Find the cause, fix it, and run the tests in `test/test_apply_model.py`.

   The agent asks your permission before editing files or running commands; accept or refuse each time (in Claude Code, you can also allow a command for the rest of the session).
6. **When you're done:** quit the agent (`/exit` in Claude Code, Ctrl+C twice also works), then close the tunnel (Ctrl+C in its terminal).

The launchers only change settings for that one session. Plain `claude` or `opencode` elsewhere keeps your usual setup (for example your own Anthropic account).

## Which agent?

Both did well on our tests with this model:

- **Claude Code** keeps your repo clean and was a bit faster.
- **OpenCode** is fully open source and followed instructions a bit more literally. With weaker models it tended to leave scratch scripts behind, so check `git status` before committing.

## Setting it up by hand (IDE, other tools)

The launchers just set a few variables before starting the agent. If you'd rather configure things yourself (for example Claude Code inside VS Code), here is what they do. The tunnel must be open.

**Claude Code** reads these environment variables:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8001
ANTHROPIC_AUTH_TOKEN=<the lab key>
ANTHROPIC_MODEL=qwen3.6-27b                 # also set ANTHROPIC_DEFAULT_OPUS_MODEL, _SONNET_MODEL, _HAIKU_MODEL
CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072       # the server's context size
CLAUDE_CODE_AUTO_COMPACT_WINDOW=131072
CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

Unset `ANTHROPIC_API_KEY` if you have one. The three `CLAUDE_CODE_*_TOKENS` lines matter: without them Claude Code doesn't know the server's limit, and long tasks fail with `400 ... maximum context length`.

**OpenCode** uses the config file `lab_server/client/opencode.json` (the lab server as a provider named `tassan`, with its context limits). Point OpenCode to it and pick the model:

```bash
export OPENCODE_CONFIG=~/benchmark-local-llm/lab_server/client/opencode.json
export TASSAN_VLLM_KEY=$(cat ~/.tassan_vllm_key)
opencode --model tassan/qwen3.6-27b
```

You can also copy the `tassan` provider block from that file into your own OpenCode config.

**Which model name?** The server says which model it runs: `curl -s -H "Authorization: Bearer $(cat ~/.tassan_vllm_key)" http://127.0.0.1:8001/v1/models`. The launchers do this for you; by hand, use that name.

## Using the model from your own code (no agent)

The server speaks the OpenAI API, so any OpenAI-compatible client works. You need the VPN, the key file and the tunnel (the scripts above, or by hand: `ssh -N -L 8001:127.0.0.1:8000 you@ge.polymtl.ca@tassan.neuro.polymtl.ca`).

With curl:

```bash
curl http://127.0.0.1:8001/v1/chat/completions \
  -H "Authorization: Bearer $(cat ~/.tassan_vllm_key)" -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-27b", "messages": [{"role": "user", "content": "Explain numpy broadcasting in 3 lines."}],
       "max_tokens": 2000}'
```

In Python (`pip install openai`):

```python
from pathlib import Path
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8001/v1",
                api_key=Path.home().joinpath(".tassan_vllm_key").read_text().strip())
model = client.models.list().data[0].id          # the model the server runs right now

r = client.chat.completions.create(
    model=model,
    messages=[{"role": "user", "content": "Write a function that checks if a string is a palindrome."}],
    max_tokens=4000,
)
print(r.choices[0].message.content)
```

- **Thinking:** by default the model reasons first (the reasoning comes back separately, in `message.reasoning`) and only then answers. For quick or simple requests, turn it off: much faster, fewer tokens.
  - Python: add `extra_body={"chat_template_kwargs": {"enable_thinking": False}}`
  - curl: add `"chat_template_kwargs": {"enable_thinking": false}` to the JSON
- **`max_tokens`:** leave room for the reasoning (a few thousand) when thinking is on, or the answer can be cut off before it starts.
- **Streaming:** pass `stream=True` and print `chunk.choices[0].delta.content` as it arrives.
- **Batch jobs** (hundreds of requests): send them a few at a time (4 to 8 in parallel), not all at once, so others keep a usable server.

## Good practices

- **Work on a branch and read the diff** before committing. The model is good, not infallible: it can claim something works when it doesn't, or quietly change behavior.
- **Run `git status`** at the end: agents sometimes create helper files you don't want to commit.
- **Give it the whole task in one message**, with the files involved and how to check the result (for example "the tests in test/morphometrics must pass"). It works through it on its own.
- **Be patient:** it reads your files and thinks before acting. Several minutes on a real task is normal.
- **Use a clone, not your only copy,** for big refactors.

## Sharing the GPU

- Several people can use it at the same time. In our tests, with 8 simultaneous users, each one kept about 90% of their writing speed and the first word arrived within 2 seconds. With 3 agents working on real tasks at once, each task took about twice as long as alone (up to 5x for one of them), with the same quality of result.
- A longer wait than usual before the first word usually means others are using it, not that it's broken.
- The server runs on GPU 1 only. Don't start your own jobs on that card while the server is up; it reserves most of its memory.

## Troubleshooting

| What you see | What it means | What to do |
|---|---|---|
| `No answer on http://127.0.0.1:8001` | the tunnel is closed, the VPN is off, or the server is stopped | check the VPN, reopen the tunnel; if it still fails, tell Youssef |
| `No lab key` | the key file is missing on your laptop | redo setup step 2 (the file is `~/.tassan_vllm_key` on your laptop, not on tassan) |
| `401 Unauthorized` | the key is wrong (extra space, quotes, old key) | redo setup step 2 with the exact key |
| The tunnel asks for a password and refuses it | wrong tassan login, or the VPN is off | use your tassan login (`you@ge.polymtl.ca`) and its password |
| The tunnel says `Address already in use` | a tunnel is already open (maybe in another window) | use that one, or close it first |
| `permission denied` when running a `.sh` script | the script lost its executable bit | `chmod +x ~/benchmark-local-llm/lab_server/client/*.sh` |
| Claude Code asks you to log in | it was started as plain `claude`, not with the launcher | use `claude-lab` (or `claude-tassan.sh`) |
| `400 ... maximum context length` | the agent was started without the lab launcher or settings | use the launcher, or the variables in "Setting it up by hand" |
| The agent answers in text but never edits files | the model didn't make a tool call | run `tassan-check`; if it shows no tool call, tell Youssef |
| Very slow, even for short answers | many people are using it, or a long task is running | wait, or try again later |
