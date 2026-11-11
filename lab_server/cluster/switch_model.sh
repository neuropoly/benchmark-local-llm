#!/usr/bin/env bash
# Switch the model the lab vLLM server runs, among the ones listed in models.conf.
#   bash switch_model.sh                  list them: which one is set, which one runs, which are downloaded
#   bash switch_model.sh <name>           download it if needed, then restart vLLM on it
#   bash switch_model.sh default          back to the MODEL in vllm.env
#   add --no-start to only record the choice (the next serve_vllm.sh uses it)
# The choice is written to ~/llm-bench/model.env, outside lab_server/, so redeploying the scripts keeps
# it. Run it from your tmux like serve_vllm.sh: it waits until the new model answers.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vllm.env"
CHOICE=$LLMBENCH/model.env
KEY=$LLMBENCH/vllm.key

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

# One "name|repo|parser|extra|note" line per model of models.conf, blanks trimmed, comments skipped.
models() {
    local name repo parser extra note
    while IFS='|' read -r name repo parser extra note; do
        name=$(trim "$name")
        case $name in ''|'#'*) continue ;; esac
        printf '%s|%s|%s|%s|%s\n' "$name" "$(trim "$repo")" "$(trim "$parser")" "$(trim "${extra:-}")" "$(trim "${note:-}")"
    done < "$HERE/models.conf"
}

downloaded() { [ -d "$HF_HOME/hub/models--${1//\//--}/snapshots" ]; }
running() { tmux has-session -t vllm 2>/dev/null; }
# The model the running server actually answers with (empty if it is down or still starting).
served_now() {
    [ -s "$KEY" ] || return 0
    curl -sf --max-time 5 -H "Authorization: Bearer $(cat "$KEY")" "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || true
}

list() {
    local now name repo parser extra note mark state
    now=$(served_now)
    echo "Models (> set for the server, * running now):"
    while IFS='|' read -r name repo parser extra note; do
        mark=' '; [ "$name" = "$SERVED_NAME" ] && mark='>'
        [ "$name" = "$now" ] && mark="${mark/ /}*"
        state='not downloaded yet'; downloaded "$repo" && state='downloaded'
        printf ' %-2s %-17s %-32s %s\n      %s\n' "$mark" "$name" "$repo" "($state)" "$note"
    done < <(models)
    echo
    if [ -e "$CHOICE" ]; then echo "Set with switch_model.sh ($CHOICE). Back to vllm.env's model: bash $0 default"
    else echo "No switch made: this is the model in vllm.env."; fi
    if [ -n "$now" ]; then echo "vLLM is up, serving $now."
    elif running; then echo "vLLM is starting (or stuck): tail -f $LLMBENCH/logs/vllm.log"
    else echo "vLLM is stopped."; fi
}

restart() {
    if running; then bash "$HERE/stop_vllm.sh"; fi
    bash "$HERE/serve_vllm.sh"
}

want=${1:-list}; no_start=0
[ "${2:-}" = --no-start ] && no_start=1
[ "$want" = --no-start ] && { want=${2:-list}; no_start=1; }
# What to offer as "go back" if the new model fails: the one running now, else the one set.
now=$(served_now)
previous=${now:-$SERVED_NAME}

case $want in
    list|-h|--help) list; exit 0 ;;
    default)
        rm -f "$CHOICE"
        source "$HERE/vllm.env"
        echo "Back to vllm.env's model: $SERVED_NAME ($MODEL)." ;;
    *)
        line=$(models | awk -F'|' -v w="$want" '$1 == w') || true
        [ -n "$line" ] || { echo "Unknown model '$want'."; echo; list; exit 1; }
        IFS='|' read -r name repo parser extra note <<< "$line"
        if [ "$name" != "$now" ] || [ "$name" != "$SERVED_NAME" ]; then
            # Download first: if it fails, the current setting is left as it was.
            [ -x "$LLMBENCH/vllm-venv/bin/hf" ] || { echo "vLLM is not installed: run setup_vllm.sh first"; exit 1; }
            downloaded "$repo" || echo "Downloading $repo into $HF_HOME (first time: can take a while)..."
            "$LLMBENCH/vllm-venv/bin/hf" download "$repo" >/dev/null
            {
                echo "# Written by switch_model.sh on $(date '+%Y-%m-%d %H:%M'). Delete this file to go back to vllm.env's model."
                printf 'MODEL=%q\nSERVED_NAME=%q\nTOOL_PARSER=%q\nEXTRA_ARGS=%q\n' "$repo" "$name" "$parser" "$extra"
            } > "$CHOICE"
            source "$HERE/vllm.env"
            echo "Set: $SERVED_NAME ($MODEL). $note"
        fi ;;
esac

if [ -n "$now" ] && [ "$now" = "$SERVED_NAME" ]; then
    echo "vLLM already serves $now. Nothing to restart."; exit 0
fi

if [ "$no_start" = 1 ]; then
    if running; then echo "Not restarted (--no-start): vLLM keeps serving the old model until: bash $HERE/stop_vllm.sh && bash $HERE/serve_vllm.sh"
    else echo "Not started (--no-start): bash $HERE/serve_vllm.sh starts it."; fi
    exit 0
fi

if restart; then
    echo "Done. Clients need nothing for Claude Code; OpenCode needs '$SERVED_NAME' in client/opencode.json."
else
    echo "The new model did not start, and vLLM is stopped now. To go back to $previous: bash $0 $previous"
    exit 1
fi
