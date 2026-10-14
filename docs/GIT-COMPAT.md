# 1git: a drop-in git

Goal (the owner, 2026-10-14): "a perfect copy of git", usable day to day, so
that `1git` can stand where `git` stands. Today it is a read-only plumbing
client (`cat-file`, `ls-tree`, `log`, `rev-parse`, `refs`) in `lib/args`'
grammar (`1git -log`), which no muscle memory transfers to.

## Decisions

- **Spelling is git's own** (`1git log`, `1git commit -m x`, `1git rev-parse
  --short HEAD`). A drop-in cannot ask for `-log`. `lib/args` stays for our
  own tools; `1git` gets a small git-grammar parser (subcommand, short and
  long options, `--` and `-C <dir>`, `-c k=v`, aliases from config).
- **Behaviour is pinned by the oracle**: every command ships with a
  `scripts/compare.sh` case that runs real git beside it and diffs stdout,
  stderr class and exit status, plus the repository state afterwards (`fsck
  --strict`, refs, index).
- **Library first.** A command is a thin front end on `core/`, `diff/`,
  `net/`; most of the library exists already (the TUI uses it).

## Status

Done: `status` (0.11.0). `1git status` is git's grammar and git's bytes:
long form (branch, upstream ahead/behind/diverged/gone, detached
at/from, merge / cherry-pick / revert / rebase sections, staged,
unmerged, unstaged, untracked, ignored, the footers), `-s/--short`,
`-b/--branch`, `--porcelain[=v1|v2]`, `-z`, `-u[<mode>]` / `--untracked-files`,
`--ignored[=traditional|matching|no]`, `--renames` / `--no-renames`,
`--ahead-behind` / `--no-ahead-behind`, `--show-stash`, `--long`, pathspecs
(literal and glob), `-C <dir>`, `-c name=value`, a subdirectory as the
working directory, colour (`color.status`, `color.ui`, `color.status.<slot>`,
`NO_COLOR`, TTY detection) with git's palette, and `status.short`,
`status.branch`, `status.showUntrackedFiles`, `status.showStash`,
`status.renames`, `status.aheadBehind`.
`scripts/compare_status.sh` diffs it byte for byte against `git status`
on ~40 fixtures in ~20 forms each (`tests/test.sh` runs it).

Known divergences: object names are seven digits (git sizes the
abbreviation by object count; `core.abbrev` is not read); `status -v`
(the diff), `--column`, submodule summaries, `rebase-apply` / `am` state and
`bisect` state are not implemented; `--ignored=matching` is treated like
`traditional`; paths that are not UTF-8 are skipped (the library's `str`
paths); `.gitattributes` / `core.autocrlf` conversions are not applied when
deciding whether a file changed; `--color[=when]` is accepted though git's
`status` has no such flag.

## Order

1. Read side, git spelling: `log` `show` `diff` ~~`status`~~ (done) `blame` `cat-file`
   `ls-tree` `ls-files` `rev-parse` `rev-list` `branch` `tag` `describe`
   `shortlog` `grep` `config`.
2. Write side: `add` `rm` `mv` `restore` `reset` `commit` `checkout`
   `switch` `branch -d/-m` `tag -a` `stash` `cherry-pick` `revert` `merge`
   `rebase` (non-interactive first).
3. Network: `clone` `fetch` `pull` `push` `remote` (HTTP(S) smart protocol
   exists; ssh when m31 grows a client).
4. The long tail: hooks, `.gitattributes`, filters, worktrees, submodules,
   `gc`/`repack`, `bisect`, `format-patch`/`am`.

Not promised: porting git's own test suite wholesale (it is the north star:
`t/` scripts run against `1git` give the honest score), and anything that
needs a feature m31 does not have (stop and discuss).
