# Where a revision comes in, and whether the grammar is needed

Audit of `origin/master` 7020057, before `GIT_revparse.m31`. "Spec" below is a
string that has to become an object name; "row" is a value the UI already holds
as a full object name.

## What the engines accept

Every engine takes a `spec: str` and called `GIT_refs.rev_parse` (a full or
abbreviated object name, then `<spec>`, `refs/<spec>`, `refs/tags/<spec>`,
`refs/heads/<spec>`, `refs/remotes/<spec>`, `refs/remotes/<spec>/HEAD`), usually
followed by `GIT_refs.peel`. Nothing else: no `~`, `^`, `@{}`, `:`, `..`.

| entry | where it lands | how the user supplies it |
|---|---|---|
| cherry-pick / revert, one commit | `GIT_sequencer.resolve_commit` | cursor row (`GIT_ui_sequencer.PickMenu.target`, a full id) |
| cherry-pick / revert **range prompt** (`r`, `R`) | `GIT_ui_sequencer.RangeAsk.received` -> `GIT_sequencer.expand` | **typed**: words split on spaces; `expand` cuts a word at the first `..` by hand; `...` is refused |
| rebase onto / upstream / `--onto` | `GIT_rebase.plan` -> `commit_named` | `GIT_ui_picker` over branch names (`GIT_ui_rebase.rebase_targets`); submit only takes a listed row, nothing typed reaches the engine |
| `rebase -i` from a commit, `--root` | `RebaseLayer.rebase_from(spec)` | cursor row (full id) |
| rebase todo (`pick <rev>`, `fixup`, `reword`, ...) | `GIT_rebase_todo.parse`, `GIT_sequencer.parse_todo` | **typed in `$EDITOR`**: any word the user writes after the verb |
| merge target | `GIT_merge.start(spec)` | branch picker (`PICK_MERGE*`); `F` offers the fetched `origin/<b>` string |
| branch creation start point | `GIT_ui_branch` | none: always `HEAD` (name from the editor file) |
| tag creation target | `GIT_ui_tags` | cursor row, else `rev_parse("HEAD")`; the tag *name* is typed |
| checkout | `GIT_checkout.checkout(target_commit_id, target_ref)` | branch picker or branch row; detaching goes through a commit row |
| log / `@` log | `GIT_log.walk(rev)` | the outline's own HEAD log; the CLI `-log [REV]` |
| blame, file history at a rev | `GIT_blame.blame(rev)`, `GIT_filelog.history(rev)` | cursor row (`GIT_ui_blame.target`: `HEAD` or a commit id) |
| stash show/apply/pop/drop | `GIT_stash` by integer index | list row (`stash@{N}` is built by `GIT_ui_stash`, never parsed) |
| upstream / remote resolution | `GIT_branches.tracking_from` | config (`branch.<n>.remote/.merge` through the fetch refspec); nothing in the grammar's `@{upstream}` sense is available to a caller that has a *name* |
| undo / redo | `GIT_undo` over `HEAD`'s reflog | key (`Z`); no `@{N}` |
| CLI of `ourgit` | `-cat-file OBJECT`, `-ls-tree TREE`, `-log [REV]`, `-rev-parse REV` | **typed**, four positional specs |
| CLI of `ourgitui` | `[path]` only | no revision argument |

## Reachable without typing, versus typed

Reached by the cursor or a picker today (no grammar involved): one-commit
cherry-pick/revert, rebase and `rebase -i` targets, merge, checkout, tag
target, blame, file history, stash, undo.

Needs typing, and therefore the grammar: the **range prompt** (the only free
text that is a revision in the whole UI), the **rebase todo** a user edits, and
the **four CLI positionals**.

## Evidence that the grammar is needed

On `origin/master`, in a four-commit repository with an annotated tag `v1`
(`ourgit -rev-parse X`): `HEAD` and `v1` resolve; `HEAD~3`, `main^`,
`v1^{tree}`, `v1^0`, `@`, `@{u}`, `HEAD~1..HEAD`, `:/c2` and `HEAD:f` all
answer "unknown revision or object name". In the range prompt, `HEAD~3..HEAD`
fails the same way (the side before `..` is `HEAD~3`), and so does the most
common cherry-pick range there is, `main..feature~2`, and `v1.0-3-gabcdef`
(what `git describe` prints). In a rebase todo, `pick HEAD~2` is refused with
"'HEAD~2' is not a commit".

So the answer to "is there a way to do it on the tool already" is: for the
cursor flows there is nothing to type, so nothing is missing; for the three
typed entries there is no way short of pasting a 40-digit id. The cursor-driven
UI does not need the grammar; the prompt, the todo and the CLI do, and all of
them already hold the half that is missing (the fallback `rev_parse`), so
the module replaces that call everywhere a *spec* (as opposed to an id the
UI already holds) is consumed.

Also found in passing: `GIT_refs.rev_parse` tries an abbreviated object name
before any ref, where git tries refs first (a branch named `cafe` wins over an
object beginning `cafe`), and the same `rev_parse` + `peel` pair is written out
in six places (log, blame, filelog, merge, rebase, sequencer).

## Decision

Implement `GIT_revparse.m31` with git's grammar (see its header for the list of
what is and is not supported) and replace the six `rev_parse` + `peel` pairs and
the CLI/prompt/todo call sites with it. `A..B` handling moves out of the
sequencer's hand-written cut. The cursor flows are untouched: they keep
passing full ids, which the module resolves as itself.
