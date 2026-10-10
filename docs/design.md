# The interactive client — design, locked 2026-09-28

Written before stage 2 of `tui` exists, so the widget list there is
built toward this rather than guessed at afterward. Not implementation —
`git.m31` is stage 1 (read-only plumbing) and this waits on `tui`
stage 2/3 per its own README. Recorded now so the direction survives the
gap.

## The comparison this came from

Terminal git clients split into two families:

  - **Panel tools** — lazygit, gitui, tig. Fixed panes (files, branches,
    commits) you switch between, each showing one slice of the repository.
  - **Magit**, structurally different: one continuous, collapsible document.
    Untracked files, unstaged changes, staged changes, stashes, recent
    commits — all sections in a single scrollable view, expanded and
    collapsed in place, rather than screens you switch between. Staging is
    cursor position, not a mode: put point on a file, a hunk, or a line and
    stage exactly that. Every action with options — commit, rebase, push —
    opens a small menu of the real git flags as togglable switches, with the
    literal command shown before it runs.

Magit's one real cost is discoverability: it leans on `?`-summoned help and
users tolerating terse text. The panel tools do better here, with an
always-visible key-hint footer.

This client takes Magit's structure and the panel tools' surface manners,
not a copy of either.

## Locked

  - **One primary view**: the collapsible document, not fixed panels. This
    is the surface the client is actually driven from.
  - **One optional side panel, a jump list — corrected 2026-09-28, this is
    not a filesystem tree.** It is a flat, navigable index of whatever the
    main document currently contains as entries: log commits, changed
    files, branches, stashes — not paths on disk. It toggles, shown or
    hidden by one key, never a fixed pane competing with the main view for
    width. It works two ways: selecting an entry jumps the main document to
    it, and scrolling the main document highlights the corresponding entry
    here — so it is as much a "where am I" indicator as a way in. Closer to
    a synced table of contents than a directory browser.
  - **Cursor-addressable staging**: line, hunk, file, or section, one key,
    uniform — whatever is under the cursor is what gets staged. No separate
    staging mode.
  - **Drill-down as the universal verb**: Enter on a commit, a stash, or a
    branch expands it in place (its diff, its log) rather than switching to
    a different screen. Recursive, with a back-stack.
  - **Base commands always visible at the bottom** — the panel tools' key
    footer, kept because Magit's willingness to make users learn keys first
    is its one real weakness. This shows the small, fixed set: stage, unstage,
    commit, push, pull, diff, quit — the things done on every visit.
  - **A which-key-style popup for everything else.** Base commands are
    always on screen; a command with its own options (commit, rebase, log
    filtering, branch operations) is reached by a prefix key that opens an
    overlay of what the *next* key does — labelled, not memorised — and for
    a command with real git flags behind it, that overlay is the transient
    menu: togglable switches, a live preview of the literal command, one key
    to run it. Depth is: footer shows the base verbs; pressing one that has
    follow-ups shows the which-key overlay of them; a follow-up with flags
    opens the transient. Nothing is ever hidden behind a key with no visible
    hint of what it does.

## What this needs from `tui`

Flagging these because they are library primitives, not client-specific
widgets, and belong in stage 2's scope rather than being built once inside
the git client and stuck there:

  - a **collapsible outline widget** for the primary document (nested
    sections, expand and collapse);
  - a **synced jump list**: a flat, selectable list bound to the outline
    widget's own entries, where selecting a row scrolls the document to it
    and scrolling the document highlights the corresponding row — two-way,
    not just a static index;
  - a **which-key overlay**: a small popup keyed by "what does the next
    keypress do", built from a list of (key, label) pairs;
  - a **transient menu**: the which-key overlay's sibling — togglable
    switches, a rendered command preview line, one key to confirm — built on
    top of the same overlay primitive rather than as a separate component;
  - a **diff view with an addressable cursor** down to the hunk and the
    line, since staging depends on knowing exactly what the cursor is over;
  - a **persistent footer region**, always reserved space, independent of
    whatever the main view is currently showing.

None of this is scoped or estimated yet — this is the shape, not the plan.
Revisit once `tui` stage 2 lands and `lib/term.m31` exists.

## The dependency chain to an actual client, 2026-09-28

Checked before starting: `lib/term.m31` already exists (raw mode, key
decoding, window size, one-write flush, read-with-timeout — everything
`tui`'s own README implies is still pending under "being written
separately", which is now stale). What's actually missing splits into three
independent pieces, plus one that depends on all of them:

  - **The `io`/`net`/`term` errno gap** `docs/errors-decision.md` §4 records
    B leaving open — orthogonal to everything else here, done in parallel.
  - **`git.m31` has no write path at all.** No `.git/index` (read or
    write), no object writing (blobs, trees, commits), no ref writing, no
    working-tree diff. Status, staging and committing all need this, and
    none of it is TUI work — it's plumbing this design has been silently
    assuming exists.
  - **`tui` stage 2** (styling layer) plus the primitives this design
    names (outline, jump list, which-key/transient, addressable diff
    cursor, footer) plus stage 3's actual remaining piece — the application
    loop joining the renderer to the *existing* `lib/term.m31`, since
    `term.m31` itself is done.
  - **The client itself** depends on both of the above and cannot start
    before they land — a second wave, not this one.

Deliberately not in this wave, each already a named, separate gap rather
than a silent omission: packfiles (`README.md`'s own stage 2 —
neither `oro` nor this repo needs it, since neither has ever been packed);
`.gitignore`; the dashboard-shaped widgets from `tui`'s original
stage-2 list (`Gauge`, `Sparkline`, `BarChart`, `Chart`) and mouse support,
none of which a keyboard-driven, document-shaped client needs.

## Starting the client, 2026-09-28

Checked before starting: no line-diff algorithm exists anywhere in this
codebase. `tui`'s `DiffView` only renders a `Hunk`/`Line` sequence —
nothing computes one from two texts. That's load-bearing for hunk-level
staging, Magit's whole interaction model, so it's a foundational piece on
its own rather than something the client builds inline.

Split into two tracks:

  - **The diff algorithm** — a line-based edit script (Myers or similar),
    grouped into hunks with context, matching `TUI_diff_view`'s existing
    `Hunk`/`Line` shape, plus git's own binary-file heuristic (a NUL byte
    in the first several KB) so a binary diff reports as one rather than
    garbling. Self-contained; the client doesn't need it to get started.
  - **The client** — the document (outline sections for untracked,
    unstaged, staged, recent commits, populated from `GIT_status.status()` and
    the existing log/object read side), whole-file stage/unstage (already
    buildable from `GIT_index.m31`/`GIT_object.m31`), commit via `$EDITOR` for the
    message (matching real git's own fallback when `-m` isn't given, and
    sidestepping a dependency on `TextInput`, which `tui` deferred for
    lack of a caller — this is that caller, later, not now), and the loop
    wiring the outline, the jump list, the footer and the which-key overlay
    together per the locked design above.

**Hunk-level diff display and staging wait on the diff-algorithm track**
and land as a follow-up once both exist — the client's first cut stages
whole files only, which is also where Magit itself starts before hunk
granularity.

**Also out of scope for this wave, each a separate, real gap:** push/pull
(no git network protocol — smart HTTP or SSH — exists in this codebase at
all); branch switching or checkout (no "write the working tree from a
tree" primitive exists); rebase or merge; packfiles (already tracked).

**Safety, same as the write-path work:** every test runs against a
disposable fixture built and destroyed by the test itself, with real `git`
as the oracle — never a real repository, including this one.

## Going remote, 2026-09-29: packfiles, then HTTP fetch, SSH held separately

Three things were named together as "make this tool complete" — packfiles,
smart HTTP, and SSH — and they are not the same size or the same kind of
risk, so they don't start together.

**Packfiles first, on their own.** Nothing else can produce anything usable
without them: a `clone`, a `fetch` and a `push` all traffic in packfiles,
and this already matters with no network involved at all — 6 of the 31
repositories on this project's own orogit server, and any repository a real
`git clone` ever produced, are unreadable by this tool today for exactly
this reason (`README.md`'s own long-standing table). Fully
independent of HTTP or SSH, and fully oracle-testable against real `git` in
disposable fixtures, the same discipline as everything else here. Reading
only for this pass -- writing a packfile (needed for `push`) is a named,
separate follow-up, the same shape as the index/object/ref read-before-write
split the rest of this repo already went through.

**Smart HTTP next, fetch/clone only, no push yet.** Builds on packfile
reading (a fetched pack is only useful once something can unpack it) but its
own wire protocol -- pkt-line framing, ref advertisement, want/have
negotiation -- is independently buildable against `lib/http.m31`, which
already exists. A freshly fetched pack is unpacked straight into loose
objects using the object-writing path that already exists, rather than also
building a packfile indexer in the same pass -- keeping a fetched pack as a
pack (what real git does, for space and time on a large repository) is a
later optimisation, not a correctness requirement.

**SSH is held, not simply sequenced after.** It is not a bigger version of
the same task -- it needs a real cryptographic transport (key exchange, host
verification, a cipher, a MAC) and public-key auth *before* the git protocol
even starts, and a subtle bug there is a vulnerability, not a wrong diff:
categorically different from "byte-for-byte matches real git." It is also
the lowest-value of the three right now -- this project's own orogit
deployment is Gitea, which serves HTTP remotes fine, so smart HTTP alone
reaches GitHub, GitLab and this project's own server with no SSH at all. It
gets its own scoping pass, the same way `docs/concurrency-decision.md`
exists as its own document, rather than riding in as a third parallel track.

## HTTPS, 2026-10-08

m31 v0.3.0 moved TLS out of `http` into a separate `https` module (`http.fetch`
answers `SchemeNeedsTls` for an `https://` URL), so the smart-HTTP transport
went from "`http://` only" to "both" by changing one call: every request in
`GIT_http_fetch.m31` and `GIT_http_push.m31` goes through
`GIT_http_fetch.exchange`, which is `https.fetch(request, trust: trust())`.
`parse_remote` keeps the scheme it was given and refuses everything else.

Decisions: (1) there is no insecure mode to expose, and none is added; the one
knob is `GITUI_HTTP_CA_FILE` (a PEM of roots, `tls.Trust.CaFile`), which is what
a self-hosted server with a private CA needs and what the tests use for their
throwaway CA. (2) The error enums gain `Certificate`, `Tls` and
`InsecureRedirect` (in `GIT_http_fetch`, and in `GIT_http_push`), derived from
`http.Error` by `GIT_http_fetch.classify`, so a refused certificate is not
reported as a generic network failure; everything else still maps to `Http`.
(3) Redirect policy is the standard library's, not ours: a request is retried
on the same origin up to five times, `http` to `https` on the same host is
followed, `https` to `http` never is.

## ssh remotes, 2026-10-10

SSH was "held" above until m31 v0.3.3 shipped an ssh client (`sshclient`,
`sshhosts`, `sshkey`, `sshauth`, `sshexec`) validated against OpenSSH. gitui
adds the transport on top of it (`GIT_ssh_transport.m31`): an exec channel
running `git-upload-pack` / `git-receive-pack` is wrapped as a `GIT_wire.Stream`,
so the v0 conversation `GIT_wire.m31` holds over HTTP runs unchanged, minus the
`# service=` preamble. `GIT_remote.m31` supplies the pure parts (URLs,
`insteadOf`, the `~/.ssh/config` subset); `GIT_pull.pull_ssh` and the push in
`GIT_ui_remote.m31` choose the transport from the `origin` URL.

Decisions: (1) trust on first use is the user's, never the program's: an
unknown host is `Error.UnknownHost(PendingHost)` carrying the key the server
presented (`ssh.presented_host_key`), the UI asks, and only `y` records it
(`sshhosts.add`, hashed when `HashKnownHosts yes` applies to the host). A
changed key is a refusal with no override from the UI. (2) The library call has
no read timeout, so gitui first connects and waits up to 15 s for the server's
banner (an ssh server speaks first), bounding a silent server. A watchdog thread
was rejected: m31 has no select or cancel, and the program waits for every
spawned thread, so a parked or sleeping watchdog would stall exit. A server that
sends the banner and then stalls, or a TCP connect that never answers, is not
bounded. (3) The environment overrides
`GITUI_SSH_IDENTITY` and `GITUI_SSH_KNOWN_HOSTS` exist for the tests and for
unusual setups; nothing reads a password from anywhere, and an encrypted key or
a missing key ends in a message that names `https://` as the alternative.

## SHA-256 and the revision grammar, 2026-10-10

Both were "not done" in the README; the maintainer decided they are needed, and
each has its own audit or design note in the code.

**SHA-256** (`GIT_hash.m31`). An object name's width is the one thing that
changes, so the decision was where the algorithm comes from: not a global, not a
parameter threaded through every caller, but (1) the id's own length wherever an
id is in hand (40 digits is SHA-1, 64 is SHA-256) and (2) the repository's
`extensions.objectFormat`, read once, where there is no id yet (hashing a new
object, a zero id, a pack trailer). The entry points refuse, by name, every
repository extension this program does not implement instead of reading such a
repository wrongly. On the wire the client echoes `object-format=<fmt>` and
refuses a remote of the other format before anything moves, over HTTP and ssh
alike (`FormatMismatch`); there is no protocol v2, so `ls-refs` and `fetch`
arguments do not arise. `TEST_HASH=sha256 bash tests/test.sh` runs every fixture
of every family as SHA-256, so the second hash is not a separate, thinner suite.

**Revisions** (`GIT_revparse.m31`, `docs/revisions-audit.md`). The audit found
that cursor and picker flows hand the engines full ids, and that three entries
take free text: the range prompt, the rebase todo and the CLI. The module follows
git's `object-name.c` in order (the order is part of the grammar's meaning: a
branch `cafe` beats an object `cafe...`), and refuses what it cannot do (dates in
`@{...}`, GNU regex escapes) with an error, never a different answer. Its
oracle is `git rev-parse` / `git rev-list` over a fixture built to hit the special
cases, plus a seeded fuzzer.

## What this deliberately does not decide yet

  - Exact keybindings (mnemonic, one key per base verb, is the only
    constraint fixed so far).
  - Colour/theme (waits on `tui`'s styling layer).
  - Whether jump-list entries carry a status marker (modified, untracked,
    ahead/behind) or are plain labels — a real decision, deferred rather
    than defaulted.
  - Whether the jump list is always one flat list or nests when the document
    does (a file entry nested under the commit that touches it, say).
  - How undo/redo of staging works, if at all — Magit leans on Emacs' undo,
    which has no equivalent here.

## m31 0.4.0, 2026-10-10

m31 v0.4.0 grouped the standard library into folders (`import net.http;`,
`import encoding.base64;`) and made `m31c lint` a gate, so gitui follows the
new naming rules: booleans start with is_/has_/did_/should_, abbreviations are
spelled out, and short names became real ones. Nothing about the design
changed. `RENAMES.md` lists every old public name next to its new one.
