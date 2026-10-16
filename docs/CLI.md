# The command line of 1git and mgit

Decision (the owner, 2026-10-16): "I know 1git is a drop in replacement but
also wanted it to be new and clean. Drop in replacement is great but then why
would anyone use our 1git over git?" So 1git keeps what makes it useful, and
changes what you type.

**Kept (the contract, see `GIT-COMPAT.md`):** the repository format, the wire
protocols, the results of every command, and the bytes of the read commands'
default output when piped (`scripts/compare_*.sh` diff them against git 2.55).

**Changed:** the command line. It is Oro's `args` grammar exactly, written in
`lib/args`, instead of git's argv.

```
1git -log --max 5 --oneline
1git -add --all -commit --message "fix the parser" -push
1git -log --help
1git --help
```

## The grammar

| you type | it is |
|---|---|
| `-word` | a command: `-status`, `-log` (short: one letter, `-s`, `-l`) |
| `--word` | an option of the command on its left (short: two dashes and one letter, `--n`) |
| anything else | data: a path, a revision, a branch name, a URL, a value |

- Options before the first command belong to the program (`--dir`, `--config`,
  `--git-dir`, `--work-tree`).
- Several commands share a line and run in the order typed. The whole line is
  validated first, so a typo in the third is found before the first has run.
- `--help` is the only help, per command too: `1git -log --help`. There is no
  `-h`, no `help`, no `--`, no clustering (`--abc` is `--a --b --c`), no
  abbreviations (only suggested), no `--no-x`, no hidden options and no
  required options (what a command cannot run without is an operand).
- An option that takes a list is greedy (`--path a b c` takes every operand up
  to the next dash) and `--path a --path b` is refused. Put the operands
  first: `1git -log main --path src docs`.
- A value taken from the next word never starts with a dash. A message that
  does is `--message=-x`.
- `-` alone and `-5` are data: `1git -switch -`.
- Shell completion: `1git --completions bash|zsh|fish`, `mgit --completions ...`.

## Exit status

| status | meaning |
|---|---|
| 0 | every command did its work |
| 1 | a command failed; the commands after it on the line did not run |
| 2 | the line was not understood (a usage error, or a combination of options that makes no sense); nothing ran |

git's own codes (1, 2, 128, 129) are not passed through: a failed command is
1, and what failed is on standard error. `-diff --exit-code` and `--quiet`
exit 1 when there are differences, so `-diff --quiet -commit ...` stops there.
`-remote-refs --exit-code` exits 1 when nothing matches.

## Chaining

```
1git -add --all -commit --message "wip" -push        # stage, commit, push
1git -fetch -rebase origin/main -push --force        # update a branch
1git -switch --create fix --from main -commit --all --message "x"
```

A command that fails ends the line with exit status 1. `-status` or `-log`
chained at the end shows where you ended up.

## Principles

- **One way to do each thing.** git's `switch`, `checkout` and `restore`
  overlap; here `-switch` moves between branches, `-restore` puts files back,
  `-reset` moves a branch. `checkout` is gone.
- **Same word, same meaning, in every command:** `--all`, `--force` (with a
  lease: it refuses to overwrite what you have not seen), `--dry-run`,
  `--message`, `--author`, `--since`, `--until`, `--quiet`, `--verbose`,
  `--path` (limit to these paths), `--from` (start at this revision),
  `--edit on|off`, `--renames on|off`.
- **No `--no-x`.** A switch that undoes another is a value (`--edit off`,
  `--renames off`, `--decorate off`, `--executable off`) or its opposite named
  for what it does (`--skip-hooks`, `--skip-checkout`).
- **Destructive things are spelled out:** `--force-delete`, `--discard-changes`,
  `--overwrite` (plain force push), `-clean` refuses to run without `--force`
  or `--dry-run`, `-reset --mode hard`.
- **Forge workflows first:** `-push --to origin --track`, `-push --for main
  --topic x` (Gerrit), `-commit --change-id`, `-fetch --pull-request 12`,
  `-fetch --merge-request 3`.
- **Words, not letters, for the rare; letters for the daily:** commands have a
  one-letter short only where they are daily: `-s -l -d -a -c -w -b -t -m -r -f
  -p`.

## Program options

| option | |
|---|---|
| `--dir DIR` (`--C`) | run as if started in DIR (git `-C`) |
| `--config NAME=VALUE...` (`--c`) | configuration for this run (git `-c`) |
| `--git-dir DIR`, `--work-tree DIR` | as git's |
| `--version`, `--help`, `--completions SHELL` | |

## Commands

`1git --help` lists them; `1git -<command> --help` prints the options with
their types and defaults. Each command is also in `MIGRATING-FROM-GIT.md`
against the git command it replaces. The text below is the same as `--help`
(a test fails when they differ), generated into
[`CLI-REFERENCE.md`](CLI-REFERENCE.md).

| command | short | operands | what it does |
|---|---|---|---|
| `-status` | `-s` | `[PATH...]` | the state of the work tree and index |
| `-log` | `-l` | `[REV...]` `--path` | the history |
| `-show` | | `[OBJECT...]` `--path` | commits, tags, trees, files |
| `-diff` | `-d` | `[REV...]` `--path` | changes (`--staged`, ranges) |
| `-add` | `-a` | `[PATH...]` | stage |
| `-remove` | | `PATH...` | git `rm` |
| `-move` | | `SRC... DEST` | git `mv` |
| `-restore` | | `PATH...` | put files back (`--from`, `--staged`) |
| `-reset` | | `[REV]` | move the branch (`--mode soft\|mixed\|hard\|keep`) |
| `-commit` | `-c` | `--path` | commit (`--message`, `--amend`, `--change-id`) |
| `-switch` | `-w` | `[BRANCH]` | change branch (`--create NAME --from REV`) |
| `-branch` | `-b` | `[PATTERN...]` | list, `--create`, `--delete`, `--rename`, `--copy`, `--set-upstream` |
| `-tag` | `-t` | `[PATTERN...]` | list, `--create`, `--delete` |
| `-stash` `-stash-list` `-stash-show` `-stash-apply` `-stash-pop` `-stash-drop` `-stash-clear` | | `[STASH]` | the stack of stashes |
| `-merge` | `-m` | `BRANCH` | join (`--fast-forward only\|never\|allow`) |
| `-rebase` | `-r` | `[UPSTREAM] [BRANCH]` | replay |
| `-cherry-pick` `-revert` | | `REV...` | |
| `-clean` | | `[PATH...]` | delete untracked files (`--force` or `--dry-run`) |
| `-worktree` `-worktree-add` `-worktree-remove` `-worktree-prune` | | | |
| `-clone` `-init` | | | |
| `-fetch` | `-f` | `[REMOTE] [REFSPEC...]` | |
| `-pull` | | `[REMOTE] [BRANCH]` | `--integrate rebase\|merge\|ff-only` |
| `-push` | `-p` | `[REF...]` | `--to REMOTE`, `--for BRANCH` |
| `-remote` `-remote-add` `-remote-remove` `-remote-rename` `-remote-set-url` `-remote-get-url` `-remote-show` `-remote-prune` `-remote-set-head` `-remote-refs` | | | the remotes (`-remote-refs` is git `ls-remote`) |
| `-cat-file` `-ls-tree` `-rev-parse` `-refs` | | | plumbing |
| `-migrate` | | `[LINE]` | write a git command line the 1git way |

`-stash-*`, `-remote-*` and `-worktree-*` are separate commands because the
grammar nests commands one level only: what git writes `stash pop` is
`-stash-pop`.

### Operands and `--path`

git tells a revision from a path by looking in the repository, or by `--`.
Here nothing is guessed: revisions are operands, paths after `-log`, `-show`,
`-diff` and `-commit` are `--path PATH...`; commands whose operands are all
paths (`-add`, `-restore`, `-status`) take them directly.

### What is not in 1git

Dropped on purpose (the scope in `GIT-COMPAT.md` says why): `checkout` (use
`-switch` and `-restore`), `reset <paths>` (`-restore --staged`), `reset -p`,
`stash branch|create|store|save`, `branch -l`, `commit -p/-i/--interactive`,
`add -i/-e/-N`, `merge` of several heads, `--no-prefix` and `--src-prefix`,
`--pretty` as a second name for `--format`, `-U<n>` and `-<n>` as second
spellings of `--context` and `--max`, clustered switches (`-am`), `--abbrev-commit`,
`--ahead-behind`, signing options, `--porcelain` as a flag (it is `--format
porcelain`), `ls-files`, `config`, `blame`, `describe`, `grep`, `reflog`,
`shortlog` (not implemented yet; they are on the list in `GIT-COMPAT.md`).

## Forge workflows

```
# GitHub / GitLab: a branch for a pull request
1git -switch --create fix --from origin/main
1git -add --all -commit --message "fix" -push --to origin --track
1git -fetch --pull-request 12 -switch pr/12          # someone else's PR
1git -fetch --merge-request 3 -switch mr/3           # GitLab

# Gerrit: review a commit, with a Change-Id
1git -commit --all --change-id --message "fix"
1git -push --to gerrit --for main --topic fix

# keep a branch current
1git -pull --integrate rebase
1git -push --force                                   # with a lease
```

## The transition from git's spelling

For one release (0.24.0), a first word that is a git command still works:

```
$ 1git log --oneline -n 5
1git: git-style arguments are deprecated; use '1git -log --oneline --max 5' (see 1git --help)
```

The line is rewritten into the new grammar by the same table the parser is
made from (`core/GIT_clitable.m31`) and runs the new way, with the new exit
status. A line with an option 1git no longer has runs as git would, with git's
exit status, and a warning that says so. The shim is deleted in 0.25.0.
`1git -migrate 'git log --oneline -n 5'` prints the new line without running
anything; with `--nul` it reads git's words from standard input and writes
ours, which is how the oracle scripts call 1git (`scripts/lib_cli.sh`).

## mgit

```
mgit [PATH] [--mouse on|off]
mgit --help | --version | --completions bash|zsh|fish
```

`PATH` is where the repository's work tree is (default `.`). The mouse is on
unless `M31GIT_MOUSE=off` or `mgit.mouse = off` says otherwise; `--mouse`
overrides both. It is a value because Oro refuses `--no-mouse`. Exit status: 0
after a normal quit, 1 when there is no repository or no terminal, 2 for a
command line that is not understood.
