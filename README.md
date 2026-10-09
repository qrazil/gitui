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
| `GIT_sha1.m31` | SHA-1 (FIPS 180-4), incremental and one-shot |
| `GIT_zlib.m31` | DEFLATE inflate (RFC 1951) and the zlib wrapper (RFC 1950), with Adler-32, from a mid-file offset as well as from the front |
| `GIT_object.m31` | the object store: the header, the SHA-1 check, trees, commits, tags -- loose or, via `GIT_pack.m31`, packed, through the one `read` |
| `GIT_pack.m31` | packfiles: `.idx` v2, the pack's own object encoding, `OBJ_OFS_DELTA`/`OBJ_REF_DELTA` delta-chain resolution |
| `GIT_refs.m31` | HEAD, `refs/**`, `packed-refs`, symbolic refs, `rev-parse`'s DWIM |
| `GIT_repository.m31` | where the files are: `.git` as a file, and a linked worktree's `commondir` |
| `git.m31` | the read-only CLI |
| `GIT_index.m31` | `.git/index`: read, write, a fresh entry from `fs.stat` |
| `GIT_status.m31` | working-tree status: staged, unstaged, untracked |
| `GIT_checkout.m31` | local branches, switching branches (the working-tree-writing primitive: refuses on local changes in the way), creating a branch |
| `GIT_hunks.m31` | `lib/diff.m31`'s edit script, grouped into qrazil/tui's `TUI_diff_view.Hunk`/`Line` with context; `spans` is the one definition of where each hunk starts and ends |
| `GIT_patch.m31` | apply or revert exactly one hunk of a diff, byte for byte -- what the diff view's `s`/`u` stage and unstage with |
| `GIT_log.m31` | the commit-history walk, shared by `git.m31 -log` and `gitui.m31` |
| `GIT_client.m31` | the interactive client's top: `State` (the layer tower's last floor), key dispatch, drawing the overlay stack over the body, the `$EDITOR` handoff (no top-level statements, so it is importable and testable) |
| `GIT_ui_core.m31` | the shared `Core`, the `Overlay` interface (`handle_key`, `render`, `hints`), **the key table** that drives dispatch, the footer and `?` alike, and the command-log ring buffer |
| `GIT_ui_model.m31` | the pure model: outline rows, commit-file diffs, commit template, editor choice |
| `GIT_ui_outline.m31`, `GIT_ui_diff.m31`, `GIT_ui_commit.m31`, `GIT_ui_branch.m31`, `GIT_ui_remote.m31` | one layer per concern (stage/unstage/discard/stage-all, hunk staging, commit and amend, branches, push and pull), each embedding the one below it, plus that concern's overlays |
| `GIT_ui_help.m31`, `GIT_ui_log.m31`, `GIT_ui_search.m31`, `GIT_ui_picker.m31`, `GIT_ui_panel.m31` | the `?` key help, the `@` command log, `/` search, the reusable fuzzy-filter picker, and the shared frame/clamp drawing helpers |
| `gitui.m31` | the interactive client's thin driver: parses a path, runs `TUI_app.Loop` |
| `GIT_http_fetch.m31` | git's smart-HTTP protocol, v0 fetch/clone only: pkt-line framing, the ref advertisement, want/have negotiation, side-band-64k demultiplexing, and pack checksum verification, over `lib/https.m31` (`http://` and `https://`) |
| `GIT_pack_write.m31` | writes packfiles (whole objects, stored-zlib) and computes the object set a push must send, like `git rev-list --objects tips ^known` |
| `GIT_http_push.m31` | smart-HTTP v0 push (`git-receive-pack`): fast-forward-only, `report-status`, HTTP Basic auth from the URL's userinfo or `GITUI_HTTP_USER`/`GITUI_HTTP_PASSWORD` |
| `GIT_config.m31` | a minimal `.git/config` reader (`remote.origin.url` and friends) |
| `deps` | the project manifest: name, version and the pinned qrazil/tui commit (`deps.lock` records what was fetched) |
| `scripts/build-gitui.sh` | builds `gitui.m31`; its `import tui.TUI_app;` lines resolve through `deps`, so nothing is staged or copied |
| `tests/t_*.m31` | test programs, each printing what a Python oracle prints, or asserting against its own expectations |
| `tests/oracles/oracle_*.py` | the oracles: `hashlib`, `zlib`, and a from-scratch format reader |
| `tests/pty_e2e.py` | drives `ourgitui` under a real pty against disposable fixtures, real `git` as the oracle |
| `scripts/compare.sh` | every command beside the real `git`, compared octet for octet |
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
from `origin` (see "Pull" below). Merge and rebase are each a named,
deliberate gap in `docs/design.md`, not an oversight here.

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
| `c` | outline | commit overlay: `e` edit, `f` finish, `A` amend, `a` abort |
| `b` | outline | branch overlay: `c` check out, `/` fuzzy-pick a branch, `n` new, `a` abort |
| `P` / `F` | outline | push / pull which-key, `p` runs it |
| `/` | outline (log included) | search; smart-case: all lower case ignores case, a capital matches exactly. `Enter` runs it, `Esc` cancels |
| `n` / `N` | outline (log included) | next / previous match, wrapping |
| `g` / `R` | outline | re-read the repository (`r` is no longer bound) |
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
SSH and protocol v2 are named, separate gaps, not oversights: v0 is
universally supported as a fallback even where v2 is preferred, and
`https://` is supported (see "HTTPS" below).

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

## Smaller things this does not do

  - **The revision grammar.** `HEAD~3`, `main^2`, `v1^{tree}`, `@{upstream}`,
    `:/message`. `rev-parse` takes a ref, a full object name or an
    unambiguous prefix. `GIT_refs.peel` follows an annotated tag to its commit,
    because `log v1` needs it.
  - **Configuration.** No `.git/config` is read at all, so no `.mailmap`, no
    `core.abbrev` (seven digits, fixed), no `log.decorate`, no
    `core.quotePath` (on, as it is by default), no colour, no pager, no
    `i18n.logOutputEncoding`.
  - **Hunk-level diff against the working tree.** `GIT_status.m31` reports
    whole-file staged/unstaged/untracked; `GIT_hunks.m31` can compute a
    line-level diff between any two texts, but nothing yet wires the two
    together into a `diff`-shaped view of the working tree, or `ls-files`.
  - **Writing beyond what `gitui.m31` does.** The write path (index,
    objects, refs) is real and checked against real `git`, but there is no
    standalone write-side CLI — only the interactive client and the tests
    exercise it today.
  - **The commit graph, bitmaps, alternates, replace refs, shallow clones,
    submodules, SHA-256 repositories.** All ignored; a SHA-256 repository
    would be refused by the length check rather than misread.
  - **`git log`'s other orderings.** The walk is git's date-ordered queue.
    `--topo-order`, `--reverse`, path limiting and `--graph` are not there.

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
`https://` (see "HTTPS" below).

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
remote one (`not a fast-forward; merge/rebase not supported yet`). The fetched
objects are kept in that last case.

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
