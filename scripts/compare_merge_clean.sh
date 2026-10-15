# --- clean ---------------------------------------------------------------------------------

# untracked files and directories, ignored ones, an empty directory, a nested repository
fx_clean() {
    fx_base "$1"
    printf '*.log\nbuild/\n' > .gitignore
    git add .gitignore
    commit_at "ignore"
    echo u > untracked.txt
    echo l > debug.log
    mkdir -p newdir/sub emptydir build dir/nu
    echo n > newdir/n.txt
    echo s > newdir/sub/s.txt
    echo o > build/out.o
    echo x > dir/nu/x.txt
    echo y > dir/y.txt
    echo i > dir/ignored.log
    mkdir -p mixed
    echo m > mixed/m.txt
    echo l > mixed/m.log
    mkdir -p onlyign
    echo l > onlyign/a.log
    mkdir -p repo
    (cd repo && git init -q . && echo r > r.txt)
}

if wanted clean; then
    case_ "clean: needs -f" fx_clean ':' 'G clean'
    case_ "clean: dry run" fx_clean ':' 'G clean -n'
    case_ "clean: force" fx_clean ':' 'G clean -f'
    case_ "clean: -d" fx_clean ':' 'G clean -fd'
    case_ "clean: -d dry run" fx_clean ':' 'G clean -nd'
    case_ "clean: -x" fx_clean ':' 'G clean -fx'
    case_ "clean: -dx" fx_clean ':' 'G clean -fdx'
    case_ "clean: -dx dry run" fx_clean ':' 'G clean -ndx'
    case_ "clean: -X" fx_clean ':' 'G clean -fX'
    case_ "clean: -dX" fx_clean ':' 'G clean -fdX'
    case_ "clean: -dX dry run" fx_clean ':' 'G clean -ndX'
    case_ "clean: -ffd takes the nested repository" fx_clean ':' 'G clean -ffd'
    case_ "clean: -q" fx_clean ':' 'G clean -fdq'
    case_ "clean: one path" fx_clean ':' 'G clean -f untracked.txt'
    case_ "clean: a directory path" fx_clean ':' 'G clean -fd newdir'
    case_ "clean: a directory path without -d" fx_clean ':' 'G clean -f newdir'
    case_ "clean: a path inside an untracked directory" fx_clean ':' 'G clean -fd newdir/sub'
    case_ "clean: a glob" fx_clean ':' 'G clean -fdx "*.log"'
    case_ "clean: from a subdirectory" fx_clean ':' 'cd dir; G clean -fd'
    case_ "clean: from a subdirectory with a path" fx_clean ':' 'cd dir; G clean -fdx nu ../newdir'
    case_ "clean: requireForce=false" fx_clean 'git config clean.requireForce false' 'G clean'
    case_ "clean: from a subdirectory without -d" fx_clean ':' 'cd dir; G clean -f'
    case_ "clean: nothing to clean" fx_base ':' 'G clean -fd'
    case_ "clean: names that need quoting" fx_base 'echo a > "sp ace.new"; echo b > "ünï.new"' 'G clean -f; G clean -fd'
    case_ "clean: tracked files stay" fx_base 'echo m >> a.txt; echo u > u.txt' 'G clean -fd'
    case_ "clean: ignored files in a tracked directory" fx_clean ':' 'G clean -fx dir'
    case_ "clean: an untracked directory with an ignored file only" fx_clean ':' 'G clean -fd onlyign; G clean -fdx onlyign'
fi

# --- worktree ------------------------------------------------------------------------------

if wanted worktree; then
    case_ "worktree: add a new branch" fx_base ':' 'G worktree add -b wt1 wt/one; git -C wt/one status -sb; git branch'
    case_ "worktree: add an existing branch" fx_base ':' 'G worktree add wt/side side; G worktree list'
    case_ "worktree: add detached" fx_base ':' 'G worktree add --detach wt/d HEAD~1; git -C wt/d status -sb'
    case_ "worktree: add with a new directory name" fx_base ':' 'G worktree add wt/fresh; git branch'
    case_ "worktree: add a path that exists" fx_base 'mkdir wt; echo x > wt/f' 'G worktree add wt side'
    case_ "worktree: add a branch checked out elsewhere" fx_base ':' 'G worktree add wt/m main'
    case_ "worktree: add -q" fx_base ':' 'G worktree add -q wt/q -b q'
    case_ "worktree: add a commit-ish" fx_base ':' 'G worktree add wt/c HEAD~1; G worktree list'
    case_ "worktree: add -B" fx_base ':' 'G worktree add -B side wt/bb; git rev-parse side'
    case_ "worktree: add -b over an existing branch" fx_base ':' 'G worktree add -b side wt/e'
    case_ "worktree: same name twice" fx_base 'git worktree add -q wt/a/x -b wx1' 'G worktree add wt/b/x -b wx2; G worktree list'
    case_ "worktree: list" fx_base 'git worktree add -q wt/l -b wl' 'G worktree list'
    case_ "worktree: list --porcelain" fx_base 'git worktree add -q wt/l -b wl; git worktree add -q --detach wt/m HEAD~1' 'G worktree list --porcelain'
    case_ "worktree: list from a linked tree" fx_base 'git worktree add -q wt/l -b wl' 'cd wt/l; G worktree list'
    case_ "worktree: remove" fx_base 'git worktree add -q wt/r -b wr' 'G worktree remove wt/r; G worktree list'
    case_ "worktree: remove a dirty one" fx_base 'git worktree add -q wt/r -b wr; echo x >> wt/r/a.txt' 'G worktree remove wt/r; G worktree remove --force wt/r; G worktree list'
    case_ "worktree: remove an untracked-file one" fx_base 'git worktree add -q wt/r -b wr; echo x > wt/r/new' 'G worktree remove wt/r'
    case_ "worktree: remove the main tree" fx_base ':' 'G worktree remove .'
    case_ "worktree: remove something that is not one" fx_base 'mkdir nowt' 'G worktree remove nowt'
    case_ "worktree: prune" fx_base 'git worktree add -q wt/p -b wp; rm -rf wt/p' 'G worktree prune; G worktree list'
    case_ "worktree: prune dry run" fx_base 'git worktree add -q wt/p -b wp; rm -rf wt/p' 'G worktree prune -n -v; G worktree list'
    case_ "worktree: list shows a missing tree as prunable" fx_base 'git worktree add -q wt/p -b wp; rm -rf wt/p' 'G worktree list'
    case_ "worktree: a commit in the new tree is seen by the main one" fx_base 'git worktree add -q wt/c -b wc' 'cd wt/c; echo n > n.txt; git add n.txt; git commit -qm n; cd ../..; git log --oneline wc | head -2'
fi
