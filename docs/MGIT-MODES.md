# mgit's modes

Since 0.25.0 `mgit` is five full-screen **modes**, not one screen with every
key bound at once. Each mode shows only what makes sense in it, the bottom row
lists only those keys, and `Tab` moves to the next mode.

```
 1 Status  2 Commit  3 History  4 Branches  5 Stash        <- the tab bar (row 1)
 main  ·  → origin/main ↑2  ·  +1 ~3 ?1  ·  repo           <- the statusline (row 2)
 ▾ Untracked files (1)
     notes.txt                                              <- the mode's body
 ▾ Unstaged changes (3)
     M  a.txt
 ...
 hunk 1 of a.txt staged                                     <- messages (dim)
 s stage  u unstage  d diff  c commit  Tab mode  : commands  ? more   <- the hint row (last row)
```

There is no border: the first row is the tab bar, the last row is the hint row,
and everything in between is the mode.

## Moving between modes

| key | does |
|---|---|
| `Tab` / `Shift-Tab` | the next / previous mode, wrapping round (an open diff is closed: it belongs to its mode) |
| `1` ... `5` | jump to a mode |
| `Esc` | from any mode but Status: back to Status. From Status: quit |
| `q` | quit (in a diff or an overlay: close it first) |
| a click on a tab | switch to it; the wheel and a click on a row work in every outline mode, as they always did in a diff |
| `:` or `Ctrl-P` | the command palette (below) |
| `?` | the help for the mode you are in (below) |

Each mode remembers where its cursor was (by row, not by position) and gives it
back when you return.

## The modes

Counts are generated, not typed: `tests/t_modes.m31` prints them (the `info:`
lines) from the same table. "action keys" are the keys that do something in the
mode (not movement, folding, search or the keys every mode shares); "hint row"
is the most the bottom row ever shows at once.

| mode | body | action keys | hint row |
|---|---|---|---|
| **1 Status** | untracked, unstaged and staged files; the hunk diff when you open one | 10 (8 in the diff) | 8 |
| **2 Commit** | what the commit will say and contain; amend | 4 | 7 |
| **3 History** | the log, a commit's files, file history | 7 | 8 |
| **4 Branches** | local branches, tags, merge, rebase, push and pull | 9 | 8 |
| **5 Stash** | the stash list, push, pop, apply, drop | 2 (plus the stash menu's own) | 6 |

Before, the one screen answered 57 keys at its top level (the outline's and the
everywhere keys, aliases counted), 20 of them actions, and on 80 columns the
footer ran out of room after about six. Now no mode has more than ten
action keys, none shows more than eight on the bottom row, and the rest are one
`?` away, grouped. The menus behind `b`, `m`, `r`, `z`, `P`, `F`, `T`, `A` and
`V` are unchanged; they are overlays with their own small key sets.

### 1 Status: review and stage

Untracked, unstaged and staged changes (the first three sections of the old
outline, in the same order). A conflict list ("Unmerged paths") appears here
while a merge, cherry-pick or rebase has conflicts.

| key | does |
|---|---|
| `s` / `u` | stage / unstage the file under the cursor |
| `S` / `U` | stage everything / unstage everything |
| `x` | discard the file's changes (asks first, naming the path) |
| `d` or `Enter` on a file | open its hunk diff |
| `c` | go to the Commit mode |
| `B` / `H` | blame / history of the file |
| `Enter` | fold or unfold the section; on an unmerged path open the resolution view |
| `Space`, `-`, `+` | fold the row's section, fold every section, unfold every section |
| `[` `]` `{` `}`, `j` `k`, `h` `l` | move between sections and rows, scroll sideways |
| `/` `n` `N` | search |
| `J` `w` | the jump list, and giving it the keys |

In the diff view (`d`): `s` / `u` stage or unstage the hunk under the cursor,
`v` selects lines (`Space` or `Enter` stages them, `x` discards them, asking
first), `D` toggles side-by-side, `f` folds a hunk, `-` / `+` fold or unfold
every hunk, `[` `]` move between hunks, `{` `}` between files, `h` `l` `e` `E`
`w` `<` `>` drive the side-by-side view, `q` or `Esc` or `Backspace` goes back.

### 2 Commit: write and make the commit

A panel, not a list: the heading says whether it is a new commit, an amend or a
merge commit, then the first line of the draft message and the staged files.

| key | does |
|---|---|
| `e` | write the message in `$EDITOR`; leaving the editor with a message makes the commit |
| `f` | make the commit from the message already on disk |
| `A` | amend HEAD: its message is prefilled, its parents and author are kept |
| `a` | discard the draft (and the amend), after asking and naming what goes: `discard the draft message "fix the parser"?` (`y` discards, any other key keeps it) |

After a commit the client returns to Status. `c` in Status is the same as
pressing `2`, plus a refusal while a cherry-pick, revert or rebase is under way.
(Sign-off is not offered: the library has no `--signoff`, and this release does
not add one.)

### 3 History: the log

The commits section: `Enter` unfolds a commit (author, date, message, files
changed); `Enter` on one of its files opens that commit's diff of the file.

| key | does |
|---|---|
| `Enter` | unfold or fold; on a commit's file open its diff (so does `d`); on the last row load more commits |
| `A` / `V` | cherry-pick / revert the commit under the cursor (menu: now, `-x`, `-n`, keep empty, a range, merge parent) |
| `r` | the rebase menu: onto a branch, interactively, `h` from the commit under the cursor, `--onto`, autosquash, autostash |
| `Z` | undo the last HEAD move from the reflog (shows it, asks first); `r` redo |
| `B` / `H` | blame / history of a commit's file |
| the movement, fold and search keys of Status | |

The diff of a commit's file has the same read-only keys as Status's diff
(side-by-side, folds, hunks, files); stage and discard are Status's.

### 4 Branches: branches, tags and the remote

Local branches, the current one starred, with ahead and behind.

| key | does |
|---|---|
| `Enter` | switch to the branch under the cursor (refused with the reason when a file is in the way) |
| `b` | the branch menu: `c` switch, `/` pick by typing, `n` new from HEAD, `r` a remote branch (a tracking branch is made) |
| `m` | the merge menu: fast-forward when possible, always a merge commit, fast-forward only; continue or abort while merging |
| `r` | the rebase menu (as in History) |
| `A` / `V` | cherry-pick / revert the branch's tip |
| `F` | the pull menu: pull, fetch, pull on the terminal with git's rules, pull with rebase |
| `P` | the push menu: push, push and set the upstream, push on the terminal |
| `T` | tags: list, create (lightweight or annotated), delete |

Not in this release: deleting a branch and renaming one. The library has no
branch delete or rename, and the language-only rule for the standard library
forbids working around that; they are listed as open decisions in the report
that came with this change.

### 5 Stash: the stash list

The stashes, newest first (the section is there even when empty).

| key | does |
|---|---|
| `z` | the stash menu: push, with untracked files, keeping the index, with a message; pop, apply, apply with `--index`, drop (asks first), branch from the stash, list |
| `Enter` on a stash | the stash list over that stash, with its diff beside it (`p` pop, `a` apply, `d` drop, `D` side-by-side) |

## Flows: merge, cherry-pick, revert, rebase

A flow is a state, not a mode. While one is under way:

* the status line names it in red (`REBASING 2/3`, `CHERRY-PICKING (1 conflict)`,
  `MERGING`) and, when nothing else is being said, the message row repeats it
  with the key that gets you out, in every mode;
* **the way out leads the hint row in every mode**: `A/V cherry-pick / revert:
  continue, skip, abort`, `r rebase: continue, skip, abort, edit`, `m merge:
  continue or abort`. Those keys work from any mode, and open the flow's own
  small menu (continue, skip, abort, quit, edit the todo list);
* the actions that would fight it are not advertised (commit, branch, merge,
  pull, undo, rebase, cherry-pick and revert from idle) and, when you press one
  anyway, are refused with one line that says why: `commit is blocked while
  CHERRY-PICKING (A or V: continue, skip or abort)`. From a mode that does not
  have the key, the refusal still says why rather than only where the key
  went. A merge in progress still allows committing: that is how it finishes;
* the conflict list, the resolution view and the rebase todo editor are the
  overlays they always were, with their own keys.

## The hint row

The last row, dim, one line, left-aligned. It shows the keys of the current
mode, view (a diff open or not) and state (a flow or not), most likely first;
on a narrow terminal the least likely go first and `? more` is always kept.
Width is measured in display columns (a wide character is two), so a CJK label
never overflows. An overlay shows its own keys instead (without `? more`: its
keys are all of them).

## `?`: the help

The keys of the mode you are in, grouped (the mode's own actions first, then
movement, folding and search, then the keys every mode shares), and below them
"every menu and view the keys above open": the reference of each menu's keys.
`j` / `k` scroll; `Esc`, `q` or `?` close.

## `:` / `Ctrl-P`: the command palette

A fuzzy picker over every action of every mode, written `Branches: switch to the
branch   [Enter]`, with the key to press next time. Typing filters (a lower-case
query ignores case); `Enter` runs it: it switches to the action's mode and does
it, exactly as its key would. Also in the palette: `Go to <mode>` for each mode.
The cursor-movement keys are not listed (nobody looks them up).

## Keys that moved

Keys keep their letters. A key that is bound but belongs to another mode says
so instead of doing nothing: `A moved to History (3): cherry-pick. Tab or 3 goes
there; : lists every command`. The full sentence is shown the first time a key
is pressed in a session; after that the short form (`A: History (3)`). A key
that is simply absent from a panel (a movement key in the Commit panel) says
nothing. This notice is meant for one release; the table row that drives it is
`GIT_ui_keymap.moved_to`.

Two keys changed their meaning rather than their place, because `Tab` is now the
mode key and `Esc` backs out:

| before | now |
|---|---|
| `Tab` folds the row (outline) / hunk (diff) | `Space` folds the row; `f` folds a hunk |
| `Esc` quits from the outline | `Esc` goes to Status; from Status it quits |
| `c` opened a commit overlay | `c` goes to the Commit mode; `e` `f` `A` `a` are the same, `Esc` no longer discards the draft (`a` does) |
| the footer listed the base keys | the hint row lists the mode's keys; `?` the rest |

## How it is built

Three tables, one source:

* `GIT_ui_core.key_table()` binds a key to a command id within a scope. It is
  the only place a key letter appears.
* `GIT_ui_keymap.entries()` says, for each mode (`modes`), view (`doc`, `diff`)
  and flow state (`when`), which `(scope, cmd)` is offered, under what `label`,
  in which help `group` and at what hint `priority` (0: help and palette only).
  The hint row, `?`, the palette and the dispatcher read it, so there is no
  second copy.
* `GIT_ui_modes` holds the pure facts: the order of the modes, which outline
  sections a mode shows, the tab bar for a width.

A keypress with no overlay open goes: scopes for the mode (`GIT_ui_keymap.scopes_for`)
-> key table lookup -> `GIT_ui_keymap.find` for the mode, view and state ->
`State.run_in_mode`. No entry means "moved to" (or a flow refusal); an entry
whose state does not match still runs, so the operation's own refusal speaks.

### How to add an action

1. Bind the key in `GIT_ui_core.key_table()` (a `Binding` in `SCOPE_OUTLINE`,
   `SCOPE_DIFF`, `SCOPE_COMMIT` or `SCOPE_GLOBAL`) with a `CMD_*` constant.
2. Add an `Entry` to `GIT_ui_keymap.entries()`: the modes it belongs to, the
   view, the same scope and command, a short label, a group, a hint priority
   (leave 0 unless it is among the mode's eight most likely actions), and `when:`
   "idle" if a flow must stop it.
3. Run it: add the `cmd` to `State.run_outline_command`, `run_diff_command` or
   `run_commit_command` in `ui/GIT_client.m31`.
4. `bash tests/test_modes.sh`-style checks (`tests/t_modes.m31`) tell you if a key
   is bound twice in a mode, if a binding is offered by no mode, if the palette
   cannot reach it, or if a hint row overflows.

## Rendering

The screen is rebuilt every frame and drawn as a difference from the last one,
so one stray cell stays wrong until something repaints it. Two things
corrupted cells before this release and are fixed here:

* **Control characters.** `TUI_buffer.set_str` keeps a zero-width character
  inside the cell before it, and that includes a tab, CR or ESC. The diff then
  sent it to the terminal raw: a tab in a diffed file jumped to its tab stop
  and every cell written after it landed in the wrong column, so a later
  update left old cells behind. File text, names, branch names and commit
  messages now go through `GIT_sbs.printable` / `visible` (tabs expanded,
  controls shown as U+2400 symbols, as the side-by-side view already did), and
  `GIT_ui_scrub.scrub` removes any control character left in a cell of the
  finished frame, whatever put it there.
* Nothing is written past a row's width: every `set_str` has a `max`, and every
  string is cut with `TUI_text` (display columns, not bytes).

`tests/pty_modes.py` is the check: at 80x24, 120x40 and 40x12 it tours every
mode (plus unified and side-by-side diffs, a commit's files, the stash list,
help and the palette) over a repository of wide, emoji, combining-mark, tabbed
and very long names, and after each step asserts that the tab bar and hint row
are where they should be, that nothing is drawn past the last column (the same
bytes are fed to a terminal 40 columns wider), and that the screen equals a full
repaint (the terminal is resized and put back, and the two screens compared
cell by cell, style included). It needs `pyte`; without it the checks are
skipped.
