# mgit audit against the `core/` library (0.18.0)

What each library capability that `1git` gained in 0.14-0.17 has in `mgit`
(the interactive client, `gitui.m31`). Status is as of this branch; the
"before" column is master 0.17.0.

| Library (1git) | mgit before 0.18.0 | mgit now |
|---|---|---|
| stash push/-u/-k/-m, list, show, apply, pop, drop, branch | `z` menu, Stashes section, list overlay with diff preview (`z l`), apply `--index`, drop asks | unchanged; complete. Not offered: `stash clear`, `push -- <paths>`, `store`/`create` (plumbing) |
| cherry-pick, revert (-x, -n, ranges, -m, continue/skip/abort/quit) | `A` / `V` menus on the commit under the cursor, sequence menu while under way | unchanged; complete |
| merge (ff, --no-ff, --ff-only, continue, abort) | `m` menu; conflict view on Enter of an Unmerged path | unchanged. Not offered: `--squash`, `-X ours/theirs`, `-s` |
| conflict resolution | resolve view: ours / theirs / both / base (diff3), per conflict or per file, undo, `$EDITOR`, stage as resolved; banner for MERGING / CHERRY-PICKING / REVERTING / REBASING; continue/abort in the operation menus | unchanged; complete |
| rebase (-i, --onto, --root, --autosquash, --autostash, continue/skip/abort/quit/edit-todo) | `r` menu, todo-list overlay (p r e s f d, J/K reorder, `E` for `$EDITOR` with exec/break), message editor handoff | unchanged. Not offered: `label`/`reset`/`merge` lines (only through `E`), `-x exec` from the menu |
| diff: patch-mode staging (`add -p`), line staging | hunk `s`/`u`, visual range `v` + Space, discard lines `x` | unchanged; complete |
| combined diff (`diff --cc`, `show` of a merge) | none: a merge commit shows its first-parent diff only | not done (see gaps) |
| fetch | none in the client | `F f`: the library's `fetch` on the terminal |
| pull (merge / rebase per config) | `F p`: fast-forward only, a diverged branch offers merge or rebase | `F p` as before; `F g` fetch + fast-forward / merge / rebase per `pull.rebase`; `F r` fetch + rebase |
| push | `P p` / `P u`: current branch to same-named branch on `origin`, credentials only from the URL | `P g`: the library's `push` on the terminal (upstream remote and branch, credential helpers, netrc, askpass, prompt, ssh known_hosts) |
| credentials (URL, netrc, `credential.helper`, askpass, prompt) | URL only | through the terminal handoff, the library's own flow; nothing is printed by mgit |
| remote management (`remote add/rm/rename/set-url`, `ls-remote`) | none | not done (use `1git remote`) |
| branch: switch, create, tracking | `b`: local branches, `/` picker, `n` new from HEAD | `b r` remote branches picker; `/` picker also lists remote branches; a local branch tracking the remote one is created |
| tags | `T` list / create / annotate / delete | unchanged |
| clean | none | not done (use `1git clean`) |
| worktree | none | not done (use `1git worktree`) |
| blame, file history, undo (reflog), overview | `B`, `H`, `Z`, `i` | unchanged |
| syntax classes (`syntax` 0.4.2: 25 classes) | tui's adapter folded them onto 12 | `GIT_ui_syntax.m31` styles the folded ones (call, property, tag, attribute, punctuation, link, emphasis ...) itself; `deps` lists `syntax` directly |

## How the network actions work

The TUI cannot draw git's progress or a password prompt, and the library's
`fetch`/`push` print to the terminal as `1git` does. So `F f`, `F g`, `F r`
and `P g` leave the alternate screen exactly as the `$EDITOR` handoff does,
print one header line, run the library command (`GIT_gitfetch.run_fetch`,
`GIT_gitpush.run_push`) in-process, wait for Enter, and return to a reloaded
outline whose status line says `fetch: done` or `fetch: failed (exit N)`.
Credentials come from the library's flow (`GIT_creds`); mgit never reads or
prints them. The library's `pull` re-runs the `1git` executable for the merge
or rebase step, which `mgit` is not, so a pull is the library's fetch followed
by mgit's own merge and rebase (which keep the conflict view).

## Gaps

- combined diff for merge commits in the show view;
- `stash clear`, squash merge, `remote` management, `clean`, `worktree`;
- fetch/push options beyond the defaults (`--prune`, `--tags`,
  `--force-with-lease`, push to another remote): use `1git`;
