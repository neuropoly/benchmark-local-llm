#!/usr/bin/env bash
# SSH tunnel to the lab servers on tassan (macOS/Linux version of tassan-tunnel.ps1).
#   vLLM   tassan 127.0.0.1:8000  -> here 127.0.0.1:8001
#   Ollama tassan 127.0.0.1:11434 -> here 127.0.0.1:11435
# The launchers (claude-tassan.sh, opencode-tassan.sh) open and close it by themselves, so this is only
# for doing it by hand, e.g. for your own scripts:
#   ./tassan-tunnel.sh           open it in this terminal, Ctrl+C to close
#   ./tassan-tunnel.sh status    is a tunnel open, and which kind
#   ./tassan-tunnel.sh stop      close the background tunnel the launchers opened
# Login: TASSAN_USER, else ~/.tassan/config (written by install-mac.sh).
set -euo pipefail
TASSAN_LIB_NO_CONNECT=1
source "$(dirname "$0")/tassan_lib.sh"

port_open() { python3 -c 'import socket; socket.create_connection(("127.0.0.1", 8001), 2).close()' 2>/dev/null; }

case ${1:-open} in
    status)
        if tassan_tunnel_alive; then echo "Background tunnel open (opened by a launcher)."
        elif port_open; then echo "Something listens on 127.0.0.1:8001: a tunnel opened by hand, probably."
        else echo "No tunnel open."; fi ;;
    stop)
        if tassan_tunnel_alive; then tassan_tunnel_close; rm -f "$run_dir"/session.*; echo "Background tunnel closed."
        else rm -f "$ctl"; echo "No background tunnel to close (a tunnel opened by hand closes with Ctrl+C in its terminal)."; fi ;;
    open)
        USER_AT=${TASSAN_USER:?no tassan login: run install-mac.sh, or set TASSAN_USER=you@ge.polymtl.ca}
        echo "Tunnel to $TASSAN_HOST open (vLLM on 127.0.0.1:8001, Ollama on 127.0.0.1:11435). Ctrl+C to close."
        exec ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -l "$USER_AT" \
            -L 8001:127.0.0.1:8000 -L 11435:127.0.0.1:11434 "$TASSAN_HOST" ;;
    *) echo "Usage: $0 [open|status|stop]"; exit 1 ;;
esac
