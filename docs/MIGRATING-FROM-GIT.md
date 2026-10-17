# Migrating from git to 1git

`1git -migrate 'git log --oneline -n 5'` prints the line for you. For one
release (0.24.0) `1git log --oneline -n 5` still runs, with a warning that
prints the same line; the shim goes in 0.27.0. The grammar is in `CLI.md`: one
dash is a command, two dashes an option, anything else data; paths after a
revision are `--path`.

| git | 1git |
|---|---|
| `git -C dir CMD` | `1git --dir dir -CMD` |
| `git -c k=v CMD` | `1git --config k=v -CMD` |
| `git status -sb` | `1git -status --format short --branch` |
| `git status --porcelain=v2 -z` | `1git -status --format porcelain2 --nul` |
| `git status -uall` / `--ignored` | `-status --untracked all` / `--ignored traditional` |
| `git log --oneline -n 5` | `1git -log --oneline --max 5` |
| `git log A..B -- p q` | `1git -log A..B --path p q` |
| `git log --author=x --since=1.week -S txt` | `1git -log --author x --since 1.week --touches txt` |
| `git log --pretty=format:%h` / `--decorate=full` | `-log --format format:%h` / `--decorate full` |
| `git log --no-merges` / `--merges` | `-log --merges exclude` / `--merges only` |
| `git log -p -c` / `--cc` / `-m` / `--first-parent` diff | `-log --patch --merge-diff combined` / `dense` / `separate` / `first-parent` |
| `git show REV:path` | `1git -show REV:path` |
| `git diff --cached A B -- p` | `1git -diff --staged A B --path p` |
| `git diff -U5 -w --no-renames` | `1git -diff --context 5 --ignore-all-space --renames off` |
| `git diff --exit-code` / `-q` | `1git -diff --exit-code` / `--quiet` |
| `git add -A` / `-u` / `-p` | `1git -add --all` / `--update` / `--patch` |
| `git add --chmod=+x f` | `1git -add --executable on f` |
| `git rm --cached -r d` / `git mv a b` | `1git -remove --keep-files --recursive d` / `-move a b` |
| `git commit -am m` | `1git -commit --all --message m` |
| `git commit -m a -m b` | `1git -commit --message a b` |
| `git commit --amend --no-edit` | `1git -commit --amend --edit off` |
| `git commit --no-verify` / `-s` | `-commit --skip-hooks` / `--signoff` |
| `git commit -m x -- p` | `1git -commit --message x --path p` |
| `git switch b` / `git checkout b` | `1git -switch b` |
| `git switch -c n start` / `git checkout -b n start` | `1git -switch --create n --from start` |
| `git switch -f b` / `--detach R` | `-switch --discard-changes b` / `--detach R` |
| `git checkout R -- f` / `git checkout -- f` | `1git -restore --from R f` / `-restore f` |
| `git restore --staged f` / `git reset f` | `1git -restore --staged f` |
| `git restore -p f` / `git checkout -p` | `1git -restore --patch f` |
| `git reset --hard R` | `1git -reset --mode hard R` |
| `git branch -vv` / `-a` / `--show-current` | `1git -branch --upstream` / `--all` / `--current` |
| `git branch n start` | `1git -branch --create n --from start` |
| `git branch -d a b` / `-D a` | `1git -branch --delete a b` / `--force-delete a` |
| `git branch -m old new` / `-u origin/x` | `1git -branch --rename old new` / `--set-upstream origin/x` |
| `git branch --contains X --no-merged Y` | `1git -branch --contains X --unmerged Y` |
| `git tag -a v1 -m msg R` | `1git -tag --create v1 --from R --message msg` |
| `git tag -l 'v*' -n2` | `1git -tag 'v*' --lines 2` |
| `git tag -d v1` | `1git -tag --delete v1` |
| `git stash push -m x -u` | `1git -stash --message x --include-untracked` |
| `git stash list/show/apply/pop/drop/clear` | `1git -stash-list/-stash-show/-stash-apply/-stash-pop/-stash-drop/-stash-clear` |
| `git stash apply --index` | `1git -stash-apply --restore-index` |
| `git merge --no-ff -m m B` | `1git -merge B --fast-forward never --message m` |
| `git merge --ff-only` / `--no-commit` / `-X theirs` | `-merge B --fast-forward only` / `--stage-only` / `--prefer theirs` |
| `git merge --abort` / `--continue` | `1git -merge --abort` / `--continue` |
| `git rebase -i --onto X U B` | `1git -rebase U B --interactive --onto X` |
| `git rebase --autostash -x cmd` / `-f` | `-rebase --autostash --exec cmd` / `--replay` |
| `git cherry-pick -x -n A B` | `1git -cherry-pick A B --record-origin --stage-only` |
| `git revert --no-edit R` / `-m 1` | `1git -revert R --edit off` / `--mainline 1` |
| `git clean -fdx` / `-n` / `-ffd` | `1git -clean --force --directories --ignored also` / `--dry-run` / `--force --nested --directories` |
| `git worktree add -b n p start` | `1git -worktree-add p --from start --branch n` |
| `git worktree list/remove/prune` | `1git -worktree` / `-worktree-remove p` / `-worktree-prune` |
| `git clone -b B --depth 1 --bare URL d` | `1git -clone URL d --branch B --depth 1 --bare` |
| `git init -b main` | `1git -init --branch main` |
| `git fetch --all -p -t` | `1git -fetch --all --prune --tags` |
| `git fetch origin pull/12/head:pr-12` | `1git -fetch origin --pull-request 12` (the branch is `pr/12`) |
| `git pull --rebase` / `--ff-only` | `1git -pull --integrate rebase` / `ff-only` |
| `git push -u origin main` | `1git -push main --to origin --track` |
| `git push --force-with-lease` / `-f` | `1git -push --force` (with a lease) |
| `git push --force` (without one) | `1git -push --overwrite` |
| `git push origin --delete b` | `1git -push b --to origin --delete` |
| `git push origin HEAD:refs/for/main%topic=t` | `1git -push --to origin --for main --topic t` |
| `git push -o k=v` | `1git -push --option k=v` |
| `git remote -v` / `add n u` / `rm n` / `rename a b` | `1git -remote --verbose` / `-remote-add n u` / `-remote-remove n` / `-remote-rename a b` |
| `git remote set-url --push n u` / `get-url n` | `1git -remote-set-url n u --push` / `-remote-get-url n` |
| `git ls-remote --heads origin` | `1git -remote-refs origin --branches` |
| `git cat-file -t X` / `-s` / `-p` | `1git -cat-file X --type` / `--size` / `--pretty` |
| `git ls-tree X` / `git rev-parse X` / `git show-ref` | `1git -ls-tree X` / `-rev-parse X` / `-refs` |

Several commands on a line (`git add -A && git commit -m x && git push`):

```
1git -add --all -commit --message x -push
```

The line stops at the first command that fails, with exit status 1.

Exit status: git's 128, 129 and 2 are all 1 here; 2 is reserved for a command
line that was not understood. Not in 1git (see `GIT-COMPAT.md`): `checkout`,
`config`, `blame`, `describe`, `grep`, `reflog`, `shortlog`, `ls-files`,
`stash branch`, `add -i`, `commit -p`.
