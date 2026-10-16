# Changelog

Each release's changes in one place (the details are in `README.md` and
`docs/GIT-COMPAT.md`).

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
