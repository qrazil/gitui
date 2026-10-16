#!/usr/bin/env bash
# `1git` over ssh beside the real `git`, against a disposable OpenSSH sshd
# (ephemeral port, throwaway host and user keys, throwaway $HOME; the real
# ~/.ssh is never touched). The server runs the system git-upload-pack and
# git-receive-pack. known_hosts is strict on both sides: the host key is
# pre-trusted in a file of this script's making.
#
#   bash scripts/compare_net_ssh.sh <1git-binary> [workdir]
set -uo pipefail
OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
exec 2> >(grep -v 'templates not found' >&2)
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
for t in "$SSHD" ssh-keygen ssh git python3; do
    command -v "$t" > /dev/null 2>&1 || [ -x "$t" ] || { echo "SKIP compare_net_ssh: $t missing"; exit 0; }
done
export LC_ALL=C TZ=UTC GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@e.x GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@e.x
export GIT_AUTHOR_DATE="1800000000 +0000" GIT_COMMITTER_DATE="1800000000 +0000"
HOMEDIR=$WORK/home; mkdir -p "$HOMEDIR/.ssh" "$WORK/srv"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/user_key"
cp "$WORK/user_key.pub" "$WORK/authorized_keys"; chmod 600 "$WORK/user_key" "$WORK/host_key"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
USERNAME=$(id -un)
cat > "$WORK/sshd_config" << EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/host_key
AuthorizedKeysFile $WORK/authorized_keys
PidFile $WORK/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowUsers $USERNAME
SetEnv PATH=/usr/libexec/git-core:/usr/bin:/bin
EOF
"$SSHD" -f "$WORK/sshd_config" -e 2> "$WORK/sshd.log" &
SSHD_PID=$!
trap 'kill $SSHD_PID 2>/dev/null' EXIT
for i in $(seq 50); do (echo > /dev/tcp/127.0.0.1/$PORT) 2> /dev/null && break; sleep 0.1; done
cat > "$HOMEDIR/.ssh/config" << EOF
Host srv
  HostName 127.0.0.1
  Port $PORT
  User $USERNAME
  IdentityFile $WORK/user_key
EOF
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$WORK/host_key.pub")" > "$HOMEDIR/.ssh/known_hosts"
export M31GIT_SSH_KNOWN_HOSTS=$HOMEDIR/.ssh/known_hosts
GIT_SSH_COMMAND="ssh -F $HOMEDIR/.ssh/config -o UserKnownHostsFile=$HOMEDIR/.ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes"

bad=0; n=0
mk_remote() {
    rm -rf "$WORK/srv/r.git" "$WORK/seed"
    git init -q -b main "$WORK/seed"
    (cd "$WORK/seed" && mkdir -p .git/hooks && for i in 1 2 3; do echo "l$i" >> f; git add f; git commit -qm "c$i"; done; git tag v1; git checkout -q -b feature; echo x > g; git add g; git commit -qm f1; git checkout -q main)
    git clone -q --bare "$WORK/seed" "$WORK/srv/r.git"
}
run() { # <label> <script using G and $URL>
    n=$((n + 1))
    local out=()
    for side in git ours; do
        mk_remote
        rm -rf "$WORK/side-$side"; mkdir "$WORK/side-$side"
        (
            cd "$WORK/side-$side"
            URL=${URL_FORM:-srv:$WORK/srv/r.git}
            if [ "$side" = git ]; then
                G() { GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git "$@"; }
            else
                G() { HOME=$HOMEDIR "$OURS" "$@"; }
            fi
            : > "$WORK/log-$side"
            eval "$2" >> "$WORK/log-$side" 2>&1
            { echo "## refs"; for d in w .; do [ -d "$d/.git" ] && (cd "$d"; git for-each-ref); done
              echo "## remote"; git -C "$WORK/srv/r.git" for-each-ref; git -C "$WORK/srv/r.git" fsck 2>&1 | head -3
              [ -d w/.git ] && (cd w; echo "## tree"; git ls-files -s; echo "## fsck"; git fsck --strict 2>&1 | head -3; git config --local --list | sort); } >> "$WORK/log-$side" 2>&1
        )
        sed -i.bak "/templates not found/d; s|$WORK|W|g; s|$PORT|PORT|g" "$WORK/log-$side"; rm -f "$WORK/log-$side.bak"
    done
    if cmp -s "$WORK/log-git" "$WORK/log-ours"; then :; else
        bad=$((bad + 1)); printf '\033[31mdiffer\033[0m %s\n' "$1"; diff "$WORK/log-git" "$WORK/log-ours" | head -12 | sed 's/^/       /'
    fi
}
run "ssh: ls-remote scp-like" 'G ls-remote "$URL"'
run "ssh: ls-remote ssh:// URL" 'G ls-remote "ssh://srv$WORK/srv/r.git"'
run "ssh: clone" 'G clone -q "$URL" w; cd w; git log --oneline | cat'
run "ssh: clone --depth 1" 'G clone -q --depth 1 "$URL" w; cat w/.git/shallow'
run "ssh: fetch" 'git clone -q "$WORK/srv/r.git" w; cd w; git remote set-url origin "$URL"; (cd "$WORK/seed"; echo m >> f; git commit -qam m; git push -q "$WORK/srv/r.git" main); G fetch origin; G fetch origin'
run "ssh: push new branch and fast-forward" 'git clone -q "$WORK/srv/r.git" w; cd w; git remote set-url origin "$URL"; git checkout -q -b topic; echo t > t; git add t; git commit -qm t; G push -u origin topic; echo u >> t; git commit -qam u; G push; G push'
run "ssh: push rejected and delete" 'git clone -q "$WORK/srv/r.git" w; cd w; git remote set-url origin "$URL"; git checkout -q main; echo z >> f; git commit -qam z; git -C "$WORK/srv/r.git" update-ref refs/heads/main refs/heads/feature; G push origin main; G push origin --delete feature'
run "ssh: pull" 'git clone -q "$WORK/srv/r.git" w; cd w; git remote set-url origin "$URL"; git -C "$WORK/srv/r.git" update-ref refs/heads/main refs/heads/feature; G pull'
echo
if [ "$bad" -eq 0 ]; then echo "compare_net_ssh: $n cases, all agree with git"; else echo "compare_net_ssh: $bad of $n differ"; fi
exit "$bad"
