# Shared by the macOS/Linux client scripts (claude-tassan.sh, opencode-tassan.sh, check-tassan.sh,
# tassan-tunnel.sh). Sets base, token, model and window for the backend chosen with TASSAN_BACKEND
# (vllm by default).
#   login: TASSAN_USER, else ~/.tassan/config (written by install-mac.sh)
#   key:   TASSAN_VLLM_KEY, else the file ~/.tassan_vllm_key
#   model: TASSAN_MODEL, else whatever the server serves (so a model change on tassan needs no client change)
# If nothing listens on the local port, it opens the SSH tunnel in the background; the last script
# using that tunnel closes it when it exits. A tunnel opened by hand (tassan-tunnel.sh) is left alone.
# With TASSAN_LIB_NO_CONNECT=1 it only loads the settings and functions (tassan-tunnel.sh does that).
# Written for the bash 3.2 that ships with macOS.

[ -r "$HOME/.tassan/config" ] && . "$HOME/.tassan/config"
TASSAN_HOST=${TASSAN_HOST:-tassan.neuro.polymtl.ca}
run_dir=$HOME/.tassan/run
ctl=$run_dir/tunnel.sock   # control socket of the background tunnel (ssh -M)
mcp_port=8002              # web search MCP, same port both sides (SEARCH_MCP_PORT in lab_server/cluster/vllm.env)

tassan_tunnel_alive() { [ -e "$ctl" ] && ssh -S "$ctl" -O check "$TASSAN_HOST" 2>/dev/null; }

tassan_tunnel_close() {
    if tassan_tunnel_alive; then ssh -S "$ctl" -O exit "$TASSAN_HOST" 2>/dev/null || true; fi
    rm -f "$ctl"
}

tassan_tunnel_open() {
    [ -n "${TASSAN_USER:-}" ] || {
        echo "No tassan login: run install-mac.sh again, or put  TASSAN_USER=you@ge.polymtl.ca  in ~/.tassan/config"; exit 1; }
    python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1])' "$TASSAN_HOST" 2>/dev/null \
        || { echo "Cannot reach $TASSAN_HOST: is the Polytechnique VPN connected?"; exit 1; }
    mkdir -p "$run_dir"; chmod 700 "$HOME/.tassan" "$run_dir"
    tassan_tunnel_close   # a socket left by a crash would make ssh -M refuse to start
    echo "Opening the tunnel to tassan..."
    # -f returns once the forwards are up (ExitOnForwardFailure), after any password prompt
    ssh -f -N -M -S "$ctl" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ConnectTimeout=15 \
        -l "$TASSAN_USER" -L 8001:127.0.0.1:8000 -L 11435:127.0.0.1:11434 -L "$mcp_port:127.0.0.1:8002" "$TASSAN_HOST" \
        || { echo "The tunnel did not open. Wrong tassan login or password? (login: $TASSAN_USER)"; exit 1; }
}

# Web search for the agents: the lab-search MCP server on tassan, through the tunnel. Writes a Claude Code
# --mcp-config file with the lab key and prints its path, or prints nothing if the search doesn't answer
# (off on tassan, or a tunnel opened by hand without the port): the agent then just has no web search.
tassan_mcp_config() {
    local code f=$run_dir/mcp.json
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:$mcp_port/mcp" 2>/dev/null || true)
    if [ "$code" != 401 ]; then
        echo "Note: no web search this session (nothing answers on 127.0.0.1:$mcp_port: tunnel opened by hand without it, or search off on tassan)." >&2
        return 0
    fi
    mkdir -p "$run_dir"
    (umask 077; printf '{"mcpServers": {"lab-search": {"type": "http", "url": "http://127.0.0.1:%s/mcp", "headers": {"Authorization": "Bearer %s"}}}}\n' \
        "$mcp_port" "$token" > "$f")
    printf '%s' "$f"
}

# Several scripts can share one background tunnel: each registers its pid, the last one out closes it.
tassan_session_start() {
    mkdir -p "$run_dir"
    : > "$run_dir/session.$$"
    trap tassan_session_end EXIT
}

tassan_session_end() {
    rm -f "$run_dir/session.$$"
    local f
    for f in "$run_dir"/session.*; do
        [ -e "$f" ] || continue
        if kill -0 "${f##*.}" 2>/dev/null; then return 0; fi   # another session still uses the tunnel
        rm -f "$f"                                              # left by a session that crashed
    done
    if [ -e "$ctl" ]; then tassan_tunnel_close; echo "Tunnel to tassan closed."; fi
    return 0
}

[ "${TASSAN_LIB_NO_CONNECT:-}" = 1 ] && return 0

if [ "${TASSAN_BACKEND:-vllm}" = ollama ]; then
    base=http://127.0.0.1:11435; token=ollama; window=65536
else
    base=http://127.0.0.1:8001; window=131072   # = MAX_MODEL_LEN in lab_server/cluster/vllm.env
    token=${TASSAN_VLLM_KEY:-$(cat "$HOME/.tassan_vllm_key" 2>/dev/null || true)}
    [ -n "$token" ] || { echo "No lab key: run install-mac.sh again, or save it with  (umask 077; printf '%s' '<key>' > ~/.tassan_vllm_key)"; exit 1; }
fi

tassan_session_start
# nothing listens on the local port = no tunnel yet (a TCP connect, not curl's exit code, which varies by OS)
port_listening() { python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()' "${base##*:}" 2>/dev/null; }
port_listening || tassan_tunnel_open
tassan_models() { curl -s --max-time 10 -w '\n%{http_code}' -H "Authorization: Bearer $token" "$base/v1/models"; }
rc=0; resp=$(tassan_models) || rc=$?
[ "$rc" = 0 ] || { echo "The tunnel is open but the server on tassan does not answer (stopped or restarting?). Tell Youssef if it lasts."; exit 1; }
code=$(printf '%s\n' "$resp" | tail -n 1); models=$(printf '%s\n' "$resp" | sed '$d')
case $code in
    200) ;;
    401|403) echo "The server refused the lab key: check ~/.tassan_vllm_key (the exact key, no spaces or quotes)."; exit 1 ;;
    *) echo "Unexpected answer from the server (HTTP $code). Tell Youssef if it lasts."; exit 1 ;;
esac
model=${TASSAN_MODEL:-$(printf '%s' "$models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')}
