# gitui — a terminal git client

Git plumbing and an interactive client, written entirely in m31 (the
language at github.com/qrazil/m31): SHA-1, zlib inflate, the loose-object
format, refs, the index, working-tree status, and both a read-only CLI
(`git.m31`) and a `TUI_app.Loop`-driven interactive client (`gitui.m31`) over
github.com/qrazil/tui. Nothing here is a binding to anything; the only C in
the program is the runtime every program links.

The repo is an m31 project: the `deps` file names it (`gitui`, its version) and pins
github.com/qrazil/tui by commit; m31c fetches that into `.m31-deps/` on the first
build and records it in `deps.lock`. Library modules and the two entry points stay
at the root; `tests/`, `tests/oracles/`, `scripts/` and `docs/` hold the rest.

```
export M31_ROOT=/path/to/m31      # a checkout, or an extracted release's runtime SDK (m31 v0.3.0+)
export LANGC=/path/to/m31c        # the matching compiler

bash tests/test.sh                    # the built-in fixtures
bash tests/test.sh <repo> [<repo>…]   # those, and each repository named

bash scripts/build.sh git.m31 -o ourgit
./ourgit -log --max 5

bash scripts/build-gitui.sh -o ourgitui    # not build.sh -- it is the one with a dependency
./ourgitui                         # run from a repository's own top level
```

| file | what it is |
|---|---|
| `GIT_zlib.m31` | DEFLATE inflate (RFC 1951) and the zlib wrapper (RFC 1950), with Adler-32, from a mid-file offset as well as from the front |
| `GIT_hash.m31` | which hash a repository uses (SHA-1 or SHA-256): the format check, the widths, the digest, and the refusal of extensions this does not implement |
| `GIT_object.m31` | the object store: the header, the hash check, trees, commits, tags -- loose or, via `GIT_pack.m31`, packed, through the one `read` |
| `GIT_pack.m31` | packfiles: `.idx` v2, the pack's own object encoding, `OBJ_OFS_DELTA`/`OBJ_REF_DELTA` delta-chain resolution |
| `GIT_refs.m31` | HEAD, `refs/**`, `packed-refs`, symbolic refs, `rev-parse`'s DWIM |
| `GIT_revparse.m31` | git's revision grammar (`HEAD~3`, `HEAD^2`, `@{upstream}`, `@{-1}`, `:/text`, `rev:path`, `rev^{tree}`, `A..B`, `A...B`, ...): `object_id`, `commit_id`, `tree_id`, `rev_lines` (what `git rev-parse` prints), `rev_range` (what `git rev-list` walks); every typed revision goes through it |
| `GIT_repository.m31` | where the files are: `.git` as a file, and a linked worktree's `commondir` |
| `git.m31` | the read-only CLI |
| `GIT_index.m31` | `.git/index`: read, write, a fresh entry from `fs.stat` |
| `GIT_status.m31` | working-tree status: staged, unstaged, untracked, and unmerged paths (index stages 1/2/3, with `git status`'s two-letter codes) |
| `GIT_checkout.m31` | local branches, switching branches (the working-tree-writing primitive: refuses on local changes in the way), creating a branch; `apply_tree_diff` (`read-tree -m -u` between two trees) and `reset_hard` (`reset --hard`) |
| `GIT_hunks.m31` | `lib/diff.m31`'s edit script, grouped into qrazil/tui's `TUI_diff_view.Hunk`/`Line` with context; `spans` is the one definition of where each hunk starts and ends |
| `GIT_patch.m31` | apply or revert exactly one hunk of a diff, or any selection of its `+`/`-` lines (`apply_lines`, `revert_lines`), byte for byte -- what the diff view's `s`/`u` stage and unstage with |
| `GIT_xdiff.m31` | a port of git's xdiff line diff (Myers with its heuristics): same edit script as `git diff --no-indent-heuristic`, and with `diff_lines_indent` the same as plain `git diff` (the indent heuristic, which `GIT_blame` needs to attribute repeated lines as git does); `GIT_hunks` and `GIT_patch` diff with it |
| `GIT_diff3.m31` | line-based three-way merge matching `git merge-file` byte for byte (`merge3`, merge and diff3 styles, `Level` Minimal..ZealousAlnum), and the conflict reader: `parse_conflicts`, `render`, `resolve`, `resolve_all` |
| `GIT_log.m31` | the commit-history walk, shared by `git.m31 -log` and `gitui.m31` |
| `GIT_client.m31` | the interactive client's top: `State` (the layer tower's last floor), key dispatch, drawing the overlay stack over the body, the `$EDITOR` handoff (no top-level statements, so it is importable and testable) |
| `GIT_ui_core.m31` | the shared `Core`, the `Overlay` interface (`handle_key`, `render`, `hints`), **the key table** that drives dispatch, the footer and `?` alike, and the command-log ring buffer |
| `GIT_ui_model.m31` | the pure model: outline rows, commit-file diffs, commit template, editor choice |
| `GIT_ui_outline.m31`, `GIT_ui_diff.m31`, `GIT_ui_commit.m31`, `GIT_ui_branch.m31`, `GIT_ui_remote.m31` | one layer per concern (stage/unstage/discard/stage-all, hunk staging, commit and amend, branches, push and pull), each embedding the one below it, plus that concern's overlays |
| `GIT_ui_help.m31`, `GIT_ui_log.m31`, `GIT_ui_search.m31`, `GIT_ui_picker.m31`, `GIT_ui_panel.m31` | the `?` key help, the `@` command log, `/` search, the reusable fuzzy-filter picker, and the shared frame/clamp drawing helpers |
| `GIT_pathtree.m31` | a commit's tree as a lookup: `read_commit`, `entry_at(tree, path)`, `blob` |
| `GIT_blame.m31` | `git blame` without renames or `-M`/`-C`: `blame(gitdir, rev, path, progress)` gives each line's commit, line number in that commit, path and boundary flag, matching `git blame --line-porcelain` (merge parents in order, an identical blob takes all lines) |
| `GIT_filelog.m31` | `git log -- path` with git's default history simplification: `history(gitdir, rev, path, limit)` |
| `GIT_undo.m31` | undo/redo from the HEAD reflog the way lazygit does it: `plan` (what one press would do, or why not, refusing while a merge/rebase/cherry-pick/revert is in progress), `apply` (checkout back through `GIT_checkout.apply_tree_diff`, then the ref, writing `undo: ...`/`redo: ...` reflog lines) |
| `GIT_branches.m31` | upstream tracking (`branch.<n>.remote`/`.merge` mapped through `remote.<r>.fetch`; ahead/behind and git's `[ahead 2, behind 1]`/`[gone]` labels), `set_upstream`, `record_push` ("update by push"), and tags: `tags`, `create_lightweight`, `create_annotated` (byte-identical tag objects), `delete_tag` |
| `GIT_watch.m31` | has the repository changed? `stat`-only fingerprint of the index, HEAD, refs, every tracked file and every non-ignored directory (bounded) |
| `GIT_ui_blame.m31`, `GIT_ui_filelog.m31`, `GIT_ui_show.m31` | `B` blame overlay (with `,` re-blame at the parent), `H` file history, and the read-only commit view both open; `GIT_ui_blame.target` works out which file and revision `B`/`H` mean |
| `GIT_ui_undo.m31`, `GIT_ui_tags.m31`, `GIT_ui_prompt.m31` | the `Z` undo/redo overlay, the `T` tag list, and the one-line text prompt it uses |
| `GIT_ui_loop.m31`, `GIT_ui_autorefresh.m31` | `TUI_app.Loop.run` with an idle `Ticker`, and the ticker that polls `GIT_watch` about once a second and reloads the outline when something changed behind the client's back |
| `gitui.m31` | the interactive client's thin driver: parses a path, runs `TUI_app.Loop` |
| `GIT_http_fetch.m31` | git's smart-HTTP protocol, v0 fetch/clone only: pkt-line framing, the ref advertisement, want/have negotiation, side-band-64k demultiplexing, and pack checksum verification, over `lib/https.m31` (`http://` and `https://`) |
| `GIT_wire.m31` | the transport-independent half of git's wire protocol over a duplex `Stream { read(n), write(bytes), close() }`: pkt-lines, the advertisement, want/have negotiation in rounds of at most 256 haves with the ACKs read between rounds (no write/write deadlock on a long-lived channel), side-band demultiplexing, pack verification, and the receive-pack command and report-status; `GIT_http_fetch.m31` and `GIT_http_push.m31` are now HTTP adapters over it |
| `GIT_remote.m31` | where a remote lives: URL parsing (https, http, `ssh://`, scp-like, local) checked against the argv git hands to ssh, `url.<base>.insteadOf` / `pushInsteadOf` rewriting, `sq_quote` and the `git-upload-pack` / `git-receive-pack` command, a pure `~/.ssh/config` subset resolver, pure `known_hosts` matching (plain, `[host]:port`, wildcard, hashed via HMAC-SHA1, markers surfaced), no I/O; the ssh transport that uses it is `GIT_ssh_transport.m31` |
| `GIT_ssh_transport.m31` | git over ssh: an exec channel of the m31 ssh client (`lib/sshclient.m31`) as a `GIT_wire.Stream` running `git-upload-pack` / `git-receive-pack` (a v0 conversation with no `# service=` preamble), `~/.ssh/config` and `known_hosts` handling, the unknown-host probe (`ssh.presented_host_key`, banner wait bounded by 15 s), `trust_host` (`sshhosts.add`); `GIT_pull.pull_ssh` and `GIT_ui_remote.m31`'s `HostTrustOverlay` sit on top of it |
| `GIT_pack_write.m31` | writes packfiles (whole objects, stored-zlib) and computes the object set a push must send, like `git rev-list --objects tips ^known` |
| `GIT_http_push.m31` | smart-HTTP v0 push (`git-receive-pack`): fast-forward-only, `report-status`, HTTP Basic auth from the URL's userinfo or `GITUI_HTTP_USER`/`GITUI_HTTP_PASSWORD` |
| `GIT_config.m31` | `.git/config` in full: every section/subsection/key, multi-valued keys, system/global/local layering with `include`/`includeIf` (`gitdir:`, `gitdir/i:`, `onbranch:`) followed, defaults for `commit.gpgsign`, `pull.rebase`, `push.default`, `init.defaultBranch` and `rerere.enabled`, and safe in-place `set`/`add`/`unset` that keep the rest of the file byte for byte |
| `GIT_ident.m31` | the author/committer name and email: `GIT_<ROLE>_*`, `<role>.*`, `user.*`, `$EMAIL`, then the login name |
| `GIT_reflog.m31` | `.git/logs/<ref>` in git's own format: read, append, delete with `--rewrite`; `GIT_refs.update` writes it for every ref move |
| `GIT_graph.m31` | the commit graph: ancestors, `is_ancestor`, `merge_bases` (criss-cross gives several), `ahead_behind`, `rev_list(include, exclude)` |
| `deps` | the project manifest: name, version and the pinned qrazil/tui commit (`deps.lock` records what was fetched) |
| `scripts/build-gitui.sh` | builds `gitui.m31`; its `import tui.TUI_app;` lines resolve through `deps`, so nothing is staged or copied |
| `tests/t_*.m31` | test programs, each printing what a Python oracle prints, or asserting against its own expectations |
| `tests/oracles/oracle_*.py` | the oracles: `hashlib`, `zlib`, and a from-scratch format reader |
| `tests/pty_e2e.py`, `tests/pty_blame_undo.py` | drive `ourgitui` under a real pty against disposable fixtures, real `git` as the oracle (the second file: blame, history, undo, tags, ahead/behind, `push -u`, auto-refresh) |
| `scripts/compare.sh` | every command beside the real `git`, compared octet for octet |
| `GIT_merge.m31` | `git merge` with conflicts: `start` (fast-forward, no-ff, ff-only, already up to date, unrelated histories), `merge_trees`/`merge_with_base` (per-path three-way merge, stages 1/2/3, rename-free like `merge.renames=false`), a virtual merge base when there are several (criss-cross, like git's recursive/ort), `continue_merge`, `abort_merge`, `mark_resolved` and `take_side` for the resolution view; writes MERGE_HEAD/MERGE_MSG/MERGE_MODE/ORIG_HEAD and reflogs as git does |
| `GIT_ui_merge.m31`, `GIT_ui_merge_model.m31` | the merge layer: the `m` menu and branch picker, the abort prompt, the conflict-resolution view, the "Unmerged paths" outline section and the MERGING banner (the model is pure and unit-testable) |
| `GIT_sequencer.m31` | `git cherry-pick` and `git revert` with git's own on-disk state: `expand` (`A..B`, tags followed), `start`, `continue_sequence`, `skip`, `abort`, `quit`, over `GIT_merge.merge_with_base`; writes CHERRY_PICK_HEAD / REVERT_HEAD, MERGE_MSG, AUTO_MERGE, `.git/sequencer/{head,abort-safety,todo,opts}` and the reflog lines git writes, so either tool can finish what the other started. Also exports the per-step pieces (`apply_step`, `finish_step`, `read_todo`/`write_todo`, `read_options`/`write_options`, `reset_to`, `clear_step_state`) for a rebase driver that keeps its own state directory |
| `GIT_ui_sequencer.m31` | the `A` (cherry-pick) and `V` (revert) menus, the range prompt, the continue / skip / abort / quit menu, and the CHERRY-PICKING / REVERTING banner (the banner text is in `GIT_ui_merge_model.m31`) |
| `GIT_rebase.m31` | `git rebase` and `rebase -i` over `GIT_sequencer`'s step pieces, with git's own `.git/rebase-merge/` state (`head-name`, `onto`, `orig-head`, `git-rebase-todo`, `done`, `message`, `stopped-sha`, `author-script`, `amend`, `rewritten-list` and the rest), so `git rebase --continue` can finish what we started and the other way round. `plan` (upstream, `--onto`, `--root`, `--keep-base`, fast-forward and up-to-date detection, commits already upstream dropped by patch-id, `--autosquash` reordering), `start` (`--autostash`, empty-commit handling), `continue_rebase`, `skip`, `abort`, `quit`, `edit_todo`, `state`, `banner`; writes REBASE_HEAD and the reflog lines git writes (`rebase (start)`, `(pick)`, `(reword)`, `(squash)`, `(finish)`, ...). Messages and the todo go through an `Editor` (`Verbatim` and `Declining` are the two stock ones) |
| `GIT_rebase_todo.m31` | the todo list: `Command` (pick, reword, edit, squash, fixup, drop, exec, break), `parse`/`format` as git writes it, abbreviations, `editor_text` with git's comment block |
| `GIT_ui_rebase.m31` | the rebase layer: the `r` menu and its pickers, the todo editor overlay, the abort prompt, the in-progress menu, the `$EDITOR` handoff for a message or the whole list, and the pull offer |
| `GIT_pull.m31` | fast-forward-only pull: fetches over smart HTTP (`GIT_http_fetch.m31`), unpacks the pack with `GIT_pack.read_pack`, refuses a dirty tree and anything but a fast-forward, then `GIT_checkout.m31` moves the working tree and the ref |
| `tests/test.sh` | all of the above (sources the `tests/test_*.sh` files next to it) |
| `docs/FRICTION.md` | **the other half of this**: what the language made hard, and what it made easy |

## What works

Read-only: `cat-file --type/--size/--pretty`, `ls-tree`, `log [--max N]
[<rev>]`, `rev-parse` and `refs`, on a working tree, a bare repository or a
linked worktree -- **loose or packed**, transparently: `GIT_object.read` checks
the loose store first and `GIT_pack.m31`'s `.idx`/`.pack` reading second, so
every reader above it (this CLI, the interactive client's status/diff/commit
reading, `rev-parse`'s short-hash resolution) works the same way on a
repository a real `git clone` produced as on one this program has only ever
committed to itself. See "Packfiles", below, for what that took.

The write path: `.git/index` (read and write), loose object writing (blob,
tree, commit), ref writing (`update`, `update_symbolic`, compare-and-swap),
and working-tree status, all checked against real git in disposable
fixtures (`test_write.sh`).

The interactive client (`gitui.m31`, `docs/design.md`'s locked design):
a collapsible outline of untracked files, unstaged changes, staged changes
and recent commits; whole-file staging and unstaging (`s`/`u`); a hunk-level
diff view (`d` on a staged/unstaged/untracked row; `Enter` directly on one
of a commit's own changed files, below) with an addressable cursor; a
commit, via a message file at `COMMIT_EDITMSG` read back and refused if
empty (`c` opens a which-key overlay: `e` launches `$EDITOR` (`vi` if unset)
on the message file, falling back to writing the template and naming the
path if no editor can be launched at all; `f` finishes; `a` aborts -- see
`GIT_client.m31`'s own header, "launching `$EDITOR`, and the terminal handoff
that takes", for how the terminal is handed to the editor and back); a
persistent footer of the base commands; and a synced jump list toggled with
`J`; and hunk-level staging from inside that diff view -- `s` on a hunk of
an unstaged diff stages exactly that hunk (`git add -p`'s "y"), `u` on a
hunk of a staged diff unstages exactly that hunk (`git reset -p`), the file
then showing as partially staged (`MM`) the way git shows it; the index blob
is built by `GIT_patch.m31` over the real `diff.Op` bytes, never the rendered
text, and checked against real `git apply --cached` byte for byte
(`test_gitui.sh`). `P` opens a push which-key; `p` pushes the current branch to the
same-named branch on `origin` over smart HTTP, fast-forward only (see
"Push" below). `F` opens a pull which-key; `p` fast-forwards the current branch
from `origin` (see "Pull" below). Merge and rebase are described under "Merge"
and "Rebase" below.

Discarding and amending, both checked against the real git command each
stands in for (`test_discard_amend.sh`): `x` on a path row asks first
(`y` discards; any other key keeps it), then restores an unstaged file from
the index's blob (`git checkout -- <path>`, a deleted file recreated, a
symlink as a symlink), removes an untracked file and whatever directory
that leaves empty (`git clean -f -- <path>`), or puts a staged path's index
entry and file both back to HEAD (`git checkout HEAD -- <path>`; a staged
brand-new file is dropped from the index and removed). In the commit
overlay, `A` amends HEAD: its message is prefilled in `COMMIT_EDITMSG`, so
`f` straight away is `--amend --no-edit` and `e` edits it first; the
replacement keeps HEAD's parents and author (date and zone included) with a
fresh committer, exactly as real git does, and moves the branch by
compare-and-swap against the HEAD it replaces. Refused on an unborn branch.
One limit, named in `discard_path`'s own comment: `lib/fs.m31` has no
`chmod`, so an executable that was deleted and then discarded comes back
without its executable bit (one still on disk is rewritten in place and
keeps it).

Branches: the last outline section lists every local branch (current one
starred, tip short id and subject). `b` opens a which-key overlay: `c`
checks out the branch under the cursor, `n` makes a new branch at `HEAD`
(its name read from a file you edit in `$EDITOR`) and switches to it, `a`
aborts. A checkout diffs the two trees and writes only the paths that
differ (modes, symlinks, deletes with empty directories pruned), rewrites
the index entries to match, and moves `HEAD`. It refuses, writing nothing,
if a differing path has staged or unstaged changes, if an untracked file is
in the way, or if either side holds a submodule; the reason shows in the
message line. Checked against real git in `test_checkout.sh`.

Each commit in the log also expands into its own "Files changed" list --
one row per path changed against the commit's first parent (the empty tree,
for the very first commit), with exact `+insertions -deletions` counts
(`(binary)` instead, for a file `git diff` itself would call binary) from
the same hunk-diff engine the working-tree rows use. `Enter` on one of
these pops its diff directly, the same view `d` opens elsewhere -- a commit
leaf row has nothing to fold, so `Enter` means "show the diff" there
specifically rather than the no-op it is on an author/date/message row. A
merge commit diffs against its first parent only (`git log --first-parent
-p`'s own simplification, not git's full combined-diff format) -- this is
for stepping through history, not auditing a merge's conflict resolution.
A commit's file list is computed the first time that commit is unfolded
and cached for the rest of the session (a commit never changes), so a
200-commit log costs no tree reads until you ask; the subsection opens
with the commit, so the review flow is `Enter` on a commit, `Enter` on a
file, read, and `q`/`Esc`/`Backspace` back to where you were -- inside a
diff, `q` closes the diff; only the outline's `q` quits. When the log is a
full page long, a final `… load 200 more commits` row extends it on `Enter`.

Line-level staging: in a diff, `v` starts a visual range and `j`/`k` extend
it; `Space` stages the changed lines in the range (in the staged view it
unstages them), `x` discards them from the working tree after a `y`. With no
range, `Space` acts on the line under the cursor, or on the whole hunk when
the cursor is on its header. The selection becomes a patch (`GIT_patch.m31`,
`GIT_ui_lines.m31`) applied to the index blob or the working file; an
untracked file works too, and a binary file or symlink is refused. Checked
against `git apply --cached` (`-R` to unstage and to discard) over 300+
selections in `pty_lines.py`.

Stashes (`GIT_stash.m31`, `GIT_udiff.m31`, `GIT_ui_stash.m31`): `push`
(`-u` untracked, `-k` keep the index, `-m` message), `list`, `show` (the
unified diff, `-u` included), `drop`, `pop` and `apply` (optionally
restoring the index), `branch`. Stash commits are built the way git builds
them (a work-tree commit with the HEAD, index and optional untracked-files
parents), so the ids are identical to `git stash create` under a fixed
identity and date, and each direction -- ours then git's, git's then ours --
reads the other's stack and `refs/stash` reflog. The outline has a
"Stashes" section (`Enter` opens the list), and `z` opens the stash overlay;
the list overlay previews the highlighted stash's diff. Every write goes to
the command log (`stash push -u`, `stash pop stash@{0}`, ...) and writes
git-style reflog lines. `apply` and `pop` refuse, writing nothing, when a
local change or an untracked file is in the way. A stash that has to be
merged (HEAD or the index moved on a file the stash also changed, `-k` followed by `pop`) goes through `GIT_merge.merge_with_base`
(`GIT_stash.stash_apply_merge`: base = the stash's base, ours = the index, theirs =
the stash, labelled `Updated upstream` / `Stashed changes`) and ends as git's
does: a clean merge leaves the index alone apart from files the stash added, a
conflicted one leaves markers, stages 1/2/3 and the other merged paths staged, and
`pop` keeps the stash. `apply --index` over a merge applies the staged changes by a
tree merge where git applies a patch, and refuses (nothing written, where git fails
half way) when the index has staged changes of its own. Other limits:
Untracked symlinks are skipped by `push -u` (the stdlib has no `readlink`),
`show` does no rename detection and submodules are stashed as the index has
them. Checked against real git in `test_stash.sh` (byte-for-byte `show`,
identical commit ids, `fsck --strict`) and `pty_stash.py` (the UI).

Blame, history, undo, tags and tracking. `B` blames a file as of HEAD or of
any commit and `H` lists the commits that touched it; neither follows
renames (git's `blame` without `-M`/`-C`, `log` without `--follow`), and
blame is of committed content, not of the worktree's uncommitted lines. `Z`
undoes and redoes HEAD moves through the reflog, lazygit's way: a commit,
reset, checkout or whole rebase is one step, the worktree follows HEAD
through the same primitive `checkout` uses, and it refuses while an
operation is in progress or when a local change is in the way. Branch rows,
the status header and the branch picker show `[ahead N, behind M]` /
`[gone]` against the upstream. `T` manages tags. The outline also reloads
by itself, about a second after the worktree, index, HEAD or refs change
under it (an editor save, a `git` in another terminal), keeping the cursor
on its row; it waits while a diff or overlay is open. Every write is in the
`@` command log and writes git-style reflog lines. Tests: `test_blame.sh`,
`test_undo.sh`, `test_branches.sh` against the real `git`, and the pty cases
in `tests/pty_blame_undo.py`.

## Keys

One table (`GIT_ui_core.key_table`) is the source for key dispatch, the
footer and the `?` overlay, so they cannot disagree. Overlays form a stack;
the top one takes every key.

| key | where | does |
|---|---|---|
| `j` `k` / arrows | outline, diff | move the cursor |
| `h` `l` | outline | scroll sideways |
| `Enter` | outline | fold or unfold; on a commit's file, open its diff; on the last row, load more commits |
| `s` / `u` | outline, diff | stage / unstage the file, or the hunk in a diff |
| `S` / `U` | outline | stage everything / unstage everything |
| `x` | outline | discard the path under the cursor (asks first) |
| `d` | outline | open the hunk-level diff of the row |
| `v` | diff | start a visual range of lines; `j`/`k` extend it, `v` or `Esc` cancels |
| `Space` / `Enter` | diff | stage the selected lines (unstage them in the staged view); with no range, the line under the cursor, or the whole hunk on its header |
| `x` | diff | discard the selected lines from the working tree (asks first, `y` confirms) |
| `z` | outline | stash overlay: `z` push, `u` push with untracked, `k` keep the index, `m` type a message, `p` pop, `a` apply, `A` apply with `--index`, `d` drop (asks first), `b` branch from the stash, `l` list, `Esc` close |
| `j` `k` `J` `K` / `p` `a` `d` | stash list | move / page; pop, apply, drop the highlighted stash |
| `c` | outline | commit overlay: `e` edit, `f` finish, `A` amend, `a` abort |
| `b` | outline | branch overlay: `c` check out, `/` fuzzy-pick a branch, `n` new, `a` abort |
| `m` | outline | merge overlay: `f` merge (fast-forward when possible), `n` always make a merge commit, `o` fast-forward only, each fuzzy-picking a branch; while merging `c` continue (commit), `a` abort (asks first) |
| `r` | outline | rebase menu: `r` onto a branch you pick (its upstream first), `i` interactively (todo editor first), `h` interactively from the commit under the cursor, `o` `--onto` (new base, then the branch to cut at), `s` / `a` toggle `--autosquash` / `--autostash` (they follow `rebase.autoSquash` / `rebase.autoStash` until toggled); while a rebase is under way the same key opens `c` continue, `s` skip, `a` abort (asks first), `q` quit, `e` edit the todo |
| `j` `k` `p` `r` `e` `s` `f` `d` `J` `K` `E` `Enter` `Esc` | todo editor | move; set the verb of the line (pick, reword, edit, squash, fixup, drop); move the line down / up; `E` edits the whole list in `$EDITOR` (the only way to add `exec` and `break`); `Enter` starts the rebase (or saves the list mid-rebase), `Esc` cancels. A list that starts with squash or fixup is refused |
| `y` `r` | pull, after a diverged fetch | merge / rebase the fetched branch; `pull.rebase=true` (or `branch.<n>.rebase`) rebases without asking, `interactive` opens the todo editor |
| `A` / `V` | outline | cherry-pick / revert the commit under the cursor (a Commits row, or a Branches row for that branch's tip): `p` now, `x` cherry-pick `-x`, `n` `-n` (apply, do not commit), `k` keep a pick that comes out empty, `r` type a range (`A..B` or commits; `R` with `-x`), `1` / `2` a merge commit against its first / second parent |
| `c` `s` `a` `q` | `A` / `V` while a pick or revert is under way | continue (commit the resolved step), skip it, abort (asks first), quit (forget the state, keep the files) |
| `Enter` | outline, on an unmerged path | open the resolution view |
| `a` `b` `B` `z` | resolution view | take ours / theirs / both / the base for the conflict under the cursor (`z` undoes) |
| `j` `k` / `n` `p` | resolution view | next / previous conflict |
| `e` | resolution view | open the file in `$EDITOR`, then re-read it |
| `s` | resolution view | stage the file as it is |
| `P` / `F` | outline | push / pull which-key, `p` runs it |
| `B` | outline, diff | blame the file under the cursor (at HEAD, or at the commit when it is one of a commit's files): short id (`^` marks a root-commit line), author, date, line number, text. `j`/`k`/`g`/`G` move, `Enter` opens the line's commit with its change to the file, `,` re-blames at that commit's parent, `Backspace` goes back, `q` closes. Untracked files are refused |
| `H` | outline, diff | history of the file under the cursor (`git log -- path`, newest first, up to 500); `Enter` shows a commit, `B` blames as of it |
| `Z` | outline | undo the last HEAD move from the reflog, after showing it (`y`/`Enter` does it, `Esc` cancels); `r` switches to redo, `z` back to undo. Worktree changes and stashes are not undoable; a dirty file in the way refuses |
| `T` | outline | tags: `n` lightweight, `a` annotated (name, then message), `d` delete (type `y`). New tags point at HEAD, or at the commit row the cursor was on |
| `u` | push menu (`P`) | push and set `origin/<branch>` as the upstream (`git push -u`); every push also moves `refs/remotes/origin/<branch>` ("update by push") |
| `/` | outline (log included) | search; smart-case: all lower case ignores case, a capital matches exactly. `Enter` runs it, `Esc` cancels |
| `n` / `N` | outline (log included) | next / previous match, wrapping |
| `g` / `R` | outline | re-read the repository |
| `J` / `w` | outline | show the jump list / give it the keys |
| `@` | everywhere | command log: every write the client made (`add`, `update-ref`, `checkout`, ...), newest at the bottom; `j`/`k`/`g`/`G` scroll |
| `?` | everywhere | key help for every scope, generated from the key table |
| `q` / `Esc` | outline | quit (in a diff or overlay: close it) |

The branch picker (`GIT_ui_picker.open(core, purpose, title, items)`) is
generic: type to filter (contiguous matches rank before scattered
subsequences), `Down`/`Tab` and `Up` to move, `Enter` picks, `Esc` cancels.
Merge, rebase and cherry-pick can reuse it by adding a `PICK_*` purpose.

Everything is checked against something that is not this program:

| check | oracle | scale |
|---|---|---|
| SHA-1 | Python `hashlib` | empty, `abc`, the 448-bit vector, a million `a` whole and in seven chunk sizes, every length 0…200, 8 MiB of random octets — 213 digests |
| inflate | Python `zlib` | 29 streams: stored, fixed, dynamic, multi-block, overlapping matches, incompressible, 2.2 MB, plus 15 corrupt inputs that must all be refused |
| objects | a from-scratch Python reader | every loose object in each repository named: 95 828 canonical lines over 8 801 objects across the four used here, with paths, names, emails and messages compared as hex or digests so no text decoding is in the loop |
| commands | the real `git` | 1 388 invocations compared byte for byte across those four repositories |

Both `log` and `cat-file -p` reproduce git's output exactly, which is less
obvious than it sounds — see `git.m31` on tab expansion in commit messages,
on trailing-whitespace trimming, and on C-style path quoting.

Throughput, `cc -O2` on x86-64, best of several runs on a busy machine:
SHA-1 **38–45 MB/s**, inflate **71–102 MB/s** of output, and **10 MB/s** of
object content end to end (open, inflate, verify the SHA-1, parse).
`docs/FRICTION.md` §5 takes the SHA-1 figure apart, because it is a language
datapoint and not a git one.

## Packfiles

This used to be the whole of what a real repository needed that this could
not do, and how much it cost depended entirely on how the repository got
there -- both still true of the numbers below, which describe the
repositories this project actually has lying around, not this program's own
ability to read them any more. `docs/design.md`'s "Going remote" names
packfiles as the first, independent piece of that larger plan (reading only
-- writing one, for `push`, is later, separate work), and it has landed:
`GIT_pack.m31` reads the `.idx` (format v2; v1 is refused, not guessed at, since
nothing still writes it), the packfile's own variable-length object headers,
and resolves an `OBJ_OFS_DELTA`/`OBJ_REF_DELTA` chain of either kind (or a
mix) down to a real commit/tree/blob/tag, iteratively rather than
recursively so a real chain cannot blow the stack. `GIT_zlib.m31` grew the
matching primitive, `inflate_at`/`decompress_at`: decompress one DEFLATE or
zlib stream starting at an offset inside a much larger buffer, and report how
many input octets it consumed, so a packfile's objects are read one at a time
without ever copying the pack to get to the next one.

`GIT_object.read` -- and so `log`, `cat-file`, `ls-tree`, `rev-parse`'s short
names and the interactive client's own reading -- checks the loose store
first and a repository's packs second, with nothing above `GIT_object.m31`
changed to make that true. Checked the same way everything else here is:
`tests/oracles/oracle_object.py`'s from-scratch reader grew its own independent
`.idx`/pack/delta implementation (Python's `zlib.decompressobj`, fed from an
offset, stands in for `inflate_at`) and walks every object of a fixture
`git repack -ad` packs into real `OBJ_OFS_DELTA` chains and, separately,
`git pack-objects --no-delta-base-offset` packs into real `OBJ_REF_DELTA`
ones instead; `scripts/compare.sh`'s full command comparison against real
`git` runs against both packed fixtures exactly as it runs against the loose
one; and `tests/oracles/oracle_inflate_at.py` checks the mid-offset codec on its
own, isolated from the packfile format around it.

Counted by walking from every ref with loose objects alone, at the time of
writing (a measurement of these repositories' own history, unrelated to
what this program can now read):

| repository | objects reachable from its refs | loose | in packs |
|---|---|---|---|
| `workspace/oro` | 3 847 | **100%** | 0 |
| `workspace/lang` (this one) | 4 050 | **100%** | 0 |
| `apps/orogit`, 25 of 31 repos | 276 | **100%** | 0 |
| `apps/orogit`, the other 6 | — | **0%** | everything |
| `git clone --no-local` of `oro` | 0 of the 17 the walk asked for | **0%** | everything |
| `git clone` of `oro` over the filesystem | 3 847 | **100%** | 0 (hardlinked) |

So the answer is not "mostly unusable" and it is not "fine", it is a sharp
split:

  - **A repository that was written to locally is entirely loose.** Neither
    `oro` nor `lang` has ever been packed — `git gc` runs on its own schedule
    and neither has hit it — so stage 1 reads all of both, completely, and
    `log` walks their whole histories. Twenty-five of the thirty-one
    repositories on the orogit server are the same, because they were pushed
    into and never repacked.
  - **A repository that arrived over a network is entirely packed.** A real
    `git clone` writes one packfile and not one loose object, so stage 1 sees
    a HEAD pointing at an object that is not there and can do *nothing at
    all* — not one commit, not one blob. The six orogit repositories that
    were imported from Gitea are in exactly this state.

The line is not "old objects are packed and new ones are loose": it is
"objects this machine wrote are loose, objects that arrived in a pack are
packed, until something repacks". That split used to mean this program was a
usable tool on a repository you have been committing to and a useless one on
a fresh clone, with very little in between; `GIT_pack.m31` is what closes that
gap. `tests/test.sh`'s own built-in fixture is still an all-loose one on
purpose (a repository this program itself commits to, same as `oro` and
`lang`), and it now builds two packed fixtures alongside it -- one repacked
with real `OBJ_OFS_DELTA` chains, one with real `OBJ_REF_DELTA` ones -- so
every command comparison in this file's own test suite runs against a packed
repository as well as a loose one.

Packfile *writing* lives in `GIT_pack_write.m31` (see "Push" below).

## Smart-HTTP fetch (`GIT_http_fetch.m31`): a verified pack on disk, and no further

`GIT_http_fetch.m31` speaks enough of git's smart-HTTP protocol -- v0 only, over
`lib/https.m31` -- to fetch a real packfile from a real server: the ref
advertisement (`GET .../info/refs?service=git-upload-pack`, refusing a
"dumb HTTP" answer rather than misparsing it), want/have negotiation (a
`clone`'s empty `have` list and a `fetch`'s non-empty one are both tested),
side-band-64k demultiplexing, and the pack's own trailing SHA-1 checked
before anything is written to disk. Tested against a real `git http-backend`
run as a genuine CGI script (`test_httpfetch.sh`), not a hand-rolled
stand-in: the ref advertisement matches `git ls-remote` byte for byte, a
full clone's pack is byte-for-byte the server's own (repacked, so genuinely
delta-compressed) pack, a `fetch` against a repository that already has
history gets a visibly smaller pack, and both are accepted by real
`git index-pack --stdin`. A truncated or corrupted transfer -- checked both
as hand-corrupted bytes with no server involved, and as a genuinely
truncated response over the wire -- is refused cleanly, never written.

**This is exactly as far as it goes: verified bytes on disk, not a usable
repository.** `GIT_http_fetch.m31` does not unpack anything it fetches -- no
`.idx`, no delta resolution, no loose objects written -- because doing that
needs the same `OBJ_OFS_DELTA`/`OBJ_REF_DELTA` machinery stage 2 (above) is
for, and duplicating an incomplete piece of that here was explicitly out of
scope. Turning a fetched pack into a repository this program can `log` or
`cat-file` is therefore stage 2's own follow-up, not a gap in this file.
Protocol v2 is a named, separate gap, not an oversight: v0 is universally
supported as a fallback even where v2 is preferred. `https://` (see "HTTPS"
below) and `ssh://` (see "Remotes over ssh" below) are supported.

## HTTPS (`GIT_http_fetch.exchange`)

Fetch, push and pull all work over `https://` remotes as well as `http://`.
Every request goes through `GIT_http_fetch.exchange`, which is the standard
library's `https.fetch` (m31 v0.3.0+; `http` itself no longer links TLS): an
`http://` URL is spoken exactly as before, an `https://` one is spoken over a
TLS connection whose certificate is verified. There is no insecure mode and no
switch that skips the check.

  - **Trust.** The operating system's root certificates by default. To trust a
    private CA (a self-hosted server, orogit behind its own CA), set
    `GITUI_HTTP_CA_FILE=/path/to/ca.pem`; it replaces the system roots for the
    run and becomes `tls.Trust.CaFile`.
  - **Credentials.** As for `http://`: `https://user:pass@host/...` or
    `GITUI_HTTP_USER`/`GITUI_HTTP_PASSWORD`, sent as HTTP Basic inside the
    encrypted connection. The password is stripped from the URL before the
    request is built and is never part of any message or error, including
    when the certificate is refused (nothing is sent before the handshake
    has verified the server).
  - **Errors.** The same vocabulary as over `http://` -- `the HTTP exchange
    failed`, `the server did not answer 200`, `the server refused the push` --
    plus three that only TLS can produce: `the server's certificate was refused
    (untrusted, expired or for another host)`, `the TLS connection failed`
    (anything else that stopped the handshake or the stream, including a CA
    file that cannot be read), and `the server redirected https to http, which
    is not followed`.
  - **Redirects** follow the standard library's rules, unchanged: up to five
    hops on the same origin (a 307/308 keeps the method and body, so a
    redirected `git-upload-pack` or `git-receive-pack` POST works; the
    `Authorization` header goes along), `http://` to `https://` on the same
    host is followed, `https://` to `http://` is never followed, and any other
    change of host or port is refused. A redirect only applies to the one
    request: a 301 on `info/refs` does not rewrite the base URL the way real
    git does, so a server that moves a repository should do it with a 307.

`test_https.sh` runs real `git http-backend` behind Python's `ssl` (TLS 1.3, a
throwaway CA and `localhost` leaf made with `openssl`, handed to the client
through `GITUI_HTTP_CA_FILE`): the ref advertisement over TLS equals `git
ls-remote`; a clone and a fetch with haves are accepted by `git index-pack`;
push to a Basic-auth server (URL credentials, environment credentials, none,
wrong) leaves a `git fsck`-clean repository and never prints the password; a
pull fast-forwards; an unknown CA, another CA's file, a certificate for another
host and a missing CA file are all refused with nothing written, pushed or
moved; and the redirect cases above, including the refused downgrade, plus
the plain `http://` listener of the same server still working.

## SHA-256 repositories (`GIT_hash.m31`)

`git init --object-format=sha256` repositories work end to end; SHA-1 stays the
default and is what every repository without the extension is. The format is
read once from `extensions.objectFormat` (only when `core.repositoryFormatVersion`
is 1, as git does), and then it is a width: 20 or 32 octets of binary id, 40 or
64 digits of name. Where an id is in hand its own length says which algorithm
it is, so a walk over ten thousand commits never rereads the config.

What is algorithm-aware: object hashing and the loose store; packs and `.idx` v2
(reading, and `GIT_pack_write.m31` writing) with 32-octet ids, `OBJ_REF_DELTA`
bases and trailers; the index (32-octet entry ids and checksum); refs,
`packed-refs`, the reflog and the stash; tree entries; revision parsing and
abbreviations; diff, merge, blame, file history, rebase, cherry-pick/revert,
undo and the watcher; and the wire.

Wire: protocol v0/v1 only (this client has no protocol v2, so v2's
`object-format` argument to `ls-refs` and `fetch` does not arise). The server
advertises `object-format=<fmt>` among the first ref line's capabilities; the
client echoes it on its first `want` and on a push command line when the format
is `sha256`. Fetch, pull and push (over `http(s)://` and over ssh, which share
`GIT_wire.m31`) compare the advertised format with the
repository's and **refuse a mismatch** (`the remote's object format differs from
this repository's`), before anything is written or sent. This client has no
`clone` or `init`: fetch and push work on a repository that already exists, so a
SHA-256 repository is made by real git.

Refused, by name, when the entry points open a repository (`GIT_hash.refusal`):
a `core.repositoryFormatVersion` above 1; any extension git knows in a version 0
repository (git dies there too: `repo version is 0, but v1-only extension
found`); an `objectFormat` other than `sha1` or `sha256`; and in version 1 every
extension this program does not implement: `compatObjectFormat`, `refStorage`
(reftable), `partialClone`, `worktreeConfig`. `noop` and `preciousObjects` (a
promise about `gc`, which this never runs) are accepted.

Tested against real git: `tests/test_sha256.sh` builds SHA-256 fixtures (loose,
`repack -ad`, `OBJ_REF_DELTA`), reads them with the Python object reader and the
`compare.sh` command comparison, writes objects, index, refs and packs and has
`git fsck --strict` and `git index-pack --strict` judge them, checks the
refusals, and pushes and pulls through a real `git http-backend` and a real
`sshd` (`test_ssh.sh`) between repositories of the same format and of different
ones. And
`TEST_HASH=sha256 bash tests/test.sh` runs **every** fixture of every test family
as SHA-256 (it sets `GIT_DEFAULT_HASH` for the fixtures, and the oracles read the
width from the repository), so the whole suite is run once per hash.

## Revisions (`GIT_revparse.m31`)

Anywhere a person types a revision it is resolved by git's own grammar, not by a
ref lookup: the cherry-pick / revert range prompt (`r`, `R`), the words of a
rebase todo (`pick HEAD~2`), the merge / log / blame / file-history / stash /
rebase target specs, and the CLI's `-cat-file`, `-ls-tree`, `-log` and
`-rev-parse`. Where the UI already holds an object name (the cursor row, a
picker) it still passes the full id, which resolves as itself.

Supported, in git's own order of precedence: full and abbreviated ids; ref names
by git's DWIM (`name`, `refs/name`, `refs/tags/name`, `refs/heads/name`,
`refs/remotes/name`, `refs/remotes/name/HEAD`, refs before abbreviations);
`@`; `rev^`, `rev^N`, `rev^0`, `rev~N`; `rev^{commit|tree|blob|tag}`, `rev^{}`,
`rev^{/text}`; `name@{N}`, `@{N}`, `@{-N}`, `@{upstream}` / `@{u}`, `@{push}`;
`<tag>-<n>-g<hex>` (`git describe` output); `rev:path`, `rev:`, `:path`,
`:N:path`; `:/text`, `:/!-text`; and, for `rev_lines` / `rev_range`, `A..B`,
`A...B`, `^A`, `A^@`, `A^!`, `A^-N`. The `:/` and `^{/}` patterns are POSIX
extended regular expressions through the standard library's `regex`.

Not understood, and said so (an `Unsupported...` error, never a wrong answer):
dates in `@{...}` (`@{yesterday}`, `@{2.days.ago}`; a Unix timestamp works),
`@{-N}@{u}`, GNU-only regex escapes and back-references in `:/` patterns, and
`:../path`. The header of `GIT_revparse.m31` has the full list. `docs/revisions-audit.md`
records where each entry point takes a revision and why the grammar was needed.

`tests/test_revparse.sh` is the proof: a fixture with merges, a criss-cross,
every tag kind, clashing names, abbreviation collisions, a reflog, upstreams, a
stash, packed and loose objects and a gitlink; every expression drawn from the
names that are in it is compared with real `git rev-parse` (and `git rev-list`
for ranges), plus a seeded fuzzer. Run with `TEST_HASH=sha256` it is the same
suite on a SHA-256 repository.

## Smaller things this does not do

Each of these was checked against the code when this section was written.

  - **Rename detection** (accepted limit): diffs, merges and rebases treat a
    rename as a delete and an add.
  - **Date forms in the revision grammar.** `HEAD@{2.days.ago}` and
    `@{yesterday}` are not understood; `HEAD@{N}`, `@{-N}`, `@{upstream}`,
    `@{push}`, `:/text`, `^{type}`, `A..B`, `A...B`, `A^@` and the rest of
    `GIT_revparse.m31` are (`docs/revisions-audit.md` says where each is used).
  - **Configuration beyond what is listed.** `.git/config` is read, but only for
    `core.bare`, `core.editor`, `core.logAllRefUpdates`, `user.name`/`email`,
    `init.defaultBranch`, `merge.conflictStyle`, `commit.gpgSign`, `rerere.enabled`,
    `rebase.*`, `branch.<name>.*`, `remote.<name>.*`, `remote.pushDefault`,
    `push.default`, `push.autoSetupRemote`, `url.<base>.insteadOf`, and the
    repository format keys. The read-only CLI (`git.m31`) pins the display
    choices instead: abbreviations in a `Merge:` line are seven digits (no
    `core.abbrev`; `compare.sh` runs git with `-c core.abbrev=7`), no
    `log.decorate`, no `.mailmap`, `core.quotePath` as on by default, no colour,
    no pager, no `i18n.logOutputEncoding`.
  - **The read-only CLI's reach.** `git.m31` is `cat-file`, `ls-tree`, `log
    [--max N] [<rev>]`, `rev-parse` and `refs`: no `--topo-order`, `--reverse`,
    path limiting or `--graph` on `log` (the interactive client has a graph view
    and a per-file history), no `ls-files`, no standalone write-side CLI; the
    interactive client and the tests exercise the write path.
  - **Index format v4** (path-prefix compression) is not read; versions 2 and 3
    are, and a v4 index is refused rather than misread.
  - **The commit graph, bitmaps, alternates, replace refs, shallow clones,
    submodules.** All ignored.
  - **Protocol v2, `clone`, `init`.** The wire is v0/v1; the client fetches and
    pushes into repositories that exist.

## Push (`GIT_pack_write.m31`, `GIT_http_push.m31`, `GIT_config.m31`)

`P` then `p` in `ourgitui` pushes the current branch to the same-named
branch on `origin`: `GIT_config.m31` reads `remote.origin.url` from
`.git/config`, `GIT_http_push.m31` fetches the receive-pack advertisement, refuses
anything but a fast-forward (the remote tip must be an ancestor of what is
pushed; no force push), `GIT_pack_write.m31` packs exactly what the server lacks,
and the server's `report-status` answer becomes the status-line message.
The UI then reloads. The push is synchronous: the screen does not repaint
while it runs.

Authentication is HTTP Basic, from `http://user:pass@host/...` in the remote
URL or, when the URL carries none, `GITUI_HTTP_USER`/`GITUI_HTTP_PASSWORD`.
The userinfo is stripped from the URL before anything is displayed, and the
password is never part of any message or error. Remotes may be `http://` or
`https://` (see "HTTPS" below), or ssh (see "Remotes over ssh" below, where the
credential is a key, not a password).

`test_push.sh` uses real git as the oracle: every pack `packwrite` writes is
accepted by `git index-pack --strict` and read back through `GIT_pack.m31`; the
object set equals `git rev-list --objects`; pushes go to a real `git
http-backend` and are judged by the server's refs, `git fsck --full` and a
byte-for-byte comparison of the pushed objects. A non-fast-forward is refused
with nothing sent, a server-side refusal (a `pre-receive` hook) is reported
with its `ng` reason, and the Basic-auth paths (URL, environment, none,
wrong) are covered against an authenticating server.

## Pull (`GIT_pull.m31`, `GIT_pack.read_pack`)

`F` then `p` in `ourgitui` pulls the current branch from the same-named
branch on `origin`, fast-forward only. `GIT_pull.m31` reads the advertisement
(`GIT_http_fetch.discover`), and a remote tip that is the local tip or one of its
ancestors is "already up to date". Anything else is fetched with the local tip
as a `have`; the pack is unpacked by `GIT_pack.read_pack` (whole objects, OFS and
REF deltas, and thin packs, whose missing bases come from the repository) and
each object is written loose with `GIT_object.write`. The pull is then refused when
the working tree or index is dirty, when HEAD is detached or unborn, when the
remote has no such branch, and when the local tip is not an ancestor of the
remote one (`not a fast-forward; merge/rebase not supported yet`); in `ourgitui`
that last refusal offers to merge or rebase onto `origin/<branch>` instead (see Merge and Rebase). The fetched
objects are kept in that case, and `refs/remotes/origin/<branch>` is updated so
there is something to merge.

The order of the two writes matters: `GIT_checkout.checkout` diffs HEAD's tree
against the target's, so it runs first, writing the files and index; only then
is the branch ref advanced (compare-and-swap on the old tip) and
`refs/remotes/origin/<branch>` updated. Moving the ref first would leave
checkout an empty diff. Authentication and `https://` behave as for push.

`test_pull.sh` uses real git as the oracle: packs from `git pack-objects`
(OFS, REF, thin) and from `GIT_pack_write.m31` unpack to an object set equal to
`git rev-list --objects` with `git fsck --full` clean; pulls come from a real
`git http-backend`, repacked so the packs delta, and are judged by `git
status`, `git ls-files -s`, a tree diff against the pushing clone and `git
fsck`. The dirty-tree (staged and unstaged), diverged, ahead, detached,
missing-branch and Basic-auth cases are covered, and `pty_e2e.py` presses `F`
and `p` for real.

## Merge (`GIT_merge.m31`, `GIT_ui_merge.m31`)

`m` in `ourgitui` opens the merge overlay. `f` / `n` / `o` pick a local branch
with the fuzzy picker and merge it (default, `--no-ff`, `--ff-only`); every
write goes to the command log and to the reflogs in git's own wording, so a
merge started here can be finished by `git merge --continue` and the other way
round (the tests do both). A merge that conflicts leaves git's state: stages
1/2/3 in the index, conflict markers in the files (merge or diff3 style, from
`merge.conflictstyle`), MERGE_HEAD, MERGE_MSG, MERGE_MODE and ORIG_HEAD. The
outline then shows a `MERGING (n conflicts)` banner and an "Unmerged paths"
section; `Enter` on a path opens the resolution view, which shows the file with
the current conflict marked `>` and writes the file after every key, so
`$EDITOR` (`e`) and the view never disagree. The file is staged by itself as
soon as no markers remain. Conflicts with no markers (modify/delete, symlinks, binary files) are
resolved whole-file with `a` (ours) / `b` (theirs).
`c` in the merge overlay finishes with the merge message (or the commit overlay,
which uses MERGE_MSG, adds the second parent and refuses while paths are
unmerged); `a` aborts like `git merge --abort`.

When the history has several merge bases (a criss-cross), the engine merges
the bases into a virtual base first, as git's recursive/ort strategy does, so
the result equals git's on such histories (checked against `git merge`).

Not done: rename detection (it merges as `-X no-renames`), octopus merges,
and `merge.ff` / merge drivers; submodules conflict and keep ours.

`test_merge.sh` runs every case on twin repositories, one merged by git and one
by us, and compares HEAD, index, status, working tree, state files and reflogs;
`pty_merge.py` drives the screens under a real pty.

## Rebase (`GIT_rebase.m31`, `GIT_rebase_todo.m31`, `GIT_ui_rebase.m31`)

`r` in `ourgitui` opens the rebase menu (see Keys). A rebase onto a branch whose
upstream is already behind HEAD is a no-op and says so; one that can fast-forward
does, as git does; commits already upstream (same patch-id, looked back 1000 commits)
are left out. `-i` and `h` open the todo editor before anything is touched: `p`, `r`,
`e`, `s`, `f`, `d` set the verb, `J` / `K` reorder, `E` hands the list to `$EDITOR`.
`reword` and `squash` open `$EDITOR` (`vi` if unset) on the message when they come up.

A conflict stops with REBASE_HEAD, stages 1/2/3 and markers, the `REBASING n/m`
banner and the same "Unmerged paths" section and resolution view as a merge;
resolve, stage and `r c` to go on. An `edit` or `break` stops with the commit
applied: change things, stage them and `r c` (the commit is amended when something is
staged). While a rebase is under way, commit, branch, merge, pull, undo, stash and
cherry-pick/revert refuse with a message. `Z` undoes a finished rebase as one step.
`.git/rebase-merge/` is git's format, so `git rebase --continue|--skip|--abort` finish
a rebase started here and the other way round (a rebase git started is recognised on
startup).

`test_rebase.sh` compares our rebase with git's on twin repositories (working tree,
index, refs, every reflog line, every file under `rebase-merge/`, commit ids, `git fsck
--strict`) for plain, `--onto`, `--root`, `--keep-base`, interactive, edit, reword,
squash and fixup chains, drop, reorder, exec, break, autosquash, autostash, already
upstream, empty commits, and every conflict flow in all four git/ours pairings of start and
finish; `pty_rebase.py` drives the screens.

Not done: `label`, `reset`, `merge` and `update-ref` todo lines (refused with a clear
error), `fixup -C` / `-c`, `amend!` commits, the `<branch>` positional (check the
branch out first), merge commits in the range (`--rebase-merges`), `--reschedule-failed-exec`,
`--signoff`, `--strategy`, `-X`, the post-rewrite hook and `notes.rewriteRef`, the `patch` file in
`rebase-merge/`, the status comment block git adds to a squash/reword message (the message itself is
identical), shift-arrow line moves in the todo editor (`J` / `K`), quick fixup / squash /
reword / drop actions on a log row, the commit overlay at an `edit` stop (stage, then `r c`),
`pull.rebase=merges` (it asks), and tags in the rebase picker (branches only). `skip` does not
refuse when a path you edited and staged at a stop would be discarded.

## Cherry-pick and revert (`GIT_sequencer.m31`, `GIT_ui_sequencer.m31`)

`A` cherry-picks and `V` reverts the commit under the cursor. The commits in
the outline are those reachable from HEAD, so to pick from another branch put
the cursor on its row under Branches (the tip is picked) or type a range with
`r`. The menu offers `-x`, `-n`, `-m 1` / `-m 2` and a range; a range is the
commits reachable from B and not from A, oldest first for a pick and newest
first for a revert, as git orders them. Several commits (or any range) keep
`.git/sequencer/` with `head`, `abort-safety`, `todo` and `opts`; a single
commit leaves only the per-step files, as git does. A conflict leaves stages
1/2/3 and markers, CHERRY_PICK_HEAD / REVERT_HEAD, MERGE_MSG with its
`# Conflicts:` block and AUTO_MERGE; the outline shows a CHERRY-PICKING or
REVERTING banner and the same "Unmerged paths" section and resolution view the
merge uses. `A c` / `V c` commits the resolved step and goes on (the pick keeps
its author), `s` drops it, `a` puts HEAD and the files back (and, as git does,
only if HEAD is still where the sequence left it), `q` forgets the sequence.
A step that comes out empty stops with a message; `s` skips it.

While a pick or revert is under way, commit, branch, merge, pull, undo and
stash apply / pop / branch refuse with a message. A sequence git started is
recognised on startup and the other way round; `test_sequencer.sh` compares 54
cases against twin repositories (working tree, index, refs, reflogs, every
state file, commit ids) in all four git/ours pairings of start and finish, and
`pty_sequencer.py` drives the screens.

Not done: rename detection (as the merge), the editor (messages are used as
they are; `MERGE_MSG` is cleaned of `#` lines on continue), `--signoff`,
`--strategy`, `-X`, `--gpg-sign`, `--edit`, a todo with verbs other than pick
and revert, committing an empty step by hand or picking an originally empty commit
(`k` keeps a pick that came out redundant, nothing offers `--allow-empty`),
and non-UTF-8 commit messages. A first step that fails
with an error (a local change in the way) leaves nothing behind, where git
leaves the sequencer directory and then calls the operation "already in
progress".

## Remotes over ssh (`GIT_ssh_transport.m31`)

When `origin` is an ssh URL -- `ssh://[user@]host[:port]/path`, `user@host:path`,
or an alias from `~/.ssh/config` (after `url.<base>.insteadOf` /
`pushInsteadOf`) -- `F p` and `P p` run `git-upload-pack` / `git-receive-pack`
on the server over the m31 ssh client, with the same fast-forward-only rules,
status messages and working-tree checks as over HTTP. The path is single-quoted
for the remote shell (`GIT_remote.sq_quote`), so spaces and quotes in it are
safe. The conversation is git's v0 protocol straight on the channel, with no
`# service=` line; `GIT_wire.fetch_pack` sends at most 256 `have`s per round
and reads the server's replies between rounds, so a long history cannot
deadlock against the ssh window (2 MiB; flow control is the library's). The
remote's stderr is kept and shown as `remote: ...`.

What is read, and from where:

  - **Where to connect.** `~/.ssh/config` through `GIT_remote.ssh_config_resolve`:
    `Host` patterns, `HostName`, `User`, `Port`, `IdentityFile`. The user
    defaults to `$USER`, the port to 22.
  - **Which key.** The config's `IdentityFile`s in order, then
    `~/.ssh/id_ed25519`; each that exists is tried until the server accepts one.
    `GITUI_SSH_IDENTITY=<file>` replaces that list with the one file.
  - **Which hosts.** `~/.ssh/known_hosts`; `GITUI_SSH_KNOWN_HOSTS=<file>` names
    another. Plain, `[host]:port` and hashed entries match; `@revoked` is
    honoured.

Host keys. A host that is not in known_hosts stops before anything is sent: the
status line and a confirm overlay say `host key SHA256:... not known; trust and
add to known_hosts? (y/N)`. Nothing is ever trusted silently: `y` is the only
way in. It appends the key (plain, or hashed when `HashKnownHosts yes` applies
to that host in `~/.ssh/config`) through the m31 library's `sshhosts.add` and
runs the push or pull again; any other key cancels with nothing written. The
fingerprint comes from `ssh.presented_host_key`, a short handshake on a second
connection that checks the server's signature and reads its key, nothing else;
that call has no timeout of its own, so gitui first waits up to 15 s for the
server's banner and reports `no host key from ... within 15 s` for a server that
accepts the connection and says nothing (a server that sends the banner and then
stalls is not bounded). The real connection then enforces the
key the file holds, so the probe cannot be used to slip a different key in. A
`@revoked` entry for the presented key is a refusal, not a prompt. A key that
differs from the one known_hosts records is a hard refusal -- no overlay, no way
to accept it from the UI, the fingerprint it presented in the message; fix
known_hosts by hand. A known_hosts file that does not exist yet is created, with
its directory, on the first `y`.

Keys and passwords. There is no terminal for a prompt, so an encrypted key, a
missing key and a key the server refuses all end in a plain message that names
`https://` remotes as the alternative; there is no password or passphrase
authentication.

Limitations: ed25519 only (host keys and user keys; RSA/ECDSA are not
negotiated), unencrypted OpenSSH-format keys only, one algorithm suite
(curve25519-sha256 with chacha20-poly1305), no ssh-agent, no rekeying
(the library never rekeys; transfers were tested up to about 7 MB), the
`ssh_config` subset above (`Match`, `Include`, `ProxyJump`, `UserKnownHostsFile`, `HostKeyAlias` and the rest are ignored), no
`/etc/ssh/ssh_known_hosts`, and, like push and pull over HTTP, the operation is
synchronous: the screen does not repaint while it runs. `~/.ssh/known_hosts`
is only ever appended to, never edited.

`test_ssh.sh` runs a disposable OpenSSH `sshd` (throwaway host and user keys, an
ephemeral port, a throwaway `$HOME`; the real `~/.ssh` is never touched) that
serves the real `git-upload-pack` / `git-receive-pack`, and SKIPs with a
visible note if `sshd`, `ssh-keygen` or git's server programs are absent (macOS
has `/usr/sbin/sshd`; the fixture starts it as an ordinary user process on a
high port). Refs are compared with
`git ls-remote` and repositories judged by `git fsck --strict` /
`git index-pack --strict`: fast-forward pull, a new branch, a fast-forward
push, both non-fast-forward refusals, `ssh://` and alias URLs, a nonstandard
port, a path with spaces and quotes, a 7 MB / 4200-object fetch and push
(bigger than the ssh window), 800 unknown `have`s in several rounds (counted
in the server's own packet trace), a wrong key, an encrypted key, a missing
key, an unknown host refused then trusted (plain and hashed, read back by
`ssh-keygen -F`), a changed and a revoked host key; `pty_ssh.py` then drives
the real client through the confirm overlay.
