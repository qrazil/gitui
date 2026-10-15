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

Done: `status` (0.11.0), `log`, `show` and `diff` (0.12.0).

`1git status` is git's grammar and git's bytes: long form (branch, upstream
ahead/behind/diverged/gone, detached at/from, merge / cherry-pick / revert /
rebase sections, staged, unmerged, unstaged, untracked, ignored, the
footers), `-s/--short`, `-b/--branch`, `--porcelain[=v1|v2]`, `-z`,
`-u[<mode>]` / `--untracked-files`, `--ignored[=traditional|matching|no]`,
`--renames` / `--no-renames`, `--ahead-behind` / `--no-ahead-behind`,
`--show-stash`, `--long`, pathspecs (literal and glob), `-C <dir>`,
`-c name=value`, a subdirectory as the working directory, colour
(`color.status`, `color.ui`, `color.status.<slot>`, `NO_COLOR`, TTY
detection) with git's palette, and `status.short`, `status.branch`,
`status.showUntrackedFiles`, `status.showStash`, `status.renames`,
`status.aheadBehind`. `scripts/compare_status.sh` diffs it byte for byte
against `git status` on ~40 fixtures in ~20 forms each (`tests/test.sh` runs
it).

### log, show, diff (0.12.0)

The three commands are git's own spelling over a port of git's own
algorithms, read from git 2.49's source: `revision.c`'s walk (the date-ordered
list, `limit_list` with its slop, TREESAME history simplification, parent
rewriting, `sort_in_topological_order`), `graph.c`'s state machine, the
`log-tree.c` assembly of header, message and diff, `pretty.c`'s formats and
placeholders (padding, truncation, `%C`, `%+`/`%-`), `diff.c`'s headers,
hunks, colour, whitespace highlighting, stat arithmetic and summary, and
`diffcore-rename.c`'s exact / basename / similarity matching, plus the
`--follow` rules of `tree-diff.c`. Where the three agree with git they agree
to the byte, piped or not:

- `log`: default and `--oneline`, `--pretty=` / `--format=` (`oneline`,
  `short`, `medium`, `full`, `fuller`, `raw`, `reference`, prefixes of those
  names, `format:` and `tformat:`, and the placeholders `%H %h %T %t %P %p
  %an %aN %ae %aE %al %ad %aD %ar %at %ai %aI %as` and the `c` forms, `%s %f
  %b %B %d %D %e %m %n %% %xNN %G? %C(...) %Cred/green/blue/reset
  %C(auto)`, `%<(N[,trunc|ltrunc|mtrunc])`, `%>(N)`, `%>>(N)`, `%><(N)`, the
  `|` column forms, and the `+`, `-` and space modifiers), `--graph`
  (including crossing merges, octopus merges, `--first-parent`, `--all`,
  path-limited graphs with rewritten parents, and colour), `--decorate[=short
  | full | no]`, `-n` / `-<N>` / `--skip`, `--since` / `--until` / `--after`
  / `--before`, `--author`, `--committer`, `--grep` (with `-i`, `-E`, `-F`,
  `--invert-grep`, `--all-match`), `-S`, `--all`, `--branches`, `--tags`,
  `--remotes`, `--first-parent`, `--no-merges` / `--merges`,
  `--min-parents` / `--max-parents`, `--reverse`, `--topo-order`,
  `--no-walk`, revision ranges (`a..b`, `a...b`, `^a`, `--not`), paths with
  history simplification, `--follow` (renames and copies), `--date=default |
  iso | iso-strict | rfc | short | raw | unix | relative | format:<fmt>`,
  `--stat[=w,n,count]`, `--numstat`, `--shortstat`, `--name-only`,
  `--name-status`, `--raw`, `--summary`, `-p`, `-s`, `-U<n>`, `-w`, `-b`,
  `-M[<n>]`, `--no-renames`, `-R`, `--diff-filter`, `-z`, `--abbrev[=n]`,
  `--color[=when]`.
- `show`: commits (header, message, patch, any of the stat / name formats,
  `--format`, `-s`), annotated tags (and tags of tags, tags of trees), trees
  and blobs (also `rev:path`), several objects at once, pathspecs. A merge
  prints its header, the blank line and the stat formats against the first
  parent, as git does when no path differs from every parent.
- `diff`: working tree against index, `--cached` / `--staged`, `<rev>`,
  `<rev> <rev>`, `a..b`, `a...b`, `-- <paths>` (literal, glob, `:!` and
  `:(exclude)` magic), subdirectories as the working directory, every
  format and option of `log` above that applies, `--exit-code` and
  `--quiet`, binary file lines, mode changes, type changes (split into a
  deletion and an addition), `diff.renames`, `diff.noprefix`, `diff.context`,
  `diff.statNameWidth` / `diff.statGraphWidth`, `core.abbrev`,
  `color.diff` and `color.diff.<slot>`, `color.decorate.<slot>`,
  `log.date`, `log.decorate`, `log.abbrevCommit`, `format.pretty`.
- Colour is on for `--color=always`, `color.ui` / `color.diff` /
  `color.log`-style values and a terminal (`auto`). On a terminal with
  colour on, added and removed lines are also coloured by token class with
  the `syntax` library (`GITUI_SYNTAX=off`, `gitui.syntax` and `NO_COLOR`
  switch it off); piped output never is, so it stays git's bytes.

`scripts/compare_log.sh` (~1500 forms over 13 fixture histories),
`scripts/compare_diff.sh` (~1700 forms over the histories and eight
work-tree states) and `scripts/compare_show.sh` (~1500 forms) run real git
beside `1git` and compare stdout and the exit status; `tests/test.sh` runs
them. The fixtures cover linear and merged history, crossing merges, an
octopus, renames, copies, mode changes, symlinks, binary files, empty
commits and files, a 4000-line file, 70 files in one commit, tags of every
kind, CRLF, a missing final newline, names that need quoting, whitespace-only
changes and unrelated roots. They were also run against this project's own
repositories (`log --graph --all`, `-p`, `--stat`, `--follow`, `-w`, `-U0`)
with no difference.

Known divergences of `status`: object names are seven digits (git sizes the
abbreviation by object count; `core.abbrev` is not read); `status -v`
(the diff), `--column`, submodule summaries, `rebase-apply` / `am` state and
`bisect` state are not implemented; `--ignored=matching` is treated like
`traditional`; paths that are not UTF-8 are skipped (the library's `str`
paths); `.gitattributes` / `core.autocrlf` conversions are not applied when
deciding whether a file changed; `--color[=when]` is accepted though git's
`status` has no such flag.

Known divergences of `log`, `show` and `diff` (everything else listed above
matches; these do not):

- **Symlinks in the working tree** cannot be read: m31 v0.4.2's `fs` has no
  `readlink` (a later m31 does). A work-tree symlink is therefore taken to
  be what the index says, so `diff` does not show a retargeted symlink, or a
  file replaced by one, and `diff HEAD` shows the index's symlink. Symlinks
  in commits are read and shown correctly.
- **Merge diffs** (`-m`, `-c`, `--cc`, `--diff-merges`, and the combined
  `diff --cc` that `show` prints for a merge that changes a path against
  every parent) are not implemented: `-m`/`-c`/`--cc` are an error, and
  such a `show` prints the header and the stat formats only. `log` prints
  no diff for a merge, as git does by default.
- **`--word-diff`, `--color-words`, `--color-moved`, `-G`, `-O`, `-B`,
  `-C`, `--find-copies-harder`, `-L`, `--ignore-blank-lines`, `-I`,
  `--ignore-space-at-eol`, `--patience`, `--histogram`, `--minimal`**:
  error (`--patience` / `--histogram` / `--minimal` are accepted and use
  Myers with git's heuristics). Copy detection exists only inside
  `--follow`, where git turns it on.
- **Not in the walk**: `--full-history`, `--simplify-merges`,
  `--simplify-by-decoration`, `--ancestry-path`, `--sparse`, `--source`,
  `--left-right`, `--cherry-pick`, `--cherry-mark`, `--boundary`,
  `--children`, `--parents`, `-g` / `--reflog`, `--decorate-refs`,
  `log.excludeDecoration`, `log.showRoot=false`, `log.diffMerges`,
  `--show-signature`: an error where git accepts the option. `show` of a
  revision range or a `^rev` is an error too.
- **Dates**: only the zone stored in the commit is known, so `--date=local`
  and `human`, `default-local`, `%ad` with `local` print the commit's zone;
  `--since` / `--until` understand `YYYY-MM-DD[ HH:MM[:SS]][ +ZZZZ]`,
  `@<unix>`, bare unix times, `now`, `yesterday`, `today` and `N
  <unit>[s] ago` chains (not `last week`, `noon`, month names); dates
  without a time take the current time of day, as git does.
- **Not read**: `.mailmap`, notes (`refs/notes/commit` is not appended to
  the message), `i18n.logOutputEncoding` and commit `encoding` headers
  (messages are bytes and printed as they are), `%(trailers)`,
  `%(describe)`, `%w(...)` (printed literally, as git does for what it does
  not know), `.gitattributes` (diff drivers, `-diff`, `eol`, textconv,
  funcname patterns: the built-in funcname rule is used) and
  `core.whitespace` / `color.diff.whitespace` rules other than the default.
- **Abbreviations**: unique-prefix extension looks at loose and packed
  objects, and the starting length follows the packed object count like
  git's; a repository with alternates or a multi-pack-index may differ.
- **Terminal**: there is no pager; `log` and `show` write to the terminal
  directly. `--stat` uses `COLUMNS` or the terminal's width, 80 when there
  is neither.
- **Performance**: every object read opens the pack files again (the
  library's read is stateless), so path-limited history of a repository with
  a pack of many megabytes is slow: ~4 ms per commit for an 8 MB pack.
- `NO_COLOR` switches colour off under `auto`, as `status` does; git itself
  ignores it.

## Order

1. Read side, git spelling: ~~`log`~~ ~~`show`~~ ~~`diff`~~ ~~`status`~~ (done) `blame` `cat-file`
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
