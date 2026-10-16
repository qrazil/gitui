# Sourced by the compare scripts: run 1git with git's own argument vector
# through the translation table in the program itself (`1git -migrate`), so the
# command line under test is the new grammar while the oracle (real git) is
# still asked in git's.
#
#   one_run <1git-binary> <git args...>
#
# runs `1git` with the rewritten line and leaves its stdout, stderr and exit
# status as they are. A git line that has no equivalent in the new command line
# (an option 1git dropped) goes through the transition shim instead, which runs
# it as git would and warns; those runs are counted in "$CLI_FALLBACKS" so a
# suite can say how many forms are not yet on the new grammar.
#
#   norm_rc <status>
#
# prints 0 for 0 and 1 for anything else: 1git's exit status is 0 or 1 (2 for a
# command line it refuses), where git's is 0, 1, 2, 128, 129 ...
#
# Works with bash 3.2 (macOS): no mapfile, no `${arr[@]}` on an empty array
# under `set -u`.

CLI_TR=${CLI_TR:-$(mktemp "${TMPDIR:-/tmp}/cli-tr.XXXXXX")}
CLI_FALLBACKS=${CLI_FALLBACKS:-$CLI_TR.fallbacks}
: > "$CLI_FALLBACKS"

one_run() {
    local bin=$1
    shift
    local words=() word
    if printf '%s\0' "$@" | "$bin" -migrate --nul > "$CLI_TR" 2> "$CLI_TR.err"; then
        while IFS= read -r -d '' word; do
            words[${#words[@]}]=$word
        done < "$CLI_TR"
        "$bin" ${words[@]+"${words[@]}"}
        return $?
    fi
    printf '%s\n' "$*" >> "$CLI_FALLBACKS"
    M31GIT_SHIM_QUIET=1 "$bin" "$@"
}

# side_run <bin> <git args...>: real git as it is, 1git through one_run.
side_run() {
    if [ "$1" = git ]; then
        shift
        git "$@"
    else
        one_run "$@"
    fi
}

norm_rc() {
    if [ "$1" -eq 0 ]; then echo 0; else echo 1; fi
}

fallback_count() {
    wc -l < "$CLI_FALLBACKS" | tr -d ' '
}
