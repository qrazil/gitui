# 1git: a drop-in git

Goal (the owner, 2026-10-14): "a perfect copy of git", usable day to day, so
that `1git` can stand where `git` stands. Today it is a read-only plumbing
client (`cat-file`, `ls-tree`, `log`, `rev-parse`, `refs`) in `lib/args`'
grammar (`1git -log`), which no muscle memory transfers to.

## Scope: the essence, not the museum (owner's call, 2026-10-14)

`1git` replaces `git` for the work done against GitHub, GitLab and Gerrit,
the way helix and vim keep the core of vi and drop its history. A feature is
in when a developer on those forges uses it in a normal week. It is out when
it exists for a legacy workflow, a mailing list, a vanished tool or a mistake
git has kept for compatibility.

**In (tiers, in order):**

1. *Look*: `status` (done), `log` (graph, oneline, format, `--since`,
   `-S`/`-G`, `--author`, path limits), `show`, `diff` (staged, ranges,
   `--stat`, `--name-only`, `-w`, `-U`, rename detection), `blame`,
   `rev-parse`, `rev-list`, `ls-files`, `cat-file`, `describe`, `shortlog`,
   `grep`, `branch -vv`, `tag -l`, `reflog`, `config` (get/set/list),
   `remote -v`, colour and pager on a terminal.
2. *Change*: `add` (incl. `-p`), `rm`, `mv`, `restore`, `reset`, `commit`
   (`--amend`, `--fixup`, `-m`, `-F`, `--no-verify`, signing off), `switch`,
   `checkout`, `branch`, `tag`, `stash`, `cherry-pick`, `revert`, `merge`
   (`--ff-only`, `--no-ff`, `--squash`), `rebase` (`-i` through the editor,
   `--onto`, `--autosquash`, `--continue/--abort`), `clean`, `worktree`
   (add/list/remove).
3. *Talk to a forge*: `clone` (incl. `--depth`, `--filter=blob:none`),
   `fetch`, `pull` (`--rebase` default-minded), `push` (`--force-with-lease`,
   `-u`, `--tags`, push options `-o`, `refs/for/*` for Gerrit, `--delete`),
   `remote` management, credential helpers, HTTPS smart protocol v2 first,
   then SSH (needs the m31 ssh client, see m31's docs/ssh-decision.md).
4. *Forge details*: Gerrit `Change-Id` trailer on commit (what its hook
   does), GitHub/GitLab `refs/pull|merge-requests/*` fetchable by refspec,
   `.gitignore`, `.gitattributes` for `text`/`eol`/`linguist` only,
   `.mailmap`, `CODEOWNERS` untouched (forge-side), `git lfs` pointer files
   passed through, partial and shallow clones, commit signing (SSH, then
   GPG via the system tool).

**Out, on purpose** (not "later"; reopen only with a concrete user need):
`am`/`apply`/`format-patch`/`send-email`/`imap-send` (mailing-list flow),
`svn`/`cvs`/`p4` bridges, `archimport`, `filter-branch` (use `filter-repo`
ideas if ever), `grafts`, `replace`, `notes`, `bundle`, `daemon`/`http-
backend`/`shell`, `gitweb`, `instaweb`, `request-pull`, `whatchanged`,
dumb-HTTP transport, `.git/branches`, `remotes/` files, `rerere`, `bisect`
(later, if wanted), `submodule` and `subtree` (reconsider after tier 4),
git protocol v0/v1 where v2 is available, SHA-1 `core.compression`
tunables, `gc`/`repack` knobs (we pick sane defaults), `--porcelain` flags
nobody scripts against, abbreviated-option guessing, `git help` man pages
(`1git <cmd> --help` prints a short usage; the docs are this repo's).

**Deliberate departures from git's mistakes** (each documented where it
bites, behind no flag unless a script would break):
- one grammar: `-h/--help` everywhere, no `git help <cmd>` indirection;
- `checkout` stays for compatibility but `switch`/`restore` are the
  documented way; `reset` modes get plain-word aliases;
- push is `--force-with-lease` when `--force` is asked for (plain force
  needs `--force=unsafe`); `pull` never creates an accidental merge commit
  (`--ff-only` unless configured);
- errors name the next command to run, status hints are shortened;
- output is stable and machine-checkable: `--json` on `status`, `log`,
  `diff --stat` and `branch` (new, not a git feature).

Everything in tier 1 and 2 is oracle-tested against real `git` byte for
byte where we match git, and tested against a stated contract where we
deliberately differ.

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
