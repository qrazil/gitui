# Builds the repository `test_revparse.sh` asks questions of.
#
#   rp_fixture <dir> <sha1|sha256>
#
# <dir>/work is the repository, <dir>/origin.git and <dir>/second.git its
# remotes. Every date is fixed and every commit is a distinct second apart, so
# the same call builds the same history each time (the object names differ
# between the two hash algorithms, nothing else does).
#
# What is in it: a master with merges (two parents and an octopus) and a
# criss-cross (`ca` and `cb` have two merge bases); lightweight, annotated,
# tag-of-tag, tree and blob tags; a branch and a tag both called `v1`; a
# branch named like an abbreviated object name; upstreams (`origin`, `.`, a
# per-branch push remote); a reflog with checkouts (attached and detached),
# resets, a stash, a hand-written one whose oldest entry has a non-zero old
# value; packed refs overridden by loose ones, packed and loose objects side
# by side; a gitlink, an empty file, a name with a space, nested directories;
# commits with the same committer date; objects of different types whose names
# begin with the same four digits; and, last, a merge left conflicted, so the index has stages 1 to 3.

RP_T=1700000000
RP_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

rp_tick() {
    RP_T=$((RP_T + 100))
    export GIT_AUTHOR_DATE="$RP_T +0000" GIT_COMMITTER_DATE="$RP_T +0000"
}

# rp_c <message> [<file>] [<body>] -- append a line to <file> (default a.txt) and commit
rp_c() {
    local file=${2:-a.txt}
    mkdir -p "$(dirname "$file")"
    echo "$1" >>"$file"
    git add -A
    rp_tick
    if [ -n "${3:-}" ]; then
        git commit -q -m "$1" -m "$3"
    else
        git commit -q -m "$1"
    fi
}

rp_fixture() {
    local dir=$1 fmt=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    dir=$(cd "$dir" && pwd)
    (
        export GIT_AUTHOR_NAME=Rev_Tester GIT_AUTHOR_EMAIL=r@example.com \
               GIT_COMMITTER_NAME=Rev_Tester GIT_COMMITTER_EMAIL=r@example.com \
               GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        RP_T=1700000000
        git init -q --bare --object-format="$fmt" "$dir/origin.git"
        git init -q --bare --object-format="$fmt" "$dir/second.git"
        git init -q -b master --object-format="$fmt" "$dir/work"
        cd "$dir/work"
        git config advice.detachedHead false

        # history
        echo one >a.txt
        mkdir -p dir/sub
        echo b >dir/b.txt
        echo c >dir/sub/c.txt
        echo sp >"sp ace.txt"
        : >empty
        git add -A
        rp_tick
        git commit -q -m "c1 first"
        git tag first
        # a gitlink: a repository inside this one, whose commit is not stored here
        git init -q --object-format="$fmt" gl
        rp_tick
        (cd gl && git commit -q --allow-empty -m inner)
        git add gl 2>/dev/null
        rp_c "c2 second" a.txt "body line one

more text of c2"
        git tag light
        git tag -a v1 -m "release one"
        git tag -a v1v -m "tag of a tag" v1
        git checkout -q -b feature
        rp_c f1 f.txt
        rp_c f2 f.txt
        git checkout -q master
        rp_c c3 dir/b.txt
        c3id=$(git rev-parse HEAD)
        git branch side
        rp_c c4 a.txt
        c4id=$(git rev-parse HEAD)
        rp_tick
        git merge -q --no-ff -m "m1 merge feature" feature
        rp_c c5
        git checkout -q side
        rp_c s1 s.txt
        git checkout -q master
        rp_tick
        git merge -q --no-ff -m "m2 merge side" side
        git checkout -q -b o1 master
        rp_c o1 o1.txt
        git checkout -q -b o2 master
        rp_c o2 o2.txt
        git checkout -q master
        rp_c c6
        rp_tick
        git merge -q --no-ff -m "octopus o1 o2" o1 o2

        # criss-cross: ca and cb each merge the other's first commit
        git checkout -q -b base-cc master
        rp_c base dir/sub/c.txt
        git checkout -q -b ca base-cc
        rp_c a1 ca.txt
        git branch a1tip
        git checkout -q -b cb base-cc
        rp_c b1 cb.txt
        git branch b1tip
        git checkout -q ca
        rp_tick
        git merge -q --no-ff -m "am merge b1" b1tip
        git checkout -q cb
        rp_tick
        git merge -q --no-ff -m "bm merge a1" a1tip
        git checkout -q master

        # tags of a tree and a blob, names that clash
        git tag treetag 'master^{tree}'
        git tag blobtag "$(git rev-parse master:a.txt)"
        git tag ambig first
        git branch ambig "$c3id"
        git branch v1 "$c3id"
        git branch "$(git rev-parse --short=7 first)" "$c4id"

        # remotes, upstreams, push settings
        git remote add origin "$dir/origin.git"
        git remote add second "$dir/second.git"
        git push -q origin master feature side
        git push -q second master
        git fetch -q origin
        git remote set-head origin master >/dev/null
        git branch -q -u origin/master master
        git branch -q -u origin/feature feature
        git branch -q --set-upstream-to=master side
        git config branch.feature.pushRemote second
        git config branch.side.pushRemote origin

        # a reflog with attached and detached checkouts, and resets
        git checkout -q feature
        git checkout -q v1
        git checkout -q master
        git checkout -q --detach HEAD~1
        git checkout -q master
        git checkout -q side
        git checkout -q master
        rp_c c7
        git reset -q --hard HEAD~1
        git reset -q --hard ORIG_HEAD
        git fetch -q origin master

        # stashes
        echo wip >>a.txt
        git stash -q
        echo wip2 >>dir/b.txt
        git stash -q

        # a reflog written by hand; its oldest entry has a non-zero old value
        local c1 c2 c3
        c1=$(git rev-parse first) c2=$(git rev-parse light) c3=$(git rev-parse side)
        git branch synth "$c3"
        mkdir -p .git/logs/refs/heads
        printf '%s %s Rev_Tester <r@example.com> 1700000050 +0000\tbranch: one\n%s %s Rev_Tester <r@example.com> 1700000060 +0000\tbranch: two\n%s %s Rev_Tester <r@example.com> 1700000070 +0000\tbranch: three\n' \
            "$c1" "$c2" "$c2" "$c3" "$c3" "$c3" >.git/logs/refs/heads/synth

        # packed refs overridden by loose ones; packed objects beside loose ones
        git pack-refs --all
        git update-ref refs/heads/side "$(git rev-parse side~1)"
        git tag late master~1
        git repack -q -a -d
        rp_c c8
        rp_c c9 dir/sub/c.txt
        echo junk-not-a-ref >.git/junkfile
        git rev-parse master >.git/looseraw

        # equal committer dates: `:/` breaks the tie by ref name, a walk by parent order
        rp_tick
        git checkout -q -b tiea "$c3id"
        echo ta >t1.txt
        git add -A
        git commit -q -m "tie a"
        git checkout -q -b tieb "$c3id"
        echo tb >t2.txt
        git add -A
        git commit -q -m "tie b"
        git checkout -q -b tiec "$c3id"
        echo tc >t3.txt
        git add -A
        git commit -q -m "tie c"
        git checkout -q tiea
        rp_tick
        git merge -q --no-ff -m "tie merge" tieb tiec >/dev/null
        git checkout -q master

        # objects whose names begin like other objects'
        python3 "$RP_HERE/oracles/revparse_collide.py" . "$fmt"

        # last: a merge left conflicted
        git checkout -q -b conf1 master
        echo left >a.txt
        git add -A
        rp_tick
        git commit -q -m "conf1 left"
        git checkout -q -b conf2 master
        echo right >a.txt
        git add -A
        rp_tick
        git commit -q -m "conf2 right"
        git checkout -q conf1
        git merge -q conf2 >/dev/null 2>&1
        true
    )
}
