# Changelog

Each release's changes in one place (the details are in `README.md` and
`docs/GIT-COMPAT.md`).

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
