# Changelog

Each release's changes in one place (the details are in `README.md` and
`docs/GIT-COMPAT.md`).

## 0.25.0

- **mgit is five modes, not one screen of every key** (`docs/MGIT-MODES.md`):
  1 Status, 2 Commit, 3 History, 4 Branches, 5 Stash. `Tab` / `Shift-Tab` cycle
  them (a click on the tab bar and `1`-`5` jump), the last row lists only the keys
  of the mode you are in, `?` is that mode's help, and `:` / `Ctrl-P` is a command
  palette of every action of every mode. A merge, cherry-pick, revert or rebase
  under way is named in every mode, its way out leads the bottom row, and what it
  forbids is refused with the reason. One table (`ui/GIT_ui_keymap.m31`) drives the
  bottom row, the help, the palette and the tests.
- Keys keep their letters and live in the mode where they make sense; pressing one
  in another mode says where it moved. Changed on purpose: `Tab` is the mode key,
  so folding is `Space` (`f` for a hunk in a diff); `Esc` goes back to Status (and
  quits from it); `c` goes to the Commit mode, whose `a` discards the draft (`Esc`
  no longer does).
- The screen has no border any more: the tab bar is the first row, the hint row the
  last. The statusline moved under the tab bar.
- **Rendering fixes.** A tab, carriage return or escape in a diffed file, a file
  name, a branch name or a commit message reached the terminal raw and moved the
  cursor under the layout, leaving stale cells behind; text is now shown with tabs
  expanded and control characters as their U+2400 symbols, and a last pass over
  every frame removes any that are left. `tests/pty_modes.py` compares incremental
  screens against a full repaint, cell by cell, over wide, emoji, combining-mark,
  tabbed and over-long names at 80x24, 120x40 and 40x12 (it needs `pyte`).
- Version 0.25.0.

## 0.24.0

- **Breaking: 1git and mgit have a command line of their own** (`docs/CLI.md`):
  Oro's args grammar instead of git's argv. One dash is a command, two dashes an
  option, anything else data; several commands share a line and run in order
  (the whole line is validated first, the first failure ends it); `--help` per
  command; `--completions bash|zsh|fish`; exit status 0, 1 (a command failed) or 2
  (the line was not understood, nothing ran). `1git log --oneline -n 5` is
  `1git -log --oneline --max 5`; `-switch`, `-restore` and `-reset` replace
  `switch`/`checkout`/`restore`/`reset`; `stash`, `remote` and `worktree`
  subcommands are `-stash-pop`, `-remote-add`, `-worktree-add`, ...; `ls-remote` is
  `-remote-refs`; `push` takes `--to REMOTE` and Gerrit's `--for BRANCH --topic T`;
  `--force` pushes with a lease and `--overwrite` without; `--no-x` spellings are
  values (`--edit off`, `--renames off`) or named for what they do (`--skip-hooks`).
  New: `-fetch --pull-request N` and `--merge-request N`, `-migrate`.
  The table is `docs/MIGRATING-FROM-GIT.md`.
- Repository, protocol and output compatibility with git is unchanged; argv
  compatibility is no longer a goal (`docs/GIT-COMPAT.md`).
- **Transition: git-style arguments still work in 0.24.0**, rewritten into the new
  grammar with a warning on stderr (`1git: git-style arguments are deprecated; use
  '1git -log --max 5' (see 1git --help)`); a line with an option 1git dropped runs as
  git would. The shim is deleted in 0.25.0.
- mgit: `mgit [PATH] [--mouse on|off] [--help|--version|--completions SHELL]`;
  `--mouse` overrides `M31GIT_MOUSE` and `mgit.mouse`. Exit status 1 when there is no
  repository or no terminal, 2 for a bad command line.
- Needs m31 0.6.0 (`lib/args` with `version`, `completions`, `parse_or_exit`).
- Tests: `tests/test_cli.sh` (`tests/run_cli.sh` alone), `tests/cli_cases.txt` (every
  option, both directions), `tests/pty_cli.py`; the `scripts/compare_*.sh` oracles call
  1git through the table (`scripts/lib_cli.sh`) and compare with git as before.

## 0.23.0

- **The repository is qrazil/m31git** (it was qrazil/gitui); the programs stay `mgit` and `1git`.
  0.21.0 was skipped. Release assets are now `m31git-<os>-<arch>[-musl].tar.gz`
  (same layout) with a `SHA256SUMS` file; `install.sh` takes the new names, still
  finds the `gitui-` assets of releases up to v0.22.0, and verifies the checksum
  when the release has one.
- The entry file is `mgit.m31` (was `gitui.m31`), `tests/test_gitui.sh` is
  `tests/test_mgit.sh`; `deps` names the project `m31git`.
- Environment variables are `M31GIT_*` (was `GITUI_*`): `HTTP_CA_FILE`, `HTTP_USER`,
  `HTTP_PASSWORD`, `SSH_IDENTITY`, `SSH_KNOWN_HOSTS`, `SYNTAX`, `MOUSE`. Git config keys are
  `mgit.syntax`, `mgit.collapsed`, `mgit.mouse` (was `gitui.*`). The old names are
  still read when the new ones are unset. The user agent is `1git/0.23.0`.
- Housekeeping: `__pycache__/` and `*.pyc` are untracked and ignored.

## 0.22.0

- **mgit: side-by-side diff.** `D` in the diff view, the commit view and the stash
  list flips between the unified diff and old | new in two columns, with line
  numbers per side, a change marker in the gutter, a ruler naming each side,
  changed words marked inside paired lines, wrapped or sideways-scrolled long
  lines, collapsed unchanged regions (`e` widens, `E` resets), and syntax colours
  on both sides. Hunk and line staging, unstaging and discarding work from it
  through the same patch code (`h` / `l` pick the side), `j`/`k`/`[`/`]`/`{`/`}`
  as before, the wheel scrolls both sides together, a click picks a row.
  `diff.view = auto|unified|split` (auto: 120 columns or more) is read from git
  config and `D` writes the choice back; below 60 columns the unified view is
  always used. New keys: `D` `h` `l` `e` `E` `w` `<` `>` in the diff view.
- **mgit: mouse reports** are asked for (`M31GIT_MOUSE=off` or `mgit.mouse=off`
  turns them off): the wheel moves the diff, a click picks a row.
- **1git: `diff`, `show`, `log -p` accept `--side-by-side` / `-y`, `--width=N`
  and `--no-side-by-side`** (an m31git extension; git has none). Without the
  flag the output is git's bytes, as before.
- Tests: `tests/test_sbs.sh` (also `bash tests/run_sbs.sh`), `tests/pty_sbs.py`,
  golden layouts in `tests/golden/sbs/`.
