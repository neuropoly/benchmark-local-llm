#!/usr/bin/env bash
# One-time setup of the lab coding assistant (tassan) on a Mac. Safe to run again: it keeps what is
# already set up and redoes what is missing.
#   curl -fsSL https://raw.githubusercontent.com/yolaatar/benchmark-local-llm/main/lab_server/client/install-mac.sh | bash
# or from a clone:  bash lab_server/client/install-mac.sh
# Does: the scripts in ~/benchmark-local-llm, your tassan login and the lab key, Claude Code (OpenCode
# on request), an SSH key so the tunnel needs no password, the claude-lab / opencode-lab shortcuts,
# and a final check. Needs no admin rights. Written for the bash 3.2 that ships with macOS.
set -euo pipefail

REPO_URL=https://github.com/yolaatar/benchmark-local-llm.git
DEST=${TASSAN_REPO_DIR:-$HOME/benchmark-local-llm}
CLIENT=$DEST/lab_server/client
CONF_DIR=$HOME/.tassan; CONF=$CONF_DIR/config
KEY_FILE=$HOME/.tassan_vllm_key
SSH_KEY=$HOME/.ssh/id_ed25519
export PATH="$HOME/.local/bin:$PATH"   # where the Claude Code installer puts claude

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
# Piped through curl, stdin is this script: questions are read from the terminal.
ask() { local answer; read -r -p "$1" answer </dev/tty; printf '%s' "$answer"; }
ask_secret() { local answer; read -r -s -p "$1" answer </dev/tty; echo >/dev/tty; printf '%s' "$answer"; }
vpn_up() { python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1])' "$TASSAN_HOST" 2>/dev/null; }
# -n: never read stdin, which is the rest of this script when it comes through curl | bash
ssh_ok() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 -l "$TASSAN_USER" "$TASSAN_HOST" true 2>/dev/null; }

# All in a function so bash reads the whole file before running any of it (curl | bash safety).
main() {
[ "$(uname)" = Darwin ] || { echo "This installer is for macOS (on Windows, see lab_server/USER_GUIDE.md)."; exit 1; }
[ -r "$CONF" ] && . "$CONF"
TASSAN_HOST=${TASSAN_HOST:-tassan.neuro.polymtl.ca}

step "1/6 git and python3"
# Any working git and python3 will do (Homebrew's too). On a fresh Mac, /usr/bin/git and /usr/bin/python3
# are only stubs for Apple's Command Line Tools: then ask macOS to install those (no full Xcode).
if git --version >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
    echo "git and python3 are there."
else
    xcode-select --install 2>/dev/null || true
    echo "git or python3 is missing: macOS is installing its Command Line Tools in a separate window"
    echo "(git and python3, not the full Xcode). When it is done, run this installer again."
    exit 1
fi

step "2/6 Lab scripts"
if [ -d "$DEST/.git" ]; then
    git -C "$DEST" pull --ff-only -q || echo "Could not update $DEST (local changes?), keeping it as it is."
    echo "Updated in $DEST"
else
    git clone -q "$REPO_URL" "$DEST"
    echo "Downloaded to $DEST"
fi
chmod +x "$CLIENT"/*.sh

step "3/6 Your tassan login and the lab key"
login=${TASSAN_USER:-}
if [ -n "$login" ]; then
    answer=$(ask "tassan login [$login] (Enter to keep): ")
    [ -n "$answer" ] && login=$answer
fi
while [ -z "$login" ]; do
    login=$(ask "tassan login (the one for training jobs, e.g. you@ge.polymtl.ca): ")
done
case $login in *@*) ;; *) echo "Note: tassan logins usually look like you@ge.polymtl.ca." ;; esac
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
# ':=' so an environment variable still wins over the file
printf ': "${TASSAN_USER:=%s}"\n: "${TASSAN_HOST:=%s}"\n' "$login" "$TASSAN_HOST" > "$CONF"
TASSAN_USER=$login

if [ -s "$KEY_FILE" ]; then
    echo "Lab key already saved in $KEY_FILE."
else
    key=""
    while [ -z "$key" ]; do key=$(ask_secret "Lab key (paste it, nothing shows while you type): "); done
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    case $key in lab-*) ;; *) echo "Note: the lab key usually starts with 'lab-'. Saved anyway; the final check will tell." ;; esac
    (umask 077; printf '%s' "$key" > "$KEY_FILE")
    echo "Saved in $KEY_FILE (only you can read it)."
fi

step "4/6 Coding agent"
if command -v claude >/dev/null; then
    echo "Claude Code is there ($(claude --version 2>/dev/null | head -1))."
else
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    command -v claude >/dev/null || { echo "Claude Code did not install. Try again later or see https://claude.com/claude-code"; exit 1; }
fi
if command -v opencode >/dev/null; then
    echo "OpenCode is there too."
elif command -v brew >/dev/null; then
    answer=$(ask "Also install OpenCode, the open-source agent? [y/N] ")
    case $answer in [yY]*) brew install opencode </dev/null ;; *) echo "Skipped (run 'brew install opencode' any time)." ;; esac
fi

step "5/6 Tunnel without a password"
if ! vpn_up; then
    echo "Cannot reach $TASSAN_HOST: the VPN looks off. Connect it and run this installer again for this step"
    echo "(everything else is done; without it the tunnel just asks for your tassan password)."
elif ssh_ok; then
    echo "Already set: tassan lets you in without a password."
else
    [ -f "$SSH_KEY" ] || { mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; ssh-keygen -q -t ed25519 -N '' -C "tassan-lab $(whoami)" -f "$SSH_KEY" </dev/null; }
    echo "Copying your SSH key to tassan: type your tassan password one last time."
    ssh-copy-id -i "$SSH_KEY.pub" "$TASSAN_USER@$TASSAN_HOST" </dev/tty || true
    if ssh_ok; then
        echo "Done: no more password for the tunnel."
    else
        echo "tassan still asks for a password. Not a blocker: the tunnel will just ask for it."
    fi
fi

step "6/6 Shortcuts and final check"
rc_file=$HOME/.zshrc; case ${SHELL:-} in */bash) rc_file=$HOME/.bash_profile ;; esac
begin='# >>> tassan lab assistant (install-mac.sh) >>>'; end='# <<< tassan lab assistant <<<'
touch "$rc_file"
awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$rc_file" > "$rc_file.tassan.tmp"
{
    cat "$rc_file.tassan.tmp"
    echo "$begin"
    echo "alias claude-lab='\"$CLIENT/claude-tassan.sh\"'"
    echo "alias opencode-lab='\"$CLIENT/opencode-tassan.sh\"'"
    echo "alias tassan-check='\"$CLIENT/check-tassan.sh\"'"
    echo "alias tassan-tunnel='\"$CLIENT/tassan-tunnel.sh\"'"
    echo "$end"
} > "$rc_file"
rm -f "$rc_file.tassan.tmp"
echo "Shortcuts added to $rc_file."

if vpn_up; then
    "$CLIENT/check-tassan.sh" || echo "The check failed: see the message above, then run  tassan-check  again."
else
    echo "Skipping the check: connect the VPN, then run  tassan-check."
fi

step "All set"
echo "Open a new terminal, go to a project folder and type:  claude-lab   (or opencode-lab)"
echo "It opens the tunnel by itself (VPN on) and closes it when you quit."
}

main "$@"
