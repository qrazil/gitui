# The layered config reads: `[include]` / `[includeIf]`, the identity chain,
# the editor chain, `commit.gpgsign`, and the settings with defaults
# (`pull.rebase`, `push.default`, `init.defaultBranch`, `rerere.enabled`),
# each compared with real `git` (`git config`, `git var`, `git init`) run under
# the same environment. Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`,
# `note`/`bad` and the counters.

cex="$WORK/config_extras"
mkdir -p "$cex/home"
cx_home="$cex/home"

# ce [NAME=value ...] command ...: the command with every identity, editor and
# config variable cleared, then the given ones set, and git pointed at a
# global file under $cx_home (or `$CX_GLOBAL`).
ce() {
    env -u GIT_EDITOR -u VISUAL -u EDITOR -u EMAIL -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
        -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u XDG_CONFIG_HOME \
        HOME="$cx_home" GIT_CONFIG_GLOBAL="${CX_GLOBAL:-$cx_home/gitconfig}" GIT_CONFIG_NOSYSTEM=1 TERM=xterm "$@"
}

cx_git() { ce git "$@"; }

if build t_config_extras; then
    cx_ours() { local r=$1; shift; ce "$WORK/t_config_extras" "$r/.git" "$@" 2>&1; }

    # --- includes ---------------------------------------------------------------

    cat >"$cx_home/gitconfig" <<'CFG'
[user]
	name = Global Name
	email = global@example.com
[inc]
	after = unset
[include]
	path = extra.cfg
[include]
	path = missing.cfg
[includeIf "gitdir:~/work/"]
	path = ~/work.cfg
[includeIf "gitdir/i:~/WORK/"]
	path = work-i.cfg
[includeIf "gitdir:/nonexistent/"]
	path = never.cfg
[includeIf "gitdir:./other/"]
	path = other.cfg
[includeIf "gitdir:r1/.git"]
	path = r1.cfg
[includeIf "onbranch:feature/**"]
	path = feature.cfg
[includeIf "onbranch:main"]
	path = main.cfg
[includeIf "onbranch:rel*"]
	path = rel.cfg
[inc]
	after = global
CFG
    printf '[inc]\n\textra = yes\n\tafter = extra\n[user]\n\temail = extra@example.com\n[include]\n\tpath = nested.cfg\n' >"$cx_home/extra.cfg"
    printf '[inc]\n\tnested = yes\n' >"$cx_home/nested.cfg"
    printf '[inc]\n\twork = tilde\n' >"$cx_home/work.cfg"
    printf '[inc]\n\tworkfold = fold\n' >"$cx_home/work-i.cfg"
    printf '[inc]\n\tnever = bad\n' >"$cx_home/never.cfg"
    printf '[inc]\n\tother = relative\n' >"$cx_home/other.cfg"
    printf '[inc]\n\tr1 = bare-pattern\n' >"$cx_home/r1.cfg"
    printf '[inc]\n\tfeature = yes\n' >"$cx_home/feature.cfg"
    printf '[inc]\n\tmain = yes\n' >"$cx_home/main.cfg"
    printf '[inc]\n\trel = yes\n' >"$cx_home/rel.cfg"

    mkdir -p "$cx_home/work" "$cx_home/other" "$cex/outside"
    cx_repo() { # dir branch
        mkdir -p "$1" && cx_git init -q "$1" && cx_git -C "$1" symbolic-ref HEAD "refs/heads/$2"
    }
    cx_repo "$cx_home/work/r1" main
    cx_repo "$cx_home/other/r2" feature/x
    cx_repo "$cex/outside/r3" release-1
    cx_git -C "$cex/outside/r3" config core.editor localeditor

    cx_inc_case() { # label repo
        local label=$1 r=$2
        local want got
        want=$(cx_git -C "$r" config --list 2>&1 | sed 's/^\(include[^=]*\)=.*/\1/' | sort)
        got=$(cx_ours "$r" list | sed 's/^\(include[^=]*\)=.*/\1/' | sort)
        if [ "$want" != "$got" ]; then
            bad "config includes: $label: list differs from git config --list" "$(diff <(echo "$want") <(echo "$got") | head -10)"
            return
        fi
        want=$(cx_git -C "$r" config --list 2>&1)
        got=$(cx_ours "$r" list)
        if [ "$want" != "$got" ]; then
            bad "config includes: $label: order differs from git config --list" "$(diff <(echo "$want") <(echo "$got") | head -10)"
            return
        fi
        local key bad_key="" n_keys=0
        for key in inc.extra inc.nested inc.after inc.work inc.workfold inc.never inc.other inc.r1 inc.feature inc.main inc.rel user.email user.name core.editor; do
            want=$(cx_git -C "$r" config --get "$key" 2>/dev/null || echo "<unset>")
            got=$(cx_ours "$r" get "$key")
            n_keys=$((n_keys + 1))
            [ "$want" = "$got" ] || bad_key="$bad_key $key(git=$want ours=$got)"
        done
        if [ -n "$bad_key" ]; then
            bad "config includes: $label: --get differs:$bad_key"
        else
            note "config includes: $label ($n_keys keys read, $(cx_ours "$r" list | wc -l) entries, order equals git config --list)"
        fi
    }
    cx_inc_case "repo under ~/work on main (relative path, nested, missing, ~/, gitdir/i, bare pattern, onbranch:main)" "$cx_home/work/r1"
    cx_inc_case "repo under ~/other on feature/x (gitdir:./ relative to the including file, onbranch glob)" "$cx_home/other/r2"
    cx_inc_case "repo outside every gitdir pattern on release-1 (onbranch:rel*, local core.editor)" "$cex/outside/r3"
    echo "ref: refs/heads/main" >"$cex/outside/r3/.git/HEAD"
    cx_inc_case "same repo after HEAD moves to main" "$cex/outside/r3"
    # a relative gitdir is made absolute with $PWD
    want=$(cd "$cx_home/work/r1" && cx_git config --get inc.work 2>/dev/null || echo "<unset>")
    got=$(cd "$cx_home/work/r1" && ce "$WORK/t_config_extras" .git get inc.work 2>&1)
    if [ "$want" = "$got" ]; then note "config includes: gitdir given as .git from inside the repository ($got)"; else bad "config includes: relative gitdir" "git=$want ours=$got"; fi

    # --- identity ---------------------------------------------------------------

    cx_ident_case() { # label repo role [NAME=value ...]
        local label=$1 r=$2 role=$3; shift 3
        local want got
        want=$(ce "$@" git -C "$r" var "GIT_${role}_IDENT" 2>&1 | sed 's/ [0-9]* [-+][0-9]*$//')
        got=$(ce "$@" "$WORK/t_config_extras" "$r/.git" ident "$role" 2>&1)
        if [ "$want" = "$got" ]; then
            note "config ident: $label: $role is $got"
        else
            bad "config ident: $label: $role" "git:  $want" "ours: $got"
        fi
    }
    r=$cx_home/work/r1
    for role in AUTHOR COMMITTER; do
        cx_ident_case "global user.* plus an included email override" "$r" $role
    done
    cx_git -C "$r" config author.name "Author Only"
    cx_git -C "$r" config committer.email "committer@only.example"
    for role in AUTHOR COMMITTER; do
        cx_ident_case "author.name / committer.email beat user.*" "$r" $role
    done
    cx_git -C "$r" config author.email "author@only.example"
    cx_ident_case "author.email" "$r" AUTHOR
    for role in AUTHOR COMMITTER; do
        cx_ident_case "environment beats config" "$r" $role GIT_AUTHOR_NAME=EnvAuthor GIT_COMMITTER_NAME=EnvCommitter GIT_AUTHOR_EMAIL=env-a@example.com GIT_COMMITTER_EMAIL=env-c@example.com
    done
    cx_ident_case "GIT_AUTHOR_EMAIL alone" "$r" AUTHOR GIT_AUTHOR_EMAIL=just-email@example.com
    printf '[user]\n\tname = Mail Less\n' >"$cx_home/gc_nomail"
    for role in AUTHOR COMMITTER; do
        cx_ident_case "no email anywhere but \$EMAIL" "$cex/outside/r3" $role GIT_CONFIG_GLOBAL="$cx_home/gc_nomail" EMAIL=from-env@example.com
    done
    cx_ident_case "\$EMAIL loses to user.email" "$cex/outside/r3" AUTHOR EMAIL=from-env@example.com
    printf '[user]\n\tname = Mail Less\n\temail = ue@example.com\n' >"$cx_home/gc_both"
    cx_ident_case "\$EMAIL loses to user.email (only user.*)" "$cex/outside/r3" COMMITTER GIT_CONFIG_GLOBAL="$cx_home/gc_both" EMAIL=from-env@example.com

    # --- editor -----------------------------------------------------------------

    cx_editor_case() { # label repo [NAME=value ...]
        local label=$1 r=$2; shift 2
        local want got
        want=$(ce "$@" git -C "$r" var GIT_EDITOR 2>&1)
        got=$(ce "$@" "$WORK/t_config_extras" "$r/.git" editor 2>&1)
        if [ "$want" = "$got" ]; then
            note "config editor: $label: $got"
        else
            bad "config editor: $label" "git:  $want" "ours: $got"
        fi
    }
    r=$cx_home/work/r1
    # With nothing set git falls back on the default its build was configured
    # with (`vi` unless DEFAULT_EDITOR said otherwise: Debian and Ubuntu build
    # with `editor`), which a program cannot ask for except through `git var`.
    cx_default_editor=$(ce git -C "$r" var GIT_EDITOR 2>&1)
    if [ "$cx_default_editor" = vi ]; then
        cx_editor_case "nothing set: vi" "$r"
    else
        got=$(ce "$WORK/t_config_extras" "$r/.git" editor 2>&1)
        if [ "$got" = vi ]; then
            note "config editor: nothing set: vi (this git was built with the default '$cx_default_editor')"
        else
            bad "config editor: nothing set" "ours: $got" "git's build default is '$cx_default_editor'; ours must be vi"
        fi
    fi
    cx_editor_case "EDITOR only" "$r" EDITOR=ed
    cx_editor_case "VISUAL beats EDITOR" "$r" EDITOR=ed VISUAL=visualed
    cx_git -C "$r" config core.editor coreed
    cx_editor_case "core.editor beats VISUAL and EDITOR" "$r" EDITOR=ed VISUAL=visualed
    cx_editor_case "GIT_EDITOR beats core.editor" "$r" EDITOR=ed VISUAL=visualed GIT_EDITOR=giteditor
    printf '[core]\n\teditor = globaled\n' >"$cx_home/gc_editor"
    cx_editor_case "core.editor from the global file" "$cex/outside/r3" GIT_CONFIG_GLOBAL="$cx_home/gc_editor" VISUAL=visualed
    cx_editor_case "local core.editor beats the global one" "$cex/outside/r3" GIT_CONFIG_GLOBAL="$cx_home/gc_editor"

    # --- the settings with defaults ---------------------------------------------

    cx_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

    cx_settings_case() { # label branch globalfile
        local label=$1 branch=$2 gfile=$3
        local d="$cex/s$cx_n"
        cx_n=$((cx_n + 1))
        rm -rf "$d"
        CX_GLOBAL="$gfile" cx_git init -q "$d"
        local i
        for i in ${cx_sets[@]+"${cx_sets[@]}"}; do
            local k=${i%% *} v=${i#* }
            if [ "$k" = "$i" ]; then printf '[%s]\n\t%s\n' "${k%%.*}" "${k#*.}" >>"$d/.git/config"; else CX_GLOBAL="$gfile" cx_git -C "$d" config "$k" "$v"; fi
        done
        [ -n "${cx_rr:-}" ] && mkdir -p "$d/.git/rr-cache"
        local gp pr_key pr_raw pr_low pr push_raw push ras ib rr
        gp=$(CX_GLOBAL="$gfile" cx_git -C "$d" config --type=bool --get commit.gpgsign 2>/dev/null || echo false)
        pr_key=pull.rebase
        if CX_GLOBAL="$gfile" cx_git -C "$d" config --get "branch.$branch.rebase" >/dev/null 2>&1; then pr_key="branch.$branch.rebase"; fi
        pr_raw=$(CX_GLOBAL="$gfile" cx_git -C "$d" config --get "$pr_key" 2>/dev/null || echo false)
        pr_low=$(cx_lower "$pr_raw")
        case $pr_low in
            m|merges) pr=merges ;;
            i|interactive) pr=interactive ;;
            *) pr=$(CX_GLOBAL="$gfile" cx_git -C "$d" config --type=bool --get "$pr_key" 2>/dev/null || echo false) ;;
        esac
        push_raw=$(cx_lower "$(CX_GLOBAL="$gfile" cx_git -C "$d" config --get push.default 2>/dev/null || echo simple)")
        case $push_raw in
            tracking) push=upstream ;;
            nothing|current|upstream|simple|matching) push=$push_raw ;;
            *) push=simple ;;
        esac
        ras=$(CX_GLOBAL="$gfile" cx_git -C "$d" config --type=bool --get push.autosetupremote 2>/dev/null || echo false)
        local fresh="$cex/fresh$cx_n"
        rm -rf "$fresh"
        CX_GLOBAL="$gfile" cx_git init -q "$fresh" 2>/dev/null
        ib=$(CX_GLOBAL="$gfile" cx_git -C "$fresh" symbolic-ref --short HEAD)
        if CX_GLOBAL="$gfile" cx_git -C "$d" config --get rerere.enabled >/dev/null 2>&1; then
            rr=$(CX_GLOBAL="$gfile" cx_git -C "$d" config --type=bool --get rerere.enabled 2>/dev/null || echo false)
        elif [ -d "$d/.git/rr-cache" ]; then rr=true; else rr=false; fi
        local want got
        want="gpgsign $gp
pull_rebase $pr
push_default $push
autosetup $ras
init_branch $ib
rerere $rr"
        got=$(CX_GLOBAL="$gfile" cx_ours "$d" settings "$branch")
        if [ "$want" = "$got" ]; then
            note "config settings: $label ($(echo "$got" | tr '\n' ' '))"
        else
            bad "config settings: $label" "$(diff <(echo "$want") <(echo "$got"))"
        fi
    }
    cx_n=0
    : >"$cx_home/gc_empty"
    printf '[init]\n\tdefaultBranch = trunk\n[push]\n\tautoSetupRemote = yes\n' >"$cx_home/gc_global"
    cx_rr=""
    cx_sets=()
    cx_settings_case "all defaults" main "$cx_home/gc_empty"
    cx_sets=("commit.gpgsign true" "push.default tracking" "rerere.enabled yes")
    cx_settings_case "gpgsign true, push.default tracking, rerere on" main "$cx_home/gc_empty"
    cx_sets=("commit.gpgsign no" "pull.rebase true" "branch.main.rebase false")
    cx_settings_case "branch.main.rebase overrides pull.rebase" main "$cx_home/gc_empty"
    cx_sets=("pull.rebase true" "branch.main.rebase false")
    cx_settings_case "another branch falls back to pull.rebase" topic "$cx_home/gc_empty"
    cx_sets=("pull.rebase merges" "branch.main.rebase interactive")
    cx_settings_case "merges and interactive" main "$cx_home/gc_empty"
    cx_settings_case "pull.rebase merges on a branch with no setting" other "$cx_home/gc_empty"
    cx_sets=("pull.rebase i")
    cx_settings_case "the short form i" main "$cx_home/gc_empty"
    cx_sets=("pull.rebase")
    cx_settings_case "a bare pull.rebase key is true" main "$cx_home/gc_empty"
    cx_sets=("push.default Upstream" "commit.gpgsign")
    cx_settings_case "push.default is case-insensitive, bare gpgsign is true" main "$cx_home/gc_empty"
    cx_sets=("push.default sideways")
    cx_settings_case "an unknown push.default is simple" main "$cx_home/gc_empty"
    cx_sets=()
    cx_settings_case "init.defaultBranch and push.autoSetupRemote from the global file" main "$cx_home/gc_global"
    cx_rr=1
    cx_settings_case "rerere is on when rr-cache exists" main "$cx_home/gc_empty"
    cx_sets=("rerere.enabled false")
    cx_settings_case "rerere.enabled false beats rr-cache" main "$cx_home/gc_empty"
    cx_sets=("rerere.enabled")
    cx_rr=""
    cx_settings_case "a bare rerere.enabled is true" main "$cx_home/gc_empty"
    cx_rr=""

    # --- commit.gpgsign refuses a merge before it changes anything ---------------

    if build t_merge; then
        g="$cex/gpg"
        rm -rf "$g"
        cx_git init -q -b main "$g"
        gi() { cx_git -C "$g" -c user.name=T -c user.email=t@example.com "$@"; }
        echo a >"$g/a"; gi add a; gi commit -q -m a
        gi checkout -q -b side; echo s >"$g/s"; gi add s; gi commit -q -m s
        gi checkout -q main; echo m >"$g/m"; gi add m; gi commit -q -m m
        head_before=$(gi rev-parse HEAD)
        gi config commit.gpgsign true
        out=$(ce "$WORK/t_merge" "$g/.git" "$g" merge side 2>&1)
        if [ "$(gi rev-parse HEAD)" = "$head_before" ] && [ -z "$(gi status --porcelain)" ] && [ ! -e "$g/.git/MERGE_HEAD" ] && [ ! -e "$g/s" ] && case $out in "refused not supported: commit.gpgsign is true"*) true ;; *) false ;; esac; then
            note "config gpgsign: a merge is refused with commit.gpgsign=true and nothing changes ($out)"
        else
            bad "config gpgsign: merge with commit.gpgsign=true" "$out" "$(gi status --short)"
        fi
        gi config commit.gpgsign false
        out=$(ce "$WORK/t_merge" "$g/.git" "$g" merge side 2>&1)
        if case $out in "ending merged"*) true ;; *) false ;; esac; then
            note "config gpgsign: the same merge goes through with commit.gpgsign=false"
        else
            bad "config gpgsign: merge with commit.gpgsign=false" "$out"
        fi
    fi
fi
