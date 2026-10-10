# `GIT_remote.m31`: where a remote lives and how to reach it. Every claim is
# judged by a tool that is not this program:
#
#   1. URL parsing and the remote command: real `git ls-remote <url>` run
#      with a recording `GIT_SSH_COMMAND` that logs the argv git would have
#      handed to ssh (destination, `-p`, and the quoted `git-upload-pack
#      '<path>'`) and exits 1. Our `exec` output must be that argv. URLs git
#      refuses (a host or path that looks like an option) must be refused
#      here too; URLs git passes on that this module rejects on purpose are
#      listed apart and asserted as rejected.
#   2. insteadOf / pushInsteadOf: `git ls-remote --get-url` and
#      `git remote get-url [--push]` over a fixture repository's own config.
#   3. ssh_config: `ssh -G -F <file> <host>` for the configured values.
#   4. known_hosts: `ssh-keygen -F <host> -f <file>` over a file of plain,
#      port, wildcard, negated, revoked and cert-authority lines, and again
#      after `ssh-keygen -H` hashed it (line numbers, markers, types, keys).
#   5. HMAC-SHA1: Python's `hmac`.
#
# The unit checks (`t_remote unit`) are counted too. Git is told to read no
# user or system config, so nothing of the machine's leaks in. Sourced from
# `test.sh`, sharing its shell, `$WORK`, `build`, `note`/`bad`; starts no
# process that outlives it.

rm_root="$WORK/remote"
mkdir -p "$rm_root"

if build t_remote; then
    rm_t="$WORK/t_remote"

    # --- unit checks ------------------------------------------------------
    "$rm_t" unit >"$rm_root/unit.out" 2>&1
    rm_ok=0
    rm_bad=0
    while IFS= read -r rm_line; do
        case "$rm_line" in
            "ok "*) note "${rm_line#ok }"; rm_ok=$((rm_ok + 1)) ;;
            "FAIL "*) bad "${rm_line#FAIL }"; rm_bad=$((rm_bad + 1)) ;;
        esac
    done <"$rm_root/unit.out"
    if [ "$rm_ok" -lt 30 ] || [ "$rm_bad" -ne 0 ]; then
        bad "remote unit: expected at least 30 passes and no failures" "ok=$rm_ok bad=$rm_bad" "$(tail -3 "$rm_root/unit.out")"
    fi

    # --- 1. URLs against git's own argv for ssh ------------------------------
    rm_rec="$rm_root/rec.sh"
    cat >"$rm_rec" <<'RECEOF'
#!/bin/sh
for a in "$@"; do printf '[%s]' "$a"; done >>"$REC_OUT"; echo >>"$REC_OUT"
exit 1
RECEOF
    chmod +x "$rm_rec"

    # What git hands to ssh for $1, as "dest=.. port=.. cmd=..", or "none".
    rm_git_argv() {
        REC_OUT="$rm_root/rec.out" GIT_SSH_COMMAND="$rm_rec" GIT_SSH_VARIANT=ssh \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
            git ls-remote "$1" >/dev/null 2>&1
        if [ ! -s "$rm_root/rec.out" ]; then
            echo none
        else
            python3 - "$rm_root/rec.out" <<'PYEOF'
import re, sys
line = open(sys.argv[1]).read().splitlines()[0]
argv = re.findall(r'\[(.*?)\](?=\[|$)', line)
port = "0"
rest = []
i = 0
while i < len(argv):
    if argv[i] == "-o":
        i += 2
    elif argv[i] == "-p":
        port = argv[i + 1]
        i += 2
    else:
        rest.append(argv[i])
        i += 1
print("dest=%s port=%s cmd=%s" % (rest[0], port, rest[1]))
PYEOF
        fi
        rm -f "$rm_root/rec.out"
    }

    rm_agree=(
        'ssh://host/path'
        'ssh://u@host:2222/a/b'
        'ssh://host/~user/x'
        'ssh://host/a%20b'
        'ssh://host/a%2Fb'
        'ssh://ho%73t/p'
        'ssh://[::1]:2222/p'
        'ssh://u@[::1]/p'
        'ssh://host:22/p'
        'ssh://host/-x'
        'ssh://host/it'"'"'s!'
        'git+ssh://host/r'
        'ssh+git://u@host/r'
        'host:rel/path'
        'u@host:/abs'
        'u@host:dir/it'"'"'s'
        '[::1]:p'
        'u@[::1]:p'
        '[h:22]:p'
        'u@[h:2200]:rel/p'
        'host:'"'"'q'"'"'/p'
        'host:/a%20b'
        'user@host.example.com:team/repo.git'
    )
    rm_both_refuse=(
        'ssh://-host/p'
        'ssh://-oProxyCommand=touch/p'
        'host:-x'
        '-host:p'
        'ssh://host'
    )
    rm_stricter=(
        'ssh://u:pw@host/p'
        'ssh://host:99999/p'
        'ssh://host:abc/p'
    )

    rm_n_agree=0
    for rm_url in "${rm_agree[@]}"; do
        rm_theirs=$(rm_git_argv "$rm_url")
        rm_ours=$("$rm_t" exec "$rm_url" upload 2>&1)
        if [ "$rm_ours" = "$rm_theirs" ] && [ "$rm_theirs" != none ]; then
            note "remote url: $rm_url -> ssh argv as git ($rm_theirs)"
            rm_n_agree=$((rm_n_agree + 1))
        else
            bad "remote url: $rm_url" "git:  $rm_theirs" "ours: $rm_ours"
        fi
    done
    for rm_url in "${rm_both_refuse[@]}"; do
        rm_theirs=$(rm_git_argv "$rm_url")
        rm_ours=$("$rm_t" exec "$rm_url" upload 2>&1)
        case "$rm_ours" in
            "error "*) rm_refuses=1 ;;
            *) rm_refuses=0 ;;
        esac
        if [ "$rm_theirs" = none ] && [ "$rm_refuses" = 1 ]; then
            note "remote url: $rm_url is refused by git and here (${rm_ours#error })"
        else
            bad "remote url refusal: $rm_url" "git:  $rm_theirs" "ours: $rm_ours"
        fi
    done
    for rm_url in "${rm_stricter[@]}"; do
        rm_theirs=$(rm_git_argv "$rm_url")
        rm_ours=$("$rm_t" exec "$rm_url" upload 2>&1)
        case "$rm_ours" in
            "error "*) rm_refuses=1 ;;
            *) rm_refuses=0 ;;
        esac
        if [ "$rm_theirs" != none ] && [ "$rm_refuses" = 1 ]; then
            note "remote url: $rm_url is passed on by git but refused here on purpose (${rm_ours#error })"
        else
            bad "remote url (stricter): $rm_url" "git:  $rm_theirs" "ours: $rm_ours"
        fi
    done

    # receive-pack differs only in the program name.
    rm_theirs=$(REC_OUT="$rm_root/rec.out" GIT_SSH_COMMAND="$rm_rec" GIT_SSH_VARIANT=ssh GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git push 'u@host:dir/it'"'"'s!' HEAD:refs/heads/x >/dev/null 2>&1; grep -o "git-receive-pack.*" "$rm_root/rec.out" | tr -d '[]'; rm -f "$rm_root/rec.out")
    rm_ours=$("$rm_t" exec 'u@host:dir/it'"'"'s!' receive)
    if [ "${rm_ours#*cmd=}" = "$rm_theirs" ] && [ -n "$rm_theirs" ]; then
        note "remote url: the receive-pack command is git's ($rm_theirs)"
    else
        bad "remote url: receive-pack command" "git:  $rm_theirs" "ours: $rm_ours"
    fi

    # sq_quote against Python's own reading of a shell word: sh must hand back the text.
    rm_quote_ok=1
    for rm_text in "plain" "it's" "a b" '!bang' '$HOME `x`' '"dq"' '' 'back\slash' "multi
line"; do
        rm_quoted=$("$rm_t" quote "$rm_text"; echo x)
        rm_quoted=${rm_quoted%x}
        rm_quoted=${rm_quoted%$'\n'}
        rm_back=$(sh -c "printf '%s' $rm_quoted; echo x")
        rm_back=${rm_back%x}
        rm_back=${rm_back%$'\n'}
        if [ "$rm_back" != "$rm_text" ]; then
            rm_quote_ok=0
            bad "remote sq_quote round trip" "text:   $rm_text" "quoted: $rm_quoted" "sh got: $rm_back"
        fi
    done
    [ "$rm_quote_ok" = 1 ] && note "remote sq_quote: sh reads every quoted text back unchanged"

    # --- 2. insteadOf ----------------------------------------------------------
    rm_repo="$rm_root/insteadof"
    git init -q "$rm_repo"
    (
        cd "$rm_repo"
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        git config --add 'url.ssh://git@h/.insteadOf' 'gh:'
        git config --add 'url.ssh://git@h/org/.insteadOf' 'gh:org/'
        git config --add 'url.https://mirror/.insteadOf' 'https://upstream/'
        git config --add 'url.ssh://push@h/.pushInsteadOf' 'https://upstream/'
        git config --add 'url.ssh://first/.insteadOf' 'tie:'
        git config --add 'url.ssh://second/.insteadOf' 'tie:'
        git config --add 'url.ssh://both/.insteadOf' 'b:'
        git config --add 'url.ssh://bothpush/.pushInsteadOf' 'b:'
        git config --add 'url.ssh://multi/.insteadOf' 'm1:'
        git config --add 'url.ssh://multi/.insteadOf' 'm2:'
        git config --add 'url.https://q/.insteadOf' 'quoted:'
    ) >/dev/null 2>&1
    rm_i=0
    for rm_url in 'gh:org/r' 'gh:x/r' 'gh:' 'https://upstream/x' 'https://other/x' 'tie:r' 'b:r' 'm1:r' 'm2:r' 'quoted:r' '/srv/local' 'GH:org/r'; do
        rm_i=$((rm_i + 1))
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$rm_repo" remote add "r$rm_i" "$rm_url" >/dev/null 2>&1
        rm_want_fetch=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$rm_repo" remote get-url "r$rm_i" 2>&1)
        rm_want_push=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$rm_repo" remote get-url --push "r$rm_i" 2>&1)
        rm_got_fetch=$("$rm_t" rewrite "$rm_repo/.git/config" "$rm_url" fetch 2>&1)
        rm_got_push=$("$rm_t" rewrite "$rm_repo/.git/config" "$rm_url" push 2>&1)
        if [ "$rm_got_fetch" = "$rm_want_fetch" ] && [ "$rm_got_push" = "$rm_want_push" ]; then
            note "remote insteadOf: $rm_url -> fetch $rm_want_fetch, push $rm_want_push"
        else
            bad "remote insteadOf: $rm_url" "git fetch: $rm_want_fetch" "our fetch: $rm_got_fetch" "git push:  $rm_want_push" "our push:  $rm_got_push"
        fi
    done

    # --- 3. ssh_config ------------------------------------------------------------
    rm_me=$(id -un)
    rm_ssh_check() { # name file host user port
        local name=$1 file=$2 host=$3 user=$4 port=$5
        local args=(-F "$file")
        [ -n "$user" ] && args+=(-l "$user")
        [ -n "$port" ] && args+=(-p "$port")
        local theirs ours
        theirs=$(ssh -G "${args[@]}" "$host" 2>/dev/null | python3 -c '
import sys, os
want = {"hostname": "", "user": "", "port": ""}
ids = []
for line in sys.stdin:
    key, _, value = line.rstrip("\n").partition(" ")
    if key in want:
        want[key] = value
    elif key == "identityfile" and not value.startswith("~/.ssh/id_") and value != "none":
        ids.append(value)
print("hostname=" + want["hostname"])
print("user=" + want["user"])
print("port=" + want["port"])
for i in ids:
    print("identity=" + i)
')
        ours=$("$rm_t" sshconfig "$file" "$host" "$user" "$port" 2>&1 | sed -e "s/^user=\$/user=$rm_me/" -e 's/^port=0$/port=22/')
        if [ "$theirs" = "$ours" ]; then
            note "remote ssh_config: $name ($host) = $(printf '%s' "$theirs" | tr '\n' ' ')"
        else
            bad "remote ssh_config: $name ($host)" "ssh -G: $(printf '%s' "$theirs" | tr '\n' ' ')" "ours:   $(printf '%s' "$ours" | tr '\n' ' ')"
        fi
    }

    cat >"$rm_root/cfg1" <<'CFGEOF'
# a comment
Host Foo
  HostName one
Host foo
  HostName two # trailing comment
  User alice
  Port 2200
  IdentityFile ~/.ssh/a
  IdentityFile "~/.ssh/b c"
  IdentityFile ~/.ssh/a
Host *.example.com !secret.example.com
  User exampleuser
  IdentityFile ~/.ssh/ex
Host *
  User fallback
  Port 2022
  HostName=%h.fallback
CFGEOF
    cat >"$rm_root/cfg2" <<'CFGEOF'
User first
Port 4000
Host a?c
    Port=5000
    User = second
    HostName	tabbed
Host a b c
  IdentityFile k1
  IdentityFile k2
Host *
  IdentityFile k1
  IdentityFile none
  IdentityFile k3
  Port 1
CFGEOF
    cat >"$rm_root/cfg3" <<'CFGEOF'
Host gh
  HostName github.com
  User git
  IdentityFile ~/.ssh/gh_ed25519
Host gh-*
  HostName ssh.%h.test
  Port 443
Host !gh-no gh-*
  User negated
CFGEOF
    : >"$rm_root/cfg_empty"

    rm_ssh_check "case: Foo matches Host Foo only" "$rm_root/cfg1" Foo "" ""
    rm_ssh_check "first value wins, identities accumulate" "$rm_root/cfg1" foo "" ""
    rm_ssh_check "FOO matches neither Foo nor foo" "$rm_root/cfg1" FOO "" ""
    rm_ssh_check "wildcard and negation (excluded)" "$rm_root/cfg1" secret.example.com "" ""
    rm_ssh_check "wildcard and negation (included)" "$rm_root/cfg1" www.example.com "" ""
    rm_ssh_check "unmatched host falls to Host *" "$rm_root/cfg1" other.test "" ""
    rm_ssh_check "caller's user and port win" "$rm_root/cfg1" foo bob 99
    rm_ssh_check "options before any Host apply to all" "$rm_root/cfg2" zzz "" ""
    rm_ssh_check "? matches one character; = and tabs separate" "$rm_root/cfg2" abc "" ""
    rm_ssh_check "Host list with several names" "$rm_root/cfg2" b "" ""
    rm_ssh_check "alias with HostName" "$rm_root/cfg3" gh "" ""
    rm_ssh_check "%h in HostName" "$rm_root/cfg3" gh-one "" ""
    rm_ssh_check "negated name in a list" "$rm_root/cfg3" gh-no "" ""
    rm_ssh_check "empty file" "$rm_root/cfg_empty" Plain.Host "" ""

    # Documented gap: Match is skipped whole (OpenSSH would apply it).
    printf 'Host a\n  Port 1\nMatch host a\n  User m\nHost *\n  User z\n' >"$rm_root/cfg_match"
    rm_got=$("$rm_t" sshconfig "$rm_root/cfg_match" a "" "" | tr '\n' ' ')
    if [ "$rm_got" = "hostname=a user=z port=1 " ]; then
        note "remote ssh_config: a Match block is skipped whole, as documented"
    else
        bad "remote ssh_config: Match block" "$rm_got"
    fi

    # --- 4. known_hosts -------------------------------------------------------------
    if command -v ssh-keygen >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        rm_kd="$rm_root/keys"
        mkdir -p "$rm_kd"
        ssh-keygen -q -t ed25519 -N '' -f "$rm_kd/k1" -C c1 >/dev/null 2>&1
        ssh-keygen -q -t ecdsa -N '' -f "$rm_kd/k2" -C c2 >/dev/null 2>&1
        ssh-keygen -q -t ecdsa -b 384 -N '' -f "$rm_kd/k3" -C c3 >/dev/null 2>&1
        rm_k1=$(cut -d' ' -f1,2 "$rm_kd/k1.pub")
        rm_k2=$(cut -d' ' -f1,2 "$rm_kd/k2.pub")
        rm_k3=$(cut -d' ' -f1,2 "$rm_kd/k3.pub")
        cat >"$rm_root/kh" <<KHEOF
# a comment line
plain.example.com $rm_k1
[port.example.com]:2222 $rm_k2 trailing comment
*.wild.example.com,other.example.com $rm_k1
!bad.wild.example.com,*.neg.example.com $rm_k2

@revoked rev.example.com $rm_k3
@cert-authority *.ca.example.com $rm_k3
UPPER.example.com $rm_k1
q?.example.com $rm_k2
[*.wild.example.com]:2222 $rm_k3
plain.example.com $rm_k2
[10.0.0.1]:22 $rm_k1
192.168.0.? $rm_k3
KHEOF
        cp "$rm_root/kh" "$rm_root/kh_hashed"
        ssh-keygen -H -f "$rm_root/kh_hashed" >/dev/null 2>&1

        # ssh-keygen -F as "type key marker line" lines. ssh lower-cases the host
        # before it looks it up; `ssh-keygen -F` does not (a hashed entry would
        # never match "PLAIN.Example.COM"), so the oracle is asked the way ssh asks.
        rm_kh_theirs() { # file host port
            local host name
            host=$(printf %s "$2" | tr 'A-Z' 'a-z')
            name=$host
            [ "$3" != "" ] && [ "$3" != 0 ] && [ "$3" != 22 ] && name="[$host]:$3"
            ssh-keygen -F "$name" -f "$1" 2>/dev/null | python3 -c '
import sys
line_no = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("# Host"):
        line_no = line.rsplit("line ", 1)[1].split()[0]
        continue
    if line.startswith("#") or not line:
        continue
    f = line.split()
    marker = ""
    if f[0].startswith("@"):
        marker = f[0][1:]
        f = f[1:]
    print(f[1], f[2], marker, line_no)
'
        }
        rm_kh_n=0
        for rm_file in kh kh_hashed; do
            for rm_q in "plain.example.com 22" "PLAIN.Example.COM 0" "port.example.com 0" "port.example.com 2222" "port.example.com 22" "a.wild.example.com 0" "a.wild.example.com 2222" \
                        "other.example.com 0" "bad.wild.example.com 0" "x.neg.example.com 0" "rev.example.com 0" "z.ca.example.com 0" \
                        "upper.example.com 0" "qa.example.com 0" "qab.example.com 0" "10.0.0.1 0" "10.0.0.1 22" "192.168.0.7 0" "192.168.0.77 0" "unknown.example.com 0"; do
                set -- $rm_q
                rm_theirs=$(rm_kh_theirs "$rm_root/$rm_file" "$1" "$2")
                rm_ours=$("$rm_t" knownhosts "$rm_root/$rm_file" "$1" "$2" 2>&1)
                if [ "$rm_theirs" = "$rm_ours" ]; then
                    rm_kh_n=$((rm_kh_n + 1))
                else
                    bad "remote known_hosts ($rm_file): $1 port $2" "ssh-keygen -F: $(printf '%s' "$rm_theirs" | cut -c1-90 | tr '\n' '|')" "ours:          $(printf '%s' "$rm_ours" | cut -c1-90 | tr '\n' '|')"
                fi
            done
        done
        note "remote known_hosts: $rm_kh_n queries over the plain and the ssh-keygen -H hashed file agree with ssh-keygen -F (lines, markers, key types, keys)"

        rm_hashed=$(grep -c '^|1|' "$rm_root/kh_hashed")
        rm_found=$("$rm_t" knownhosts "$rm_root/kh_hashed" plain.example.com 0 | wc -l)
        if [ "$rm_hashed" -ge 3 ] && [ "$rm_found" = 2 ]; then
            note "remote known_hosts: $rm_hashed hashed entries in the oracle file, both plain.example.com lines found through HMAC-SHA1"
        else
            bad "remote known_hosts: hashed entries" "hashed=$rm_hashed found=$rm_found"
        fi
    else
        note "remote known_hosts: ssh-keygen or python3 not found; skipped"
    fi

    # --- 5. HMAC-SHA1 against Python's hmac ----------------------------------------------
    if command -v python3 >/dev/null 2>&1; then
        rm_hmac_ok=0
        rm_hmac_bad=0
        while IFS=' ' read -r rm_key rm_msg rm_want; do
            rm_got=$("$rm_t" hmac "$rm_key" "$rm_msg" 2>&1)
            if [ "$rm_got" = "$rm_want" ]; then
                rm_hmac_ok=$((rm_hmac_ok + 1))
            else
                rm_hmac_bad=$((rm_hmac_bad + 1))
                bad "remote hmac_sha1 key=${rm_key:0:16}.. msg=${rm_msg:0:16}.." "python: $rm_want" "ours:   $rm_got"
            fi
        done < <(python3 - <<'PYEOF'
import hmac, hashlib, random
r = random.Random(31)
cases = [(b"", b""), (b"k", b""), (b"", b"m"), (b"Jefe", b"what do ya want for nothing?"),
         (b"\x0b" * 20, b"Hi There"), (b"\xaa" * 80, b"Test Using Larger Than Block-Size Key"),
         (b"a" * 64, b"x"), (b"a" * 65, b"x"), (b"a" * 63, b"x")]
for n in (1, 19, 20, 21, 55, 56, 63, 64, 65, 100, 127, 128, 129, 300):
    cases.append((bytes(r.randrange(256) for _ in range(n)), bytes(r.randrange(256) for _ in range(n * 3 % 211))))
for k, m in cases:
    # an empty hex argument is not representable as a field; a lone "00" stands for none below
    print((k.hex() or "-"), (m.hex() or "-"), hmac.new(k, m, hashlib.sha1).hexdigest())
PYEOF
)
        if [ "$rm_hmac_bad" -eq 0 ] && [ "$rm_hmac_ok" -ge 20 ]; then
            note "remote hmac_sha1: $rm_hmac_ok vectors (empty, RFC 2202, keys around the 64-byte block, random) equal Python's hmac"
        else
            bad "remote hmac_sha1" "ok=$rm_hmac_ok bad=$rm_hmac_bad"
        fi
    fi
fi
