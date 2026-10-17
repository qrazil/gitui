# 1git: git's repositories, protocols and output, a command line of its own

**The contract (0.24.0, the owner, 2026-10-16): repository, protocol and output
compatibility, not argv compatibility.** "I know 1git is a drop in replacement
but also wanted it to be new and clean ... drop in replacement is great but then
why would anyone use our 1git over git?" So:

- the **repository format** is git's: `git` and `1git` work on the same
  repository, in either order (`git fsck --strict` is clean after every 1git
  command, object ids are identical);
- the **wire protocols** are git's (smart HTTP v2, ssh), so every forge works;
- the **results** are git's: the same commits, trees, refs, index, reflog and
  state files for the same operation, and for the read commands the same bytes
  on a pipe (`scripts/compare_*.sh` run git 2.55 beside 1git and diff them);
- the **command line is not git's**: it is Oro's args grammar, designed for 1git
  (`CLI.md`). `git log --oneline -n 5` is `1git -log --oneline --max 5`
  (`MIGRATING-FROM-GIT.md`). git's own spelling still works in 0.24.0 behind a
  deprecation warning (the transition shim) and is removed in 0.25.0.

Everything below describes behaviour. Where it quotes options, they are **git's
spelling of the same thing**: translate with `1git -migrate 'git ...'` or the
table in `MIGRATING-FROM-GIT.md`. The oracle scripts do exactly that
(`scripts/lib_cli.sh`): they pass git's argv to `1git -migrate --nul`, run
1git with the new line, and compare the output with git's.

Exit status is 0, 1 (the command failed) or 2 (the line was not understood);
git's 128 and 129 are 1. Forms of git's that were dropped on purpose are listed
in `CLI.md` ("What is not in 1git"); the oracle runs them through the shim for
this release and the checks go with the shim.

Historical goal (2026-10-14), kept for the record: "a perfect copy of git",
usable day to day, so that `1git` can stand where `git` stands. It was a
read-only plumbing client in `lib/args`' grammar, then git's own grammar for the
porcelain; 0.24.0 settled on one grammar, the clean one, with git's results.

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
- one grammar (Oro's): `--help` everywhere (no `-h`, no `git help <cmd>`),
  one dash a command, two a option, several commands on a line;
- no `checkout`: `-switch` for branches, `-restore` for files; `-reset --mode`;
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

- **Spelling is Oro's** (0.24.0, superseding the 2026-10-14 decision that it be
  git's own): `1git -log --max 5`, `1git -commit --message x`. The command
  functions still take git's argv; `core/GIT_cli.m31` maps the parsed line onto
  it from one table (`core/GIT_clitable.m31`) and the same table rewrites git's
  argv into ours (`-migrate`, the transition shim).
- **Behaviour is pinned by the oracle**: every command ships with a
  `scripts/compare.sh` case that runs real git beside it and diffs stdout,
  stderr class and exit status, plus the repository state afterwards (`fsck
  --strict`, refs, index).
- **Library first.** A command is a thin front end on `core/`, `diff/`,
  `net/`; most of the library exists already (the TUI uses it).

## Status

Done: `status` (0.11.0), `log`, `show` and `diff` (0.12.0), `add`, `rm`, `mv`,
`restore`, `reset`, `commit`, `switch`, `checkout`, `branch` and `tag` (0.13.0),
`stash`, `cherry-pick`, `revert`, `merge`, `rebase`, `clean` and `worktree`
(0.16.0), `clone`, `fetch`, `pull`, `push`, `remote`, `ls-remote` and `init`
over HTTPS, HTTP and ssh (0.17.0, below).

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
  the `syntax` library (`M31GIT_SYNTAX=off`, `mgit.syntax` and `NO_COLOR`
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

### An extension: `--side-by-side` (0.22.0)

Git has no side-by-side diff, so this is **not** git's behaviour and never
happens unless asked: `1git diff`, `show` and `log` without the flag print
git's bytes, on a terminal or piped (`scripts/compare_*.sh` and
`tests/test_sbs.sh` check both).

- `--side-by-side` (`-y`, as in GNU diff; it implies `-p`) lays every file's
  patch out as two columns, old | new, with line numbers, a gutter marker per
  row, changed words marked inside paired lines, long lines wrapped per side,
  and each file's ruler naming both sides (`a/x (abc1234)` | `b/x (def5678)`
  from the `index` line). Commit headers, messages and `--stat` lines pass
  through unchanged; a rename, mode change, binary or submodule entry keeps its
  git lines; a combined diff (`diff --cc`) stays unified behind the line
  `(side-by-side: combined diff shown unified)`. A file that does not fit the
  width (under about 31 columns) stays unified too.
- `--width=N` sets the columns, else `$COLUMNS`, else the terminal's, else 130
  (GNU diff's default). `--no-side-by-side` undoes the flag.
- Colour follows git: `--color=always`, `color.ui` / `color.diff` or a terminal;
  the slots are `color.diff.meta`, `frag`, `old` and `new`, changed words in
  bold underline on top. No syntax colours, and `--word-diff` is ignored (the
  layout parses git's plain patch and paints it itself; the changed words of
  a paired line are marked by the layout instead).
- The output is held until the end (a diff is laid out whole), and a control
  character in a line is shown as its `U+2400` symbol. Output that is not
  valid UTF-8 as a whole is printed as git prints it, unlaid.
- mgit's split view is the same layout (`README.md`, "Side-by-side diff").

### Change commands, batch 1 (0.13.0)

`scripts/compare_write.sh` builds two identical repositories per case
(fixed identities and dates, same umask), runs real git on one and `1git`
on the other, and compares every call's stdout and exit status, then
`ls-files -s`, refs, HEAD, `status --porcelain=v2 -b`, reflog bytes, the
work tree (names, modes, content), `.git/config` and the unfinished-
operation files; `git fsck --strict` must be clean on ours. Commit and tree
ids come out identical because dates and identities are fixed. 486 cases:
happy paths and refusals (dirty switch, unmerged paths, non-ff, existing
branch, detached HEAD, empty repository, root commit, amend of a merge,
spaces and unicode, executable bit, CRLF, symlinks that exist in commits).

Forms that match git (stdout, status, repository state, object ids):

- `add`: paths, directories, globs, `.`, `-A`/`--all`, `-u`/`--update`,
  `-f`, `-n`, `-v`, `--chmod=+x|-x`, `--ignore-removal`, `--ignore-errors`,
  resolving conflicts, deletions, file/directory replacement, ignored-file
  refusal, `core.filemode`, from a subdirectory.
- `rm`: `--cached`, `-r`, `-f`, `-n`, `-q`, `--ignore-unmatch`, globs, the
  three refusals (staged, local, both) and their exit status.
- `mv`: file, directory, into a directory, several sources, `-f`, `-k`,
  `-n`, `-v`, every `bad source` / `destination exists` refusal.
- `restore`: `--staged`, `--worktree`, `--source`, `--ours`/`--theirs`,
  `--ignore-unmerged`, no-overlay deletion, unmerged refusal.
- `reset`: `--soft`, `--mixed`, `--hard`, `--keep`, `<tree-ish> -- paths`,
  `-q`, `ORIG_HEAD`, reflog lines (HEAD only when nothing moves), the
  `Unstaged changes after reset:` list, clearing merge state.
- `commit`: `-m` (several), `-F` (file, `-`), `-a`, `--amend`, `--no-edit`,
  `--allow-empty`, `--allow-empty-message`, `--author`, `--date` (raw, ISO,
  RFC 2822), `--reset-author`, `-s`, `--fixup`, `--squash`, `-C`, `-c`,
  `--cleanup`, `-e`, `commit <paths>` (`--only`, `-i`), `-n`/`--no-verify`,
  merges (`MERGE_HEAD`, `MERGE_MSG`) and cherry-picks (`CHERRY_PICK_HEAD`,
  the picked author), the editor (`GIT_EDITOR`, `core.editor`, `VISUAL`,
  `EDITOR`), `commit.template` (including "you did not edit the message"),
  `core.commentChar`, hooks (`pre-commit`, `prepare-commit-msg`,
  `commit-msg`, `post-commit`, `core.hooksPath`), the summary with
  `(root-commit)`, `Author:`, `Date:`, shortstat and rename summary, and
  the "nothing to commit" status report.
- **Gerrit**: with `gerrit.createChangeId=true`, or `--change-id` (not a
  git option), `commit` appends `Change-Id: I<40 hex>` as Gerrit's
  `commit-msg` hook does: the hash of a commit made of the new tree, the
  parent, both identities and the message without sign-off and comment
  lines; the trailer goes after a leading run of `Bug:`/`Issue:`/`Test:`...
  lines and before the other footer lines (`Signed-off-by:`), or at the end;
  left alone when a `Change-Id:` exists, on `fixup!`/`squash!` subjects and
  empty messages. The oracle is `scripts/gerrit-commit-msg.sh`, the 2.x-3.x
  hook reconstructed from memory of Gerrit's source: compare it with the
  hook your server serves before relying on id equality.
- `switch`: `<branch>`, `-c`, `-C`, `--detach`, `-`, `-f`/`--discard-
  changes`, `-t`/`--track`, the remote-branch guess, the refusals with the
  paths named, "cannot switch branch while merging", the local-changes list,
  the upstream report, and git's reflog lines (`checkout: moving from A to
  B`, `branch: Created from X`, `branch: Reset to X`).
- `checkout`: the above plus `-b`, `-B`, `checkout <tree-ish> [--] <paths>`,
  `checkout -- <paths>`, `--ours`/`--theirs`, `checkout HEAD`.
- `branch`: list (`-v`, `-vv`, `-a`, `-r`, patterns, `--show-current`,
  `--contains`, `--no-contains`, `--merged`, `--no-merged`, `--points-at`,
  `--sort=[-]refname`, `--format` atoms `refname[:short]`,
  `objectname[:short]`, `objecttype`, `HEAD`, `subject`, `upstream:short`),
  create (`-f`, `--track`, `--no-track`, automatic upstream from a remote
  branch), `-d`/`-D` (merged check, config and log removed), `-m`/`-M`,
  `-c`/`-C` (reflog and config follow), `-u`, `--unset-upstream`.
- `tag`: list (`-l`, patterns, `-n[<n>]`, `--sort=[-]refname|[-]version:
  refname`, `--contains`, `--no-contains`, `--merged`, `--no-merged`,
  `--points-at`, `--format`), lightweight, `-a`, `-m`, `-F`, editor, `-f`,
  `-d`.

Known divergences and gaps (everything else listed above matches):

- **Symlinks** are read with `fs.readlink` (m31 v0.4.5): a work-tree link
  is compared, staged (`add`, `add -A`/`-u`, `commit -a`), checked (`rm`,
  `restore`, `reset --hard`, `checkout`/`switch`) and written like git does,
  by its target text. Not done: a target that is not valid UTF-8 (`fs`
  gives a `str`), and the stat data of a link in the index entry are the
  target's length and a zero mtime (there is no `lstat`), so real git
  re-checks content of links once.
- `add -N` (intent-to-add), `-e`, `-i`, `--pathspec-from-file`;
  `restore -m`, `checkout -m`/`--orphan`, `switch -m`/`--orphan`,
  `reset --merge`, `commit --interactive`/`-p`/`--trailer`/`--short`/
  `--porcelain`, `commit -S`/`tag -s/-u/-v` (signing; `commit.gpgsign=true`
  refuses), `branch --edit-description`, `tag --column`: error (exit 129,
  or 128 for signing) naming the option.
- **Patch mode** (`add -p`, `reset -p [<tree-ish>]`, `restore -p [-S] [-W]
  [-s <tree-ish>]`, `checkout -p [<tree-ish>]`; 0.15.0) prints git's header,
  hunks, prompts (`(2/3) Stage this hunk (was: y) [y,n,q,a,d,k,K,j,J,g,/,s,
  e,p,P,?]? `), help and messages byte for byte, and applies the choices to
  the index and/or the work tree the way git's `apply` would. The keys are
  `y n q a d j J k K g / s p P ?`; an answer is a line of standard input (on a
  terminal Enter ends it, there is no single-key mode). Not done: `e` (edit a
  hunk) answers "Sorry, cannot edit this hunk"; the pager (`P` prints); the
  `g` list is not paged; `checkout -p HEAD|<tree>` where the index differs from
  the work tree prints nothing about the "Apply them to the worktree
  anyway?" question git asks; `--no-color`/`interactive.*` settings and
  `color.interactive` are not read. `scripts/compare_write.sh patch` runs 56
  piped dialogues against git and compares the output, the index, the work
  tree and the object ids.
- Paths that are not valid UTF-8 are carried through the index untouched
  but cannot be named; `commit` refuses when the index holds one.
- No `.gitattributes` or `core.autocrlf` conversion on `add`/checkout
  (CRLF content is stored and written as is); no sparse checkout, no
  submodules (a gitlink is kept, never entered), no linked-worktree checks
  (`branch -d` of a branch checked out elsewhere is not refused).
- The index is written without the cached-tree, untracked-cache and fsmonitor
  extensions and without inode/device/ownership data, so real git
  re-checks content of files once.
- Identities: a committer without name or email configured falls back to
  `$USER` / `<name>@localhost` as the library always has (git's hostname
  and GECOS lookup is not done); dates without a zone use UTC.
- Messages on stderr (hints, advice, `fatal:` text) are shorter than git's
  and not compared; stdout and exit status are.
- `branch`/`tag` listings: no colour, no `--column`, `--format` knows only
  the atoms above, `--sort` only the keys above.
- `commit` does not run `post-rewrite`/`post-checkout` hooks and sets only
  `GIT_DIR` for hooks.

### History-changing commands, batch 2 (0.16.0)

`scripts/compare_merge.sh` is `compare_write.sh`'s method (two identical
repositories, fixed identities and dates, real git on one and `1git` on the
other) for `stash`, `cherry-pick`, `revert`, `merge`, `rebase`, `clean` and
`worktree`: stdout and exit status of every call, then index with its
stages, refs, HEAD, `status --porcelain=v2`, reflog bytes, the work tree,
`.git/config`, and every state file (`MERGE_HEAD`, `MERGE_MSG`, `MERGE_MODE`,
`AUTO_MERGE`, `ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `SQUASH_MSG`,
`sequencer/*`, `rebase-merge/*`, `worktrees/*`); `fsck --strict` clean on
ours; object ids identical. ~300 cases against git 2.55, which is the oracle:
a conflict left by `1git` can be continued by `git` and the other way round.

Forms that match git (stdout, status, repository state, object ids):

- `stash`: `push` (`-u`, `-k`/`--keep-index`, `-m`, `-q`), `save <msg>`,
  `list`, `show` (stat by default, `-p`, `--name-only` and the other diff
  options, `-u`, `--only-untracked`, `stash.showStat`/`showPatch`/
  `showIncludeUntracked`), `apply`/`pop` (`--index`, `-q`, `stash@{n}` and
  `n`, the merge when HEAD moved, conflicts with `The stash entry is kept`,
  untracked files restored around one in the way), `drop`, `clear`,
  `branch`, `create`, `store`.
- `cherry-pick` and `revert`: commits, ranges (`A..B`, `^A`, several words,
  a commit named twice picked once), `-x`, `-n`, `-m <n>`, `-s`,
  `--allow-empty`, `--keep-redundant-commits`, `-X ours|theirs`, `--edit` /
  `--no-edit` (revert opens the editor by default only on a terminal, as
  git), `--continue`, `--skip`, `--abort`, `--quit`, the stop on an empty
  result, `-m` for merge commits, `merge.conflictStyle` merge, diff3 and
  zdiff3, reflog lines, the summary of each commit made.
- `merge`: fast-forward, `--no-ff`, `--ff-only`, `merge.ff`, `--squash`
  (`SQUASH_MSG` as git writes it), `--no-commit`, `-m` (several are
  paragraphs), `-F`, `--edit`/`--no-edit` (editor only on a terminal unless
  asked), `-s ours`, `-X ours|theirs`, `--allow-unrelated-histories`,
  `--abort`, `--continue` (it is `git commit`), `--quit`, up to date, dirty
  and staged refusals (exit 2), unrelated histories, criss-cross bases (the
  recursive virtual base, `merged common ancestors` in diff3), `MERGE_MSG`
  with its `# Conflicts:` block, `MERGE_MODE`, `AUTO_MERGE`, the stat and
  `create mode` lines.
  **Rename detection** as ort has it: exact and 50%-similar renames on
  either side, a renamed file merged under its new name with `HEAD:old`
  / `other:new` markers, rename/delete, rename/rename (1to2), rename on
  both sides to one name, and directory renames in `merge.directoryRenames=
  conflict` mode (a file added to a renamed directory moves with `CONFLICT
  (file location)`). `cherry-pick`, `revert`, `stash` and `rebase` use the
  same merge. `zdiff3` is git's zealous diff3.
- `rebase`: `<upstream> [<branch>]`, `--onto`, `--keep-base`, `--root`,
  `-i` through `GIT_SEQUENCE_EDITOR` / `sequence.editor` / the editor (all
  verbs of the merge backend: pick, reword, edit, squash, fixup, drop, exec,
  break), `--autosquash` (with and without `-i`, `rebase.autoSquash`),
  `--autostash` (`rebase.autoStash`), `-x`/`--exec`, `--force-rebase`,
  `--continue`, `--skip`, `--abort`, `--quit`, `--edit-todo`,
  `--show-current-patch`, up to date and fast-forward, the commits that
  become empty, `rebase-merge/*` (todo, backup with git 2.55's help, done,
  `patch`, ...), reflog lines, ORIG_HEAD, `status` while rebasing.
- `clean`: `-n`, `-f`, `-ff`, `-d`, `-x`, `-X`, `-q`, pathspecs and globs,
  from a subdirectory, `clean.requireForce`, nested repositories (kept
  unless `-ff`), empty directories, ignored-only directories.
- `worktree`: `add` (`-b`, `-B`, `--detach`, `-f`, `-q`, a branch, a
  commit-ish, the directory-named branch, unique names), `list` (and
  `--porcelain`, `prunable`), `remove` (`-f`), `prune` (`-n`, `-v`), with
  git's files under `.git/worktrees/<name>` and the `.git` file.

Known divergences and gaps (everything else listed above matches):

- **stash**: `push` with pathspecs, `-p`, `-S`, `-a`/`--all`,
  `--pathspec-from-file`, and options of `list` (`git log` options) are an
  error; a symlink in the work tree is neither stashed nor restored.
- **cherry-pick / revert**: `--ff`, `--empty=`, `--allow-empty-message`,
  `-S`, `--strategy`, `-X` other than `ours`/`theirs`, editing several
  commits (`--no-edit` is needed for ranges), a pick onto an unborn branch,
  `post-commit` and `prepare-commit-msg` hooks.
- **merge**: octopus (several heads), `--log`, `--autostash`, `--signoff`,
  `-s` other than `ort`, `recursive`, `resolve` (taken as ort) and `ours`,
  `-X` other than `ours`/`theirs` (`no-renames`, `renormalize`,
  `ignore-space-*`, `patience`, `find-renames=` are errors), merging into an
  unborn branch, `.gitattributes` merge drivers and `rerere`, the hooks
  (`pre-merge-commit`, `post-merge`), `merge.renameLimit`, rename/rename
  (2to1) and some rename/add layouts, directory renames below the nearest
  directory level or with ties. After a merge refused for local changes
  `AUTO_MERGE` is not written (git leaves a tree of what it had started).
- **rebase**: `--rebase-merges`, `--update-refs`, `--empty=`, `-s`/`-X`,
  `--signoff`, `--fork-point`, `--reapply-cherry-picks`, the apply backend,
  the `post-rewrite` hook and notes copying, and the `Rebasing (n/m)`
  progress on stderr. Commits upstream already has are found by a patch-id
  equivalent of git's, among the first 1000 of `head..upstream`.
- **clean**: `-i`, `-e <pattern>`, and git's `Would refuse to remove current
  working directory`.
- **worktree**: `lock`, `unlock`, `move`, `repair`, `--orphan`, `--track`,
  `list -v` annotations, the `post-checkout` hook.
- Messages on stderr (hints, advice, `fatal:` text, `Rebasing (n/m)`) are
  shorter than git's and not compared; stdout and exit status are. Where git
  prints a message on stdout (`Auto-merging`, `CONFLICT (...)`, `Updating`,
  the stat) 1git does too.

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

- **Merge diffs** follow git (0.15.0): `show <merge>` combines
  (`diff --cc`) by default; `-c`, `--cc`, `-m` (a header `commit X (from P)`
  and a diff per parent), `--first-parent` / `--dd` (a diff against the first
  parent), `--no-diff-merges`, `--diff-merges=<off|none|on|m|1|first-parent|
  separate|c|combined|cc|dense-combined>` and `log.diffMerges` work for
  `show` and `log`, with `-p`, `--stat`/`--numstat`/`--shortstat`/`--summary`
  (against the first parent, as git does), `--raw`, `--name-only` and
  `--name-status` (the `::100644 100644 100644 a b c MM<TAB>path` lines),
  `-U<n>`, `-w`/`-b`, `-z`, colour, `--abbrev`/`--full-index` and
  pathspecs. `git diff` of a conflicted merge prints `diff --cc` for a path
  with both stages (and `-c`/`--cc` explicitly), the `* Unmerged path` lines
  after them. Not done: `--remerge-diff`, `--combined-all-paths`,
  `--word-diff` of a combined diff, and a rename of the combined path is
  detected per parent with the same score as for a plain diff only.
- **`--word-diff-regex`, `--color-moved`, `-G`, `-O`, `-B`,
  `-C`, `--find-copies-harder`, `-L`, `--ignore-blank-lines`, `-I`,
  `--ignore-space-at-eol`, `--patience`, `--histogram`, `--minimal`**:
  error (`--word-diff[=plain|color|porcelain]` and `--color-words` work with
  the default word regex; `--patience` / `--histogram` / `--minimal` are accepted and use
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
- **Performance**: packs are read once per run through a cache
  (`GIT_gitstore`), so path-limited history of an 8 MB pack is ~0.3 s.
- `NO_COLOR` switches colour off under `auto`, as `status` does; git itself
  ignores it.

### Network commands (0.17.0)

`clone`, `fetch`, `pull`, `push`, `remote`, `ls-remote` and a minimal `init`,
in git's grammar. Transport: smart HTTP(S) with protocol v2 first
(`Git-Protocol: version=2`; `ls-refs` and `fetch` commands) and v0 when the
server answers v0 or `protocol.version=0|1` is set; `receive-pack` is v0 as
in git. ssh (`ssh://`, `git@host:path`, `~/.ssh/config` Host/HostName/User/
Port/IdentityFile) is v0 over m31's own ssh client: ed25519 OpenSSH keys, no
agent, no passphrases; `known_hosts` is strict (an unknown host is asked about
on the terminal only, a changed key is refused).
`scripts/compare_net.sh` (HTTP, 100 cases) and `scripts/compare_net_ssh.sh`
run every form below beside real git 2.55 and compare stdout, stderr, exit
status, refs, reflogs, config, `packed-refs`, `shallow`, `FETCH_HEAD`, the
object set, the index and the work tree, and the server's refs and `fsck`.

What matches git byte for byte (stdout, stderr, state):

- `fetch`: remotes by name or URL, refspecs (`+src:dst`, globs, short names,
  `tag <name>`), the opportunistic update of remote-tracking refs, auto-follow
  of tags in git's visiting order (`git`'s name hashmap), `--tags`,
  `--no-tags`, `remote.<n>.tagOpt`, `--prune`, `--depth`, `--unshallow`,
  `--all`, `-f`, `-q`, `-v`, `--dry-run`, `FETCH_HEAD` (for-merge flags),
  `refs/remotes/<n>/HEAD` (`followRemoteHEAD`), the `From` summary in git's
  columns, reflog messages (`fetch origin: storing head`, `fast-forward`,
  `forced-update`), `refusing to fetch into branch`, `fetch.unpackLimit`.
- `clone`: `-b` (branch or tag, with git's detached-HEAD advice), `--bare`,
  `--single-branch`, `--depth`, `-o`, `--no-tags`, `-n`, `-q`, `-c`, empty
  remotes, the destination checks, clean-up on failure; the config, the
  packed refs, `origin/HEAD` and the `clone: from <url>` reflogs as git
  writes them.
- `push`: `<remote> <refspec>...`, `src:dst`, `HEAD`, `+`, `:dst`/`--delete`,
  `--tags`, `--all`, `-u`/`push.autoSetupRemote`, `-o` push options,
  `--atomic`, `-n`, `-q`, `-v`, `push.default` (simple, current, upstream,
  matching), `remote.<n>.push`/`pushurl`, `pre-push` hook, `--force-with-lease`
  (`=ref`, `=ref:expect`), `Everything up-to-date`, `[new branch]`/`..`/`...`
  rows, rejection reasons (`non-fast-forward`, `fetch first`, `already exists`,
  `stale info`, `remote rejected`) and git's `hint:` blocks, `remote:` lines
  from the server's side-band (with git's trailing padding), tracking-ref
  update (`update by push`), Gerrit `refs/for/<branch>%topic=...,r=...`.
- `pull`: fetch, then `merge`/`rebase` (this program run again with
  `GIT_REFLOG_ACTION=pull ...`): fast-forward, up to date, `--ff-only`,
  `--rebase[=...]`, `--no-rebase`, `pull.rebase`, `pull.ff`,
  `branch.<n>.rebase`, `Merge branch 'x' of <url> [into <branch>]`, git's
  divergent-branches refusal and no-tracking-information messages.
- `remote`: list, `-v`, `add` (`-t`, `-m`, `-f`, `--tags`, `--no-tags`),
  `remove`/`rm`, `rename` (config, refs, reflogs, branch config), `set-url`
  (`--push`, `--add`, `--delete`), `get-url`, `show` (and `-n`), `prune`
  (`-n`), `set-head` (`-a`, `-d`).
- `ls-remote`: `--heads`/`--branches`, `--tags`, `--refs`, `--symref`,
  `--exit-code`, `--get-url`, `-q`, patterns, a named, implied or URL remote.
- Credentials, in git's order: userinfo of the URL, `~/.netrc`,
  `credential.helper` (`store` natively; `!cmd`, absolute paths and
  `git-credential-<name>` run with `get`/`store`/`erase`), `GIT_ASKPASS` /
  `core.askPass` / `SSH_ASKPASS`, the terminal (`/dev/tty`, echo off);
  `GIT_TERMINAL_PROMPT=0`; `approve` after success, `reject` after a refusal.
  The first request goes out without credentials and waits for the 401, as
  curl does. A secret is never printed.
- Pack handling: a pack is checksum-verified, then unpacked (< 100 objects)
  or kept with a version 2 `.idx`; thin packs (never requested) and deltas
  against local objects resolve; SHA-256 repositories exchange with SHA-256
  servers; `.git/shallow` makes the commit it names parentless for every
  command.

Deliberate departures, and gaps:

- `push --force`/`-f` and a leading `+` are a lease on the remote-tracking ref
  (`stale info` when the remote moved since the last fetch; a missing
  tracking ref means "must not exist"); `--force=unsafe` is git's plain force
  (this is the departure listed above, and the one place output differs).
- No progress meters: `no-progress` is always requested, `Rebasing (1/1)` is
  not printed by `rebase` (stderr only; `pull --rebase` therefore differs in
  that one stderr line), and the transfer is not interleaved with `remote:`
  lines (they are printed once the response is read).
- Negotiation is one round: all haves (at most 256 commits from the local
  refs, breadth first) and `done`. A pack can be larger than git's; never
  wrong. Thin packs are not requested.
- Not done: `--filter`/partial clone (needs lazy object fetch), submodules,
  `--mirror`, `--reference`, local-path and `git://` remotes, `file://`,
  `http.proxy`, `http.sslVerify=false` (certificates are always checked; roots
  from the system, `GIT_SSL_CAINFO`, `http.sslCAInfo`, `M31GIT_HTTP_CA_FILE`),
  client certificates, `credential.helper=cache`'s daemon (the helper program
  is run if present), `fetch.negotiationAlgorithm`, `push --follow-tags`,
  `--signed`, `push --mirror`/`--prune`, `remote update`/`set-branches`,
  `pull` of several heads (octopus), `--recurse-submodules`, `gc --auto`,
  bundle URIs, sideband progress on a terminal, ssh protocol v2 and ssh
  agent/passphrase keys, `ssh -o` options (only `~/.ssh/config`'s Host
  blocks; `GIT_SSH_COMMAND` is not used).
- A server that answers a pack with `Content-Length` over 32 MiB is refused by
  m31's `lib/net/http.m31` (`MAX_BODY`, applied to framing even for a
  streamed body); chunked answers, which git servers send, stream without a
  ceiling and are held in memory whole once received (a 40 MB clone takes
  ~40 s at `-O0`, a 21 MB repository 7 s at `-O2`). This is an m31 library
  limit, not worked around.
- `init` writes no templates (no sample hooks, `info/exclude`, `description`).
- The advertised user agent is `1git/0.25.0`.

## Case-insensitive and Unicode-normalizing volumes (0.19.0, 0.19.1)

`init` and `clone` probe the volume the way git's `create_default_files`
does (`setup.c`, git 2.55): `core.ignorecase = true` is written when
`.git/CoNfIg` answers for the `config` just written; on macOS also
`core.precomposeunicode`, `true` when a file created as U+00E4 can be opened
as `a` + U+0308, `false` when not (and not at all when the user's own
configuration already has the key). The keys go after `logallrefupdates` in
`[core]`, in that order, so `.git/config` is byte for byte git's (for SHA-256
the `[extensions]` section comes first, as in git). `core.symlinks` is not
probed.

With `core.ignorecase=true` the commands follow git's `dir.c`, `name-hash.c`,
`read-cache.c` and `unpack-trees.c`:

- names are folded the way git folds them: ASCII only (`strcasecmp`);
- `status`, `add`, `clean`, `stash -u`: a work-tree file whose whole path
  folds to an index path is that file, not an untracked one; a directory that
  folds to a directory of the index is walked, not collapsed to `dir/` (and
  `clean`/`stash -u` leave it standing); `.gitignore` patterns match folded;
- `add`: the directories of a new file take the spelling the index has
  (`add DIR/new.txt` stages `dir/new.txt`); a name that folds to an entry is
  that entry and, when the file already matches it, nothing is staged; a case
  variant of a tracked file is no news (no "ignored" hint);
- `mv a.txt A.txt` does not refuse "destination exists" for the same file
  under another case, and does not delete it first;
- `switch`, `checkout`, `reset --hard`, `merge`, `cherry-pick`, `revert`,
  `rebase`, `stash pop`: a work-tree file that only differs in case from a
  tracked path and whose size and mtime are the index entry's is the tracked
  file itself (git's `icase_exists`), so a merge that renames `a.txt` to
  `A.txt` does not report an untracked file in the way;
- the index keeps its entries' spelling: nothing renames an entry for a
  work-tree file's case;
- (0.19.1) a tracked file is "there" when `lstat` of the index spelling
  succeeds, as in git, not when `readdir` lists that spelling: on a real
  folding volume the old spelling of a file renamed `a.txt` -> `A.txt` still
  answers, so `status`, `add -A/-u`, `commit -a`, `checkout`/`restore`,
  `mv`, `stash` and `switch` show no phantom ` D a.txt`. A racily clean
  entry (size 0 in the index) whose stat data says it is the same file is
  compared by content;
- (0.19.1) `add` matches a literal pathspec case-folded against the
  untracked scan only (git scans from the directory the pathspec names and
  names the files in the pathspec's spelling: `add -v Dir/new.txt` says
  `add 'Dir/new.txt'`, then stages `dir/new.txt`); tracked paths are matched
  as typed, so `add B.TXT` does not stage a modified `b.txt`;
- (0.19.1) `mv -f a.txt B.TXT` onto another spelling lets `rename(2)` keep
  the name the volume has, as git does, instead of deleting the target first;
- (0.19.1) `stash` puts a path HEAD has and the index lacks back into the
  work-tree commit when the file is there (`update-index --add --remove`),
  with or without `core.ignorecase`.

With `core.precomposeunicode=true` (macOS only: elsewhere git does not
compile the conversion in, and the key is inert here too) every argument after
the subcommand, the directory the command runs in, and every name read from a
work-tree directory are converted to NFC (`text.unicode.nfc`).

Gaps: `core.ignorecase` and `core.precomposeunicode` are read from the
configuration files by the library layers (the merge, rebase, stash and
undo engines and `mgit`); `-c core.ignorecase=true` is honoured by `status`,
`add`, `mv`, `clean`, `switch`, `checkout` and `init`/`clone`
only. A case conflict between refs (`refs/heads/foo` and `refs/heads/Foo/bar`
with `ignorecase`), the "the following paths have collided" warning of a clone
onto a folding volume, and `git mv dir Dir` (which git itself refuses on such
a volume) are not reproduced. Not special-cased (and so as in a
case-sensitive git): a glob pathspec with a differently spelled directory
(`add 'DIR/*.txt'`) and a new untracked directory named by a variant
pathspec (`add NEWDIR/x` where the disk says `newdir`: git stages the
pathspec's spelling, 1git the disk's). No behaviour was left out for lack of a
real volume; the cases below are what pins them.

Tests: on macOS `scripts/compare_write.sh icase` and the `icase:` cases of
`scripts/compare_merge*.sh` run on the real APFS volume. On Linux (6.13+, with
unprivileged user namespaces) the same cases are run a second time on a real
folding volume: a tmpfs mounted `casefold` inside `unshare -Urm`, where lstat
and open of the other spelling succeed and readdir has one name, exactly as on
APFS (a case-only `rename(2)` keeps the old spelling there, so the fixtures
rename in two steps, `mvc`). Every Linux run also does the case-sensitive
run with the hard link standing in for the same file under another case.

## Order

1. Read side, git spelling: ~~`log`~~ ~~`show`~~ ~~`diff`~~ ~~`status`~~ (done) `blame` `cat-file`
   `ls-tree` `ls-files` `rev-parse` `rev-list` `branch` `tag` `describe`
   `shortlog` `grep` `config`.
2. Write side: ~~`add`~~ ~~`rm`~~ ~~`mv`~~ ~~`restore`~~ ~~`reset`~~ ~~`commit`~~
   ~~`checkout`~~ ~~`switch`~~ ~~`branch`~~ ~~`tag`~~ (done, 0.13.0) ~~`stash`~~
   ~~`cherry-pick`~~ ~~`revert`~~ ~~`merge`~~ ~~`rebase`~~ ~~`clean`~~ ~~`worktree`~~ (done, 0.16.0).
3. Network: ~~`clone`~~ ~~`fetch`~~ ~~`pull`~~ ~~`push`~~ ~~`remote`~~ ~~`ls-remote`~~
   (done, 0.17.0: HTTP(S) smart protocol v2 with a v0 fallback, ssh v0).
4. The long tail: hooks, `.gitattributes`, filters, worktrees, submodules,
   `gc`/`repack`, `bisect`, `format-patch`/`am`.

Not promised: porting git's own test suite wholesale (it is the north star:
`t/` scripts run against `1git` give the honest score), and anything that
needs a feature m31 does not have (stop and discuss).

## Target version

The oracle is the newest released git (2.55 on CI). Where releases differ
1git follows the newest: since 2.55 a commit named on the command line is
shown with its real header and parents even when a pathspec leaves no diff
(`show HEAD -- path`); `compare_show.sh` runs those forms only against git
2.55 or later.
