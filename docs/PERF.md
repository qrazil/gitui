# Performance: 1git against git

`scripts/bench_1git.py` times `1git` against real `git` on four repositories and
this document records what it found, what was fixed and what is left.

## Method

```sh
python3 scripts/bench_1git.py --one ./1git --git git --runs 5 \
    --medium-src https://github.com/qrazil/m31 --mgit ./mgit
```

- Python 3 only, no GNU flags, every path from `tempfile`/argv, no `/tmp` literals.
  No `hyperfine` needed: each case runs once untimed (warmup) and then N times;
  min and median are reported. Output is read through a pipe (git skips work when
  stdout is `/dev/null`).
- Repositories: **small** (this repository, ~260 files), **medium** (qrazil/m31,
  ~1.9k files, ~430 commits, packed and loose objects), **large-packed** and
  **large-loose** (synthetic through `fast-import`: 20 000 files in 1 000
  directories, 5 000 commits of 5 files each, three multi-megabyte blobs; the
  loose one has every pack exploded). `--files`/`--commits` change the shape.
- Cases: process start, status (clean/dirty), log (several forms), show, diff
  (clean, dirty, staged, 50 commits), branch, rev-parse, cat-file, add 500 files,
  commit, switch, `checkout -b`, merge, stash. Mutating cases run in the
  script's own copy and are reset to a fixed ref before every run; the script
  refuses to run them outside `--work`. A case 1git does not implement
  (`blame`, `ls-files`, `ls-tree -r`) is reported `n/a`. `--mgit` also times
  `mgit` from spawn to its first full paint on a pty.
- Reference: git 2.55.0; 1git built with m31 v0.5.0, `cc -O2`, x86-64 Linux,
  12 cores. Medium and small: 5 runs, min/median of which the median is shown in
  the "after" columns. Large: one timed run. The "before" large numbers are one
  run on a busier machine; ratios, not milliseconds, are the finding.

## Results

Median times; "after" is this branch.

| repo | case | git | 1git before | 1git after | after / git |
|---|---|---:|---:|---:|---:|
| small | process start (--version / --help) | 1.8 ms | 11.1 ms | 10.7 ms | 6x |
| small | status (clean) | 4.1 ms | 43.4 ms | 15.2 ms | 4x |
| small | log -n 20 | 3.5 ms | 16.3 ms | 11.0 ms | 3x |
| small | log --oneline (full) | 8.6 ms | 88.0 ms | 67.6 ms | 8x |
| small | log --stat -n 20 | 37.1 ms | 999.9 ms | 507.3 ms | 14x |
| small | show HEAD | 3.9 ms | 22.2 ms | 14.0 ms | 4x |
| small | diff HEAD~50 HEAD (large) | 43.7 ms | 503.1 ms | 360.5 ms | 8x |
| small | status (dirty) | 5.3 ms | 54.1 ms | 18.8 ms | 4x |
| small | diff (dirty) | 6.0 ms | 34.1 ms | 24.0 ms | 4x |
| small | branch -a -vv | 7.1 ms | 174.1 ms | 61.6 ms | 9x |
| small | add 500 new files | 11.6 ms | 141.7 ms | 66.4 ms | 6x |
| small | commit 500 staged files | 14.7 ms | 29.1 ms | 27.4 ms | 2x |
| small | switch other (30 commits back) | 32.9 ms | 222.6 ms | 110.9 ms | 3x |
| small | merge side (no-ff clean) | 42.5 ms | 628.5 ms | 153.5 ms | 4x |
| small | stash push | 17.1 ms | 69.9 ms | 40.1 ms | 2x |
| medium | process start (--version / --help) | 2.2 ms | 13.4 ms | 10.9 ms | 5x |
| medium | status (clean) | 11.4 ms | 195.4 ms | 91.7 ms | 8x |
| medium | log -n 20 | 6.6 ms | 40.6 ms | 24.1 ms | 4x |
| medium | log --oneline (full) | 14.9 ms | 192.0 ms | 150.8 ms | 10x |
| medium | log --stat -n 20 | 51.0 ms | 789.4 ms | 486.7 ms | 10x |
| medium | show HEAD | 6.6 ms | 56.7 ms | 64.5 ms | 10x |
| medium | diff HEAD~50 HEAD (large) | 163.5 ms | 1.75 s | 1.08 s | 7x |
| medium | status (dirty) | 12.4 ms | 224.1 ms | 92.2 ms | 7x |
| medium | diff (dirty) | 15.4 ms | 110.7 ms | 104.6 ms | 7x |
| medium | branch -a -vv | 9.7 ms | 1.51 s | 155.5 ms | 16x |
| medium | add 500 new files | 11.6 ms | 214.5 ms | 134.7 ms | 12x |
| medium | commit 500 staged files | 20.2 ms | 72.6 ms | 56.8 ms | 3x |
| medium | switch other (30 commits back) | 87.3 ms | 1.10 s | 264.7 ms | 3x |
| medium | merge side (no-ff clean) | 69.9 ms | 6.12 s | 973.2 ms | 14x |
| medium | stash push | 49.7 ms | 392.5 ms | 228.8 ms | 5x |
| large-packed | process start (--version / --help) | 1.9 ms | 13.7 ms | 11.2 ms | 6x |
| large-packed | status (clean) | 53.1 ms | 15.53 s | 959.9 ms | 18x |
| large-packed | log -n 20 | 3.9 ms | 58.0 ms | 11.2 ms | 3x |
| large-packed | log --oneline (full) | 98.7 ms | 1.52 s | 952.4 ms | 10x |
| large-packed | log --stat -n 20 | 23.9 ms | 897.0 ms | 421.3 ms | 18x |
| large-packed | show HEAD | 7.1 ms | 78.0 ms | 45.1 ms | 6x |
| large-packed | diff HEAD~50 HEAD (large) | 52.9 ms | 2.57 s | 1.34 s | 25x |
| large-packed | status (dirty) | 62.4 ms | 16.34 s | 1.10 s | 18x |
| large-packed | diff (dirty) | 90.1 ms | 1.49 s | 888.3 ms | 10x |
| large-packed | branch -a -vv | 3.7 ms | 41.0 ms | 11.4 ms | 3x |
| large-packed | add 500 new files | 30.2 ms | 8.78 s | 1.20 s | 40x |
| large-packed | commit 500 staged files | 70.1 ms | 1.17 s | 1.30 s | 19x |
| large-packed | switch other (30 commits back) | 108.9 ms | 2.26 s | 1.29 s | 12x |
| large-packed | merge side (no-ff clean) | 207.3 ms | n/a | 3.36 s | 16x |
| large-packed | stash push | 387.2 ms | 18.27 s | 2.12 s | 5x |
| large-loose | process start (--version / --help) | 1.9 ms | 16.5 ms | 11.3 ms | 6x |
| large-loose | status (clean) | 50.0 ms | 4.82 s | 942.2 ms | 19x |
| large-loose | log -n 20 | 4.0 ms | 11.7 ms | 10.6 ms | 3x |
| large-loose | log --oneline (full) | 55.7 ms | 5.51 s | 890.4 ms | 16x |
| large-loose | log --stat -n 20 | 12.8 ms | 292.3 ms | 146.2 ms | 11x |
| large-loose | show HEAD | 4.3 ms | 83.5 ms | 33.2 ms | 8x |
| large-loose | diff HEAD~50 HEAD (large) | 37.6 ms | 890.3 ms | 363.2 ms | 10x |
| large-loose | status (dirty) | 74.3 ms | 4.99 s | 1.17 s | 16x |
| large-loose | diff (dirty) | 101.4 ms | 1.53 s | 927.3 ms | 9x |
| large-loose | branch -a -vv | 3.4 ms | 12.7 ms | 10.7 ms | 3x |
| large-loose | add 500 new files | 30.6 ms | 4.19 s | 830.8 ms | 27x |
| large-loose | commit 500 staged files | 50.3 ms | 886.1 ms | 542.8 ms | 11x |
| large-loose | switch other (30 commits back) | 92.4 ms | 5.87 s | 785.9 ms | 9x |
| large-loose | merge side (no-ff clean) | 146.6 ms | 9.54 s | 3.85 s | 26x |
| large-loose | stash push | 270.1 ms | 6.81 s | 2.43 s | 9x |

mgit, spawn to first full paint (it draws nothing until its first load is done):

| repo | before | after |
|---|---:|---:|
| small | 752 ms | 95 ms |
| medium | 3.75 s | 271 ms |
| large-packed | 3.55 s | 745 ms |

(before, small/medium: same measurement with the pre-branch binary; large-loose
8.9 s before, 741 ms after.)

The full table (all cases and all four repositories) is what the script prints.

## Root causes

1. **Every object read re-read whole pack files.** `GIT_object.read(gitdir, id)`
   makes a fresh `GIT_pack.Cache`, and a fresh cache read the entire `.idx` and the
   entire `.pack` to find one object. About fifty call sites read objects this way,
   many of them in loops (walking HEAD's tree, branches, merge, checkout). `status`
   on a 4 000-file repository read about 10 GB; time grew with objects x pack size,
   which is why large repositories were 200x slower than git (status 15 s against
   70 ms) while small ones were only 5-10x.
2. **The work tree was walked three times, and `.git` was walked with it.**
   `fs.walk` lists every entry below the root, `.git/objects` included; status
   walked once for the file list and once for `.gitignore` files, and asked four
   `stat` questions per file; `mode_pass` asked five more. A loose-object repository
   spent most of its time listing its own object store.
3. **The HEAD tree and the index were read twice** (the library's status, then the
   git-format layer on top of it).
4. **`fs.makedirs` stats every ancestor from `/`** and was called for every object,
   ref and file written: ten `stat` calls per file written by checkout or `add`.
5. **Inflate was a bit-at-a-time Huffman walk** (one call per bit): 16 MB/s.
6. **A stale `$PWD`.** 1git took its directory from `$PWD`, so a parent that does
   not export it (a Python subprocess, make, an editor) ran the command in the
   parent's repository. Found when the benchmark's own `add`/`merge`/`checkout -b`
   landed in the repository the benchmark was started from. Fixed here; see below.

## What was fixed (no behaviour change)

Output is byte-identical: `compare_diff` (2201 forms), `compare_log` (2228),
`compare_show` (7818), `compare_status` (932), `compare_write` (635 cases) and
`compare_merge` (364 cases) all pass against git 2.55.0. (`compare.sh` on the
medium repository differs in `refs/remotes/*` listing before and after alike.)

- `GIT_pack.Cache` serves its first 24 lookups by reading only the fanout table,
  the one slice of names, the one offset and a 16 KiB window of the entry
  (growing x4 until the entry fits), through `File.seek`; after 24 lookups it
  switches to reading each file once, whole, as before. A fresh cache per call
  therefore never reads a pack whole.
- Tree walks (status, gitstatus, `flatten_tree`), checkout writes, merge
  (`Ctx.packs`), commit-graph walks (`Graph.packs`) and `GIT_log.walk` share one
  cache per command; `GIT_log.walk` also stops reading each parent twice.
- `GIT_status.status_given` takes the HEAD map `gather` already has.
- `list_worktree` is its own walker: two system calls per entry, `.git` not
  entered; the `.gitignore` files come from that listing
  (`GIT_ignore.load_known`); `mode_pass` does one `stat`.
- `GIT_repository.ensure_dir` (one `stat`, then `makedirs` only if missing) at all
  write sites.
- `GIT_zlib`: codes of up to 9 bits are one table lookup on a 15-bit look-ahead,
  long matches copy in pieces, tables are built only for streams worth it.
  1.9x on large streams (16 to ~34 MB/s). Verified against Python's `zlib`
  (`t_inflate`, `t_inflate_at`).
- `git.m31` uses the physical current directory, not `$PWD`.

## Is mgit better optimised?

No. `mgit` calls the same library functions (it shows the same read/inflate/hash
profile) and its first paint took 3.7 s on the medium repository before this branch,
slower than `1git status`. It feels fast because it is one long-lived process:
the load is paid once, `GIT_watch` makes later refreshes cheap and the diff shown
is only the selected file's. `1git` pays process start plus a full load on every
command. The `tui` library is not on the hot path.

## What remains (and why)

Everything left is compute in code the m31 compiler and standard library emit,
not I/O or repeated work in this repository:

- **Process start is ~10 ms** against git's 2 ms, for every command (so a small
  repository's status is 15 ms against 4). It is m31's runtime, not 1git: a
  `print("hi")` program takes the same time. Measured causes: the scheduler
  zeroes a 4 MiB green-thread table at start (about 3 ms and 1000 page faults,
  `greenthread.c rt_gtstate_ensure`); exit joins the blocking-FFI monitor, which
  sleeps 5 ms between polls (`scheduler.c monitor_main`, 0-5 ms); `rt_run_program`
  polls for completion with `nanosleep(1 ms)`. Patching those three in a copy of
  the runtime took the trivial program from 10.4 ms to about 3 ms.
- **SHA-1 (`crypto.sha1digest`) runs at ~38 MB/s and inflate at ~34 MB/s.** Every
  object read is hash-verified, which is a stated property of this program, and
  that verification is 20-45% of `diff`, `log --stat`, `switch` and `merge`.
  `-O3 -flto -march=native` changes nothing: the cost is checked arithmetic,
  bounds checks and non-inlined runtime calls (`rt_bytes_push`, `rc_dec`,
  `rt_stack_check` run millions of times).
- **No module-level state.** A process-wide object cache keyed by `gitdir` would
  remove the remaining re-reads (merge and switch still read the same trees
  through `GIT_object.read`), but the language has none (`docs/FRICTION.md` s6);
  caches had to be threaded by hand through the hottest loops only.
- **Per-file system calls.** `fs` has no `lstat` that returns a mode, so "is it a
  link, and what is it" is two calls per entry; `makedirs` stats every ancestor;
  `File.read` after `File.seek` fills 64 KiB however little was asked for.
- Remaining ratios: status 10-20x on 20k files (git ~55 ms, 1git ~1 s), diff and
  `log --stat` 8-20x, merge 15-25x on large repositories (3.4-3.9 s), `log
  --oneline` of 5 000 commits 10-16x.
