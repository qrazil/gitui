# `GIT_config.m31` -- the reader (every section, subsection and key, multi
# values, quoting, continuation lines, bare keys) and the write path (set, add,
# unset, unset-all), driven through `t_config` and checked against `git config`
# as the oracle: the same operation on a copy of the same bytes must leave the
# same bytes, and the same list.
# Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the
# counters.

cfx="$WORK/config_fx"
mkdir -p "$cfx"

# cfg_case <label> <initial content> -- sets $cfg_dir/base for the checks below
cfg_base() {
    printf '%s' "$2" >"$cfx/$1.base"
}

cfg_read_case() {
    local label=$1
    local base="$cfx/$label.base"
    local want got
    want=$(git config --file "$base" --list 2>&1)
    got=$("$WORK/t_config" list "$base" 2>&1)
    if [ "$want" = "$got" ]; then
        note "config: list $label ($(printf '%s\n' "$want" | grep -c .) entries)"
    else
        bad "config: list $label" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -8)"
    fi
}

# cfg_edit <label> <op> <name> [value]: op is set|add|unset|unset-all
cfg_edit() {
    local label=$1 op=$2 name=$3 value=${4-} flag
    local gitf="$cfx/$label.$op.git" ours="$cfx/$label.$op.ours"
    cp "$cfx/$label.base" "$gitf"
    cp "$cfx/$label.base" "$ours"
    local gst ost
    case $op in
        set)       git config --file "$gitf" "$name" "$value" 2>/dev/null; gst=$? ;;
        add)       git config --file "$gitf" --add "$name" "$value" 2>/dev/null; gst=$? ;;
        unset)     git config --file "$gitf" --unset "$name" 2>/dev/null; gst=$? ;;
        unset-all) git config --file "$gitf" --unset-all "$name" 2>/dev/null; gst=$? ;;
    esac
    "$WORK/t_config" "$op" "$ours" "$name" "$value" >/dev/null 2>&1
    ost=$?
    local tag="config: $op $name in $label"
    if [ $gst -ne 0 ]; then
        if [ $ost -ne 0 ] && cmp -s "$cfx/$label.base" "$ours"; then
            note "$tag refused like git (git exit $gst)"
        else
            bad "$tag" "git refused (exit $gst) but ours exit $ost / file changed"
        fi
    elif [ $ost -ne 0 ]; then
        bad "$tag" "git succeeded but ours refused"
    elif cmp -s "$gitf" "$ours"; then
        note "$tag"
    else
        bad "$tag" "$(diff "$gitf" "$ours" | head -10)"
    fi
}

if build t_config; then
    cfg_base plain '[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
[remote "origin"]
	url = https://example.com/a.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
'
    cfg_base messy '# leading comment
; another
[Core]
	FileMode = TRUE   # trailing comment
	Name = "quoted ; value"   ; comment
	empty =
	bare
	tab = a\tb\nc
	esc = "say \"hi\" \\ done"
	spaces =    inner   spaces   kept   
	cont = one \
two
[ALIAS]
	co = checkout
[remote "Or igin"]
	url = x
[remote "Or igin"]
	url = y
	pushurl = z
[section.OldSub]
	Key = v
[a]
[b "empty sub"]
[core]
	filemode = false
'
    cfg_base multi '[remote "origin"]
	fetch = +refs/heads/a:refs/remotes/o/a
	fetch = +refs/heads/b:refs/remotes/o/b
	url = u
[x]
	one = 1
[remote "origin"]
	fetch = +refs/heads/c:refs/remotes/o/c
'
    cfg_base noeol '[core]
	a = 1'
    cfg_base crlf "$(printf '[core]\r\n\ta = 1\r\n\tb = two\r\n')"
    cfg_base empty ''
    cfg_base comments '[core]
	# about a
	a = 1
	; about b
	b = 2
[other]
	# lonely comment
	c = 3
[last]
	d = 4
	# after d
'
    cfg_base shared '[core] a = 1
[core] b = 2
[sec] x = 9 ; note
'
    cfg_base blanks '[core]
	a = 1

	b = 2


[next]
	n = 1

'
    for l in plain messy multi noeol crlf empty comments shared blanks; do cfg_read_case $l; done

    # get-all, get and bool against git
    for spec in "messy core.filemode" "messy remote.Or igin.url" "multi remote.origin.fetch" "plain remote.origin.url" "messy section.OldSub.key" "messy core.bare" "messy core.missing"; do
        label=${spec%% *}; name=${spec#* }
        want=$(git config --file "$cfx/$label.base" --get-all "$name" 2>&1)
        got=$("$WORK/t_config" get-all "$cfx/$label.base" "$name" 2>&1)
        if [ "$want" = "$got" ]; then note "config: get-all $name ($label)"; else bad "config: get-all $name ($label)" "want: $want" "got: $got"; fi
    done
    for spec in "messy core.filemode" "messy core.bare" "messy core.empty" "messy core.name" "multi x.one" "messy core.missing"; do
        label=${spec%% *}; name=${spec#* }
        if git config --file "$cfx/$label.base" --get "$name" >/dev/null 2>&1; then
            want=$(git config --file "$cfx/$label.base" --type=bool --get "$name" 2>/dev/null) || want=invalid
        else
            want=unset
        fi
        got=$("$WORK/t_config" bool "$cfx/$label.base" "$name" 2>&1)
        if [ "$want" = "$got" ]; then note "config: bool $name ($label) = $got"; else bad "config: bool $name ($label)" "want: $want" "got: $got"; fi
    done

    # set
    for l in plain messy noeol crlf empty comments shared blanks; do
        cfg_edit $l set core.filemode false
        cfg_edit $l set core.newkey 'a value'
        cfg_edit $l set remote.origin.url 'https://x/y.git'
        cfg_edit $l set brand.new.key v
        cfg_edit $l set sec.x 'semi;colon'
        cfg_edit $l set sec.y ' lead and trail '
        cfg_edit $l set sec.z "tab	and \"quote\" and \\ back"
        cfg_edit $l set Sec.CamelKey v
        cfg_edit $l set sec.empty ''
    done
    cfg_edit multi set remote.origin.fetch v
    cfg_edit multi set remote.origin.url v2
    # add / unset / unset-all
    for l in plain messy multi noeol comments shared blanks; do
        cfg_edit $l add remote.origin.fetch '+refs/x:refs/y'
        cfg_edit $l add new.thing 1
        cfg_edit $l unset core.filemode
        cfg_edit $l unset core.bare
        cfg_edit $l unset remote.origin.url
        cfg_edit $l unset branch.main.merge
        cfg_edit $l unset branch.main.remote
        cfg_edit $l unset nothere.key
        cfg_edit $l unset-all remote.origin.fetch
        cfg_edit $l unset-all core.a
        cfg_edit $l unset-all core.b
        cfg_edit $l unset-all other.c
        cfg_edit $l unset-all last.d
        cfg_edit $l unset-all sec.x
        cfg_edit $l unset-all nothere.key
    done
    cfg_edit multi unset remote.origin.fetch
    cfg_edit multi unset x.one

    # the file API: replaces .git/config in place, leaves nothing beside it
    rdir="$cfx/repo"
    rm -rf "$rdir"
    git init -q "$rdir"
    cp "$cfx/plain.base" "$rdir/.git/config"
    "$WORK/t_config" repo-set "$rdir/.git" remote.origin.url https://new/url.git >/dev/null
    want=$(cd "$rdir" && git config --get remote.origin.url)
    left=$(ls "$rdir/.git" | grep -c 'config\.tmp' || true)
    if [ "$want" = "https://new/url.git" ] && [ "$left" = 0 ]; then
        note "config: file API set is read back by git, no temp file left"
    else
        bad "config: file API set" "git reads: $want; temp files: $left"
    fi
    (cd "$rdir" && git fsck --strict >/dev/null 2>&1) && note "config: repo fsck clean" || bad "config: repo fsck"
fi
