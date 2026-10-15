#!/usr/bin/env bash
# Fixture repositories for compare_log.sh, compare_show.sh and compare_diff.sh,
# built from scratch with fixed identities and dates so that a run is the same
# byte for byte on every machine. Source this file; it defines `build_all
# <workdir>`, which creates one repository per scenario under <workdir>:
#
#   linear     six commits on one branch, multi-line messages, a tab in one
#   merges     a branch merged twice, an octopus merge, a fast-forward
#   cross      crossing merges for --graph: criss-cross, nested, long-lived
#   renames    renames with and without edits, a directory move, a copy
#   modes      chmod +x, symlinks added, changed and replaced by a file
#   binary     binary files added, changed and removed
#   empty      an empty commit, empty files added and removed, a root commit
#   large      a 4000-line file with scattered edits, 70 files in one commit
#   tags       lightweight and annotated tags, a tag of a tag, remote refs
#   crlf       CRLF files, mixed endings, a file that loses its final newline
#   unicode    names with spaces, quotes, tabs and non-ASCII letters
#   space      whitespace-only changes for -w and -b
#   orphan     two unrelated roots merged
#   links      symlinks to files, directories, nothing; retargeted; merged
#
# Every commit is made by `commit_at`, which advances a clock by 1 hour.

export LC_ALL=C TZ=UTC
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Ada Author" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Cy Committer" GIT_COMMITTER_EMAIL="cy@example.org"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE NO_COLOR

CLOCK=1700000000

g() { git -c init.defaultBranch=main -c advice.detachedHead=false -c core.abbrev=7 "$@"; }

tick() {
    CLOCK=$((CLOCK + 3600))
    export GIT_AUTHOR_DATE="$CLOCK +0000" GIT_COMMITTER_DATE="$CLOCK +0000"
}

# commit_at <message...>: commit what is staged, one hour after the last
commit_at() {
    tick
    g commit -q --allow-empty -m "$1" "${@:2}"
}

# commit_zone <offset> <message>: author in another zone
commit_zone() {
    tick
    local when="$CLOCK $1"
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" g commit -q --allow-empty -m "$2"
}

# merge_at <message> <branch...>
merge_at() {
    tick
    local msg=$1
    shift
    g merge -q --no-ff -m "$msg" "$@" > /dev/null
}

new_repo() {
    local dir=$1
    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir" || exit 1
    g init -q .
}

fx_linear() {
    new_repo "$1/linear"
    printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\n' > a.txt
    printf 'one\n' > b.txt
    mkdir -p src
    printf 'int main(void)\n{\n    return 0;\n}\n' > src/main.c
    g add -A
    commit_at "first commit"
    printf 'alpha\nbeta\ngamma\nDELTA\nepsilon\nzeta\neta\ntheta\niota\nkappa\n' > a.txt
    g add -A
    commit_at "change delta

A longer body with several lines.
It explains the change in detail.

Signed-off-by: Ada Author <ada@example.com>"
    printf 'one\ntwo\n' > b.txt
    printf 'int main(void)\n{\n    puts("hi");\n    return 0;\n}\n' > src/main.c
    g add -A
    commit_at "second file and main

	a tab-indented line in the body
    four spaces in the body"
    printf 'new file\n' > c.txt
    g add -A
    commit_at "add c.txt"
    g rm -q b.txt
    commit_at "remove b.txt"
    printf 'alpha\nbeta\ngamma\nDELTA\nepsilon\nZETA\neta\ntheta\niota\nkappa\nlambda\n' > a.txt
    g add -A
    commit_zone "+0530" "evening change in another zone"
}

fx_merges() {
    new_repo "$1/merges"
    printf 'base\n' > base.txt
    g add -A
    commit_at "base"
    g checkout -q -b feature
    printf 'feature 1\n' > f1.txt
    g add -A
    commit_at "feature: one"
    printf 'feature 2\n' > f2.txt
    g add -A
    commit_at "feature: two"
    g checkout -q main
    printf 'main 1\n' > m1.txt
    g add -A
    commit_at "main: one"
    merge_at "Merge branch 'feature'" feature
    g checkout -q -b topic
    printf 'topic\n' > t.txt
    g add -A
    commit_at "topic: one"
    g checkout -q main
    printf 'main 2\n' > m2.txt
    g add -A
    commit_at "main: two"
    g checkout -q -b other
    printf 'other\n' > o.txt
    g add -A
    commit_at "other: one"
    g checkout -q main
    merge_at "Merge topic and other (octopus)" topic other
    printf 'main 3\n' > m3.txt
    g add -A
    commit_at "main: three"
}

fx_cross() {
    new_repo "$1/cross"
    printf 'r\n' > r.txt
    g add -A
    commit_at "root"
    g checkout -q -b a
    printf 'a1\n' > a1.txt
    g add -A
    commit_at "a1"
    g checkout -q main
    g checkout -q -b b
    printf 'b1\n' > b1.txt
    g add -A
    commit_at "b1"
    g checkout -q a
    printf 'a2\n' > a2.txt
    g add -A
    commit_at "a2"
    g checkout -q b
    printf 'b2\n' > b2.txt
    g add -A
    commit_at "b2"
    # a merges b at b1, b merges a at a1: crossing merges
    g checkout -q a
    merge_at "a merges b1" b~1
    g checkout -q b
    merge_at "b merges a1" a~1
    g checkout -q main
    printf 'm1\n' > m1.txt
    g add -A
    commit_at "m1"
    merge_at "main merges a" a
    printf 'm2\n' > m2.txt
    g add -A
    commit_at "m2"
    merge_at "main merges b" b
    g checkout -q -b long
    printf 'l1\n' > l1.txt
    g add -A
    commit_at "long 1"
    g checkout -q main
    printf 'm3\n' > m3.txt
    g add -A
    commit_at "m3"
    g checkout -q long
    printf 'l2\n' > l2.txt
    g add -A
    commit_at "long 2"
    g checkout -q main
    printf 'm4\n' > m4.txt
    g add -A
    commit_at "m4"
    merge_at "main merges long" long
}

fx_renames() {
    new_repo "$1/renames"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        printf 'line %s of the original\n' "$i"
    done > doc.txt
    printf 'same\ncontent\nhere\nfor\nrename\ntest\nmore\nlines\n' > same.txt
    mkdir -p dir/sub
    printf 'file one\nin dir\n' > dir/one.txt
    printf 'file two\nin dir\nwith more\n' > dir/two.txt
    printf 'deep\n' > dir/sub/deep.txt
    printf 'copy source\ncopy source\ncopy source\n' > src.txt
    g add -A
    commit_at "initial"
    g mv doc.txt document.txt
    g mv same.txt renamed-same.txt
    g mv dir moved
    g add -A
    commit_at "pure renames"
    printf 'line 1 of the original\nline 2 changed\nline 3 of the original\nline 4 of the original\nline 5 of the original\nline 6 of the original\nline 7 of the original\nline 8 of the original\nline 9 of the original\nline 10 of the original\nline 11 of the original\nline 12 of the original\nextra line\n' > document.txt
    g mv document.txt docs.txt
    g add -A
    commit_at "rename with edits"
    g mv renamed-same.txt run.sh
    chmod +x run.sh
    g add -A
    commit_at "rename with mode change"
    cp src.txt copy.txt
    g add -A
    commit_at "copy of a file"
    g rm -q -f src.txt
    printf 'brand new\n' > fresh.txt
    g add -A
    commit_at "delete one and add one"
}

fx_modes() {
    new_repo "$1/modes"
    printf '#!/bin/sh\necho hi\n' > run.sh
    printf 'plain\n' > plain.txt
    ln -s plain.txt link
    g add -A
    commit_at "files and a symlink"
    chmod +x run.sh
    chmod +x plain.txt
    g add -A
    commit_at "chmod +x"
    rm link
    ln -s run.sh link
    g add -A
    commit_at "retarget the symlink"
    rm link
    printf 'now a file\n' > link
    g add -A
    commit_at "symlink becomes a file"
    rm plain.txt
    ln -s run.sh plain.txt
    g add -A
    commit_at "file becomes a symlink"
    chmod -x run.sh
    printf '#!/bin/sh\necho changed\n' > run.sh
    g add -A
    commit_at "mode and content together"
}

# symbolic links in history: to a file, to a directory, dangling, retargeted
# on one side of a merge, replaced by a file, and a conflicting retarget
# resolved by hand (a merge that is in neither parent)
fx_links() {
    new_repo "$1/links"
    mkdir sub
    printf 'real\n' > real.txt
    printf 'inner\n' > sub/i.txt
    ln -s real.txt link
    ln -s sub dirlink
    ln -s nowhere dangling
    ln -s real.txt becomes-file
    ln -s real.txt both
    ln -s 'with space' spaced
    g add -A
    commit_at "base with links"
    g checkout -q -b side
    rm link dirlink both
    ln -s sub/i.txt link
    ln -s real.txt dirlink
    ln -s side-target both
    ln -s dangling newlink
    g add -A
    commit_at "side retargets links"
    g checkout -q main
    rm dangling becomes-file both
    ln -s elsewhere dangling
    printf 'now a file\n' > becomes-file
    ln -s main-target both
    g add -A
    commit_at "main changes links"
    g merge -q side > /dev/null 2>&1
    rm -f both
    ln -s resolved-target both
    g add -A
    commit_at "merge side, resolving both"
}

fx_binary() {
    new_repo "$1/binary"
    printf 'text\n' > t.txt
    printf '\000\001\002binary\n' > b.bin
    head -c 3000 /dev/zero > zeros.bin
    g add -A
    commit_at "binary files"
    printf '\000\001\002binary changed\n' > b.bin
    printf 'text\nmore\n' > t.txt
    g add -A
    commit_at "binary changed"
    head -c 9000 /dev/zero > zeros.bin
    g add -A
    commit_at "bigger zeros"
    g rm -q b.bin
    commit_at "binary removed"
    printf 'now text\n' > b.bin
    g add -A
    commit_at "binary name reused for text"
}

fx_empty() {
    new_repo "$1/empty"
    commit_at "empty root commit"
    : > e.txt
    g add -A
    commit_at "empty file added"
    printf 'x\n' > e.txt
    g add -A
    commit_at "empty file gets content"
    commit_at "another empty commit"
    : > e.txt
    g add -A
    commit_at "file emptied"
    g rm -q e.txt
    commit_at "empty file removed"
}

fx_large() {
    new_repo "$1/large"
    local i
    for i in $(seq 1 4000); do
        printf 'line number %d of the big file\n' "$i"
    done > big.txt
    mkdir -p many
    for i in $(seq 1 70); do
        printf 'content of file %d\n' "$i" > "many/file-with-a-moderately-long-name-$i.txt"
    done
    g add -A
    commit_at "big file and many files"
    awk 'NR==10 || NR==500 || NR==2000 || NR==3990 { print "CHANGED " $0; next } NR==1500 { next } { print } NR==3000 { print "inserted after 3000" }' big.txt > big.new
    mv big.new big.txt
    for i in $(seq 1 70); do
        printf 'content of file %d\nmore\n' "$i" > "many/file-with-a-moderately-long-name-$i.txt"
    done
    g add -A
    commit_at "scattered edits"
    for i in $(seq 1 4000); do
        printf 'line %d\n' "$i"
    done > big2.txt
    g add -A
    commit_at "second big file"
}

fx_tags() {
    new_repo "$1/tags"
    printf 'one\n' > a.txt
    g add -A
    commit_at "one"
    g tag light
    printf 'two\n' > a.txt
    g add -A
    commit_at "two"
    tick
    g tag -a -m "annotated release one" v1.0
    printf 'three\n' > a.txt
    g add -A
    commit_at "three"
    tick
    g -c advice.nestedTag=false tag -a -m "tag of a tag" v1.0-final v1.0
    g branch side
    g update-ref refs/remotes/origin/main HEAD
    g update-ref refs/remotes/origin/feature HEAD~1
    g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    g tag -a -m "a tag on a tree" tree-tag 'HEAD^{tree}'
    printf 'four\n' > a.txt
    g add -A
    commit_at "four"
}

fx_crlf() {
    new_repo "$1/crlf"
    printf 'one\r\ntwo\r\nthree\r\n' > dos.txt
    printf 'unix\nline\n' > unix.txt
    printf 'mixed\r\nendings\nhere\r\n' > mixed.txt
    printf 'no final newline' > noeol.txt
    g add -A
    commit_at "crlf and friends"
    printf 'one\r\nTWO\r\nthree\r\nfour\r\n' > dos.txt
    printf 'unix\nline\nadded\n' > unix.txt
    printf 'mixed\r\nendings\nhere\r\nmore\n' > mixed.txt
    printf 'no final newline\n' > noeol.txt
    g add -A
    commit_at "edits"
    printf 'no final newline\nsecond line without newline' > noeol.txt
    printf 'one\ntwo\nthree\nfour\n' > dos.txt
    g add -A
    commit_at "line endings converted"
}

fx_unicode() {
    new_repo "$1/unicode"
    printf 'a\n' > 'with space.txt'
    printf 'b\n' > 'caf\303\251.txt'
    printf 'c\n' > "tab	name.txt"
    printf 'd\n' > 'quote"d.txt'
    mkdir -p 'dir with space'
    printf 'e\n' > 'dir with space/inner.txt'
    g add -A
    commit_at "names that need quoting"
    printf 'a2\n' > 'with space.txt'
    printf 'b2\n' > 'caf\303\251.txt'
    printf 'e2\n' > 'dir with space/inner.txt'
    g add -A
    commit_at "change them"
    g mv 'with space.txt' 'spaced name.txt'
    commit_at "rename a spaced name"
}

fx_space() {
    new_repo "$1/space"
    printf 'int f(int a)\n{\n    return a + 1;\n}\n\nint g(void)\n{\n  return 2;\n}\n' > code.c
    printf 'one two\nthree  four\n  five\n' > words.txt
    g add -A
    commit_at "base"
    printf 'int f(int a)\n{\n\treturn a + 1;\n}\n\nint g(void)\n{\n  return  2;\n}\n' > code.c
    printf 'one  two\nthree four\n five\n' > words.txt
    g add -A
    commit_at "whitespace only"
    printf 'int f(int a)\n{\n\treturn a + 2;  \n}\n\nint g(void)\n{\n  return  2;\n}\n\n\n' > code.c
    printf 'one  two \nthree four\n five\nsix\n' > words.txt
    g add -A
    commit_at "whitespace and content"
}

fx_orphan() {
    new_repo "$1/orphan"
    printf 'first root\n' > one.txt
    g add -A
    commit_at "first root"
    g checkout -q --orphan second
    g rm -q -rf .
    printf 'second root\n' > two.txt
    g add -A
    commit_at "second root"
    g checkout -q main
    tick
    g merge -q --allow-unrelated-histories --no-ff -m "merge unrelated histories" second > /dev/null
}

# a scenario with the work tree dirty, for `diff` without a revision
fx_dirty() {
    new_repo "$1/dirty"
    printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > a.txt
    printf 'bee\n' > b.txt
    printf '#!/bin/sh\n' > run.sh
    chmod +x run.sh
    mkdir -p dir
    printf 'cee\n' > dir/c.txt
    printf '\000bin\n' > bin.dat
    ln -s a.txt lnk
    g add -A
    commit_at "base"
    printf 'one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n' > a.txt
    printf 'bee\n  trailing  \n' > b.txt
    chmod -x run.sh
    printf 'cee changed\n' > dir/c.txt
    printf '\000bin changed\n' > bin.dat
    rm b.txt
    printf 'untracked\n' > untracked.txt
    # one staged and then edited again
    printf 'staged\n' > s.txt
    g add s.txt
    printf 'staged\nand more\n' > s.txt
    printf 'new in index\n' > n.txt
    g add n.txt
}

build_all() {
    local base=$1
    mkdir -p "$base"
    for f in linear merges cross renames modes binary empty large tags crlf unicode space orphan links dirty; do
        CLOCK=1700000000
        ( "fx_$f" "$base" ) || { echo "fixture $f failed" >&2; return 1; }
    done
}
