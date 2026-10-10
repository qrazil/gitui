"""pty cases for blame (B), file history (H), undo/redo (Z), tags (T), the
ahead/behind decoration, `u` (push and set the upstream) and the outline's
auto-refresh. Kept out of `pty_e2e.py` so that file only gains a two-line hook;
`pty_e2e.main` calls `run(ctx)` with its own helpers.

Every fixture is disposable and built with fixed author/committer identities
and dates; real `git` is the oracle (and `git fsck --strict` runs on what the
client changed). Both directions are covered: the client continues state real
git created (reflogs, tags, upstream config) and real git continues state the
client created.
"""
import functools
import http.server
import os
import subprocess
import sys
import threading
import time


def run(ctx):
    binpath, root = ctx.binpath, ctx.root
    Session, make_fixture, git, GIT_ENV = ctx.Session, ctx.make_fixture, ctx.git, ctx.GIT_ENV

    def check(name, condition, detail=""):
        if condition:
            ctx.ok(name)
        else:
            ctx.fail(name, detail)

    def commit(fx, name, text, message, when):
        path = os.path.join(fx, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        env = dict(GIT_ENV)
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = "%d +0000" % when
        git(fx, "add", "-A", env=env)
        git(fx, "commit", "-q", "-m", message, env=env)

    def wait_for(session, predicate, timeout=4.0):
        end = time.time() + timeout
        while time.time() < end:
            session.drain(0.3)
            if predicate(session.text()):
                return True
        return predicate(session.text())

    def type_text(session, text):
        for ch in text:
            session.send(ch)

    BASE = 1700000000

    # ---------------------------------------------------------------- blame
    fx = make_fixture(root, "blame")
    commit(fx, "a.txt", "one\ntwo\nthree\n", "first", BASE)
    commit(fx, "a.txt", "one\nTWO\nthree\nfour\n", "second", BASE + 100000)
    commit(fx, "other.txt", "x\n", "unrelated", BASE + 200000)
    commit(fx, "a.txt", "one\nTWO\nthree\nfour\nfive\n", "third", BASE + 300000)
    with open(os.path.join(fx, "a.txt"), "a") as f:
        f.write("six\n")  # unstaged: row 2 is a.txt
    with open(os.path.join(fx, "untracked.txt"), "w") as f:
        f.write("u\n")
    out, _, _ = git(fx, "blame", "--line-porcelain", "HEAD", "--", "a.txt")
    expected = []  # (commit, boundary, text)
    cur = None
    for line in out.split("\n"):
        if line.startswith("\t"):
            expected.append((cur[0], cur[1], line[1:]))
        elif len(line.split(" ")[0]) in (40, 64) and all(c in "0123456789abcdef" for c in line.split(" ")[0]):
            cur = [line.split(" ")[0], False]
        elif line == "boundary":
            cur[1] = True
    s = Session(binpath, fx)
    s.send("j")  # untracked file row
    s.send("B")
    check("blame: B on an untracked file refuses", "untracked" in s.text() and "blame a.txt" not in s.text(), s.text())
    s.send("jj")  # section Unstaged, then a.txt
    s.send("B")
    t = s.text()
    check("blame: B opens the overlay for the file under the cursor", "blame a.txt @ HEAD" in t, t)
    # HEAD content blamed: five lines (the unstaged "six" is not committed)
    rows_ok = True
    detail = ""
    for commit_id, boundary, text in expected:
        prefix = ("^" + commit_id[:6]) if boundary else commit_id[:7]
        if not any(prefix in row and (text + " ") in (row + " ") for row in t.split("\n")):
            rows_ok = False
            detail = "missing %r %r in\n%s" % (prefix, text, t)
    check("blame: every line shows the commit git blame attributes it to", rows_ok and len(expected) == 5, detail)
    s.send("G")
    s.send("\r")
    t = s.text()
    last = expected[-1][0]
    check("blame: Enter opens the commit of the line under the cursor, with its diff of the file", "commit " + last in t and "third" in t and "+ five" in t, t)
    s.send("q")
    check("blame: q closes the commit view back to the blame", "blame a.txt @ HEAD" in s.text(), s.text())
    s.send("g")
    s.send(",")
    parent, _, _ = git(fx, "rev-parse", expected[0][0] + "^")
    check("blame: line 1 is from the root commit, which has no parent", "root commit" in s.text() and "@ HEAD" in s.text(), s.text())
    s.send("jjj")  # line 4 "four": introduced by "second"
    s.send(",")
    second_parent, _, _ = git(fx, "rev-parse", expected[3][0] + "^")
    check("blame: , re-blames at the parent of the line's commit", "blame a.txt @ " + second_parent[:7] in s.text(), s.text())
    s.send("\x7f")
    check("blame: backspace goes back to the previous blame", "blame a.txt @ HEAD" in s.text(), s.text())
    s.send("q")
    check("blame: q closes the overlay", "blame a.txt" not in s.text(), s.text())

    # history
    s.send("H")
    log_out, _, _ = git(fx, "log", "--format=%h", "--", "a.txt")
    hist_ids = log_out.split("\n")
    t = s.text()
    positions = [t.find(h[:7]) for h in hist_ids]
    check("history: H lists exactly the commits git log -- a.txt does, in order", len(hist_ids) == 3 and all(p >= 0 for p in positions) and positions == sorted(positions) and "unrelated" not in t, t)
    s.send("j")
    s.send("B")
    second_id, _, _ = git(fx, "rev-parse", hist_ids[1])
    check("history: B blames the file as of the commit under the cursor", "blame a.txt @ " + second_id[:7] in s.text(), s.text())
    s.send("q")
    s.send("\r")
    check("history: Enter shows the commit and its change to the file", "commit " + second_id[:7] in s.text() and "second" in s.text(), s.text())
    s.send("q")
    s.send("q")
    # from a commit's file row (diff view), H and B use that commit
    s.send("g")
    rc = s.quit()
    check("blame/history: the client exits cleanly afterwards", rc == 0, "rc=%r" % rc)
    fsck_out, _, fsck_rc = git(fx, "fsck", "--strict")
    check("blame/history: read-only; git fsck --strict is clean", fsck_rc == 0, fsck_out)

    # ----------------------------------------------------------------- undo
    fx = make_fixture(root, "undo")
    commit(fx, "a.txt", "1\n", "c1", BASE)
    commit(fx, "a.txt", "1\n2\n", "c2", BASE + 10)
    commit(fx, "b.txt", "b\n", "c3", BASE + 20)
    c1, _, _ = git(fx, "rev-parse", "HEAD~2")
    c2, _, _ = git(fx, "rev-parse", "HEAD~1")
    c3, _, _ = git(fx, "rev-parse", "HEAD")
    s = Session(binpath, fx)
    s.send("Z")
    t = s.text()
    check("undo: Z shows what would be undone and the note about the worktree", "undo: commit: c3" in t and "not undoable" in t, t)
    s.send("y")
    head, _, _ = git(fx, "rev-parse", "HEAD")
    status_out, _, _ = git(fx, "status", "--short")
    check("undo: y moves the branch back to c2 and the worktree with it (git: HEAD = c2, clean)", head == c2 and status_out == "" and not os.path.exists(os.path.join(fx, "b.txt")), "head=%r status=%r" % (head, status_out))
    reflog_out, _, _ = git(fx, "reflog", "-1", "--format=%gs")
    check("undo: git reflog records 'undo: commit: c3' for the move", reflog_out == "undo: commit: c3", reflog_out)
    s.send("@")
    check("undo: the command log has the undo", "undo: commit: c3" in s.text(), s.text())
    s.send("q")
    s.send("Z")
    s.send("r")
    t = s.text()
    check("undo: r shows the redo side", "redo: commit: c3" in t, t)
    s.send("y")
    head, _, _ = git(fx, "rev-parse", "HEAD")
    check("undo: redo brings c3 back (git: HEAD = c3, b.txt restored)", head == c3 and os.path.exists(os.path.join(fx, "b.txt")), "head=%r" % head)
    s.send("Z")
    s.send("r")
    check("undo: after the redo there is nothing left to redo", "Nothing to redo" in s.text(), s.text())
    s.send("\x1b")
    # a local edit to a file the undo would touch refuses and changes nothing
    with open(os.path.join(fx, "b.txt"), "a") as f:
        f.write("local edit\n")
    s.send("Z")
    s.send("y")
    head, _, _ = git(fx, "rev-parse", "HEAD")
    with open(os.path.join(fx, "b.txt")) as f:
        kept = f.read()
    check("undo: a dirty file in the way refuses; HEAD and the edit are untouched", head == c3 and kept == "b\nlocal edit\n", "head=%r kept=%r" % (head, kept))
    s.send("\x1b")
    rc = s.quit()
    git(fx, "checkout", "-q", "--", "b.txt")
    out, err, rc2 = git(fx, "commit", "-q", "--allow-empty", "-m", "after", env=GIT_ENV)
    fsck_out, _, fsck_rc = git(fx, "fsck", "--strict")
    check("undo: real git continues the repository the client moved (commit works, fsck --strict clean)", rc2 == 0 and fsck_rc == 0, "%s %s %s" % (err, fsck_out, rc2))

    # ----------------------------------------------------------------- tags
    fx = make_fixture(root, "tags")
    commit(fx, "a.txt", "1\n", "c1", BASE)
    commit(fx, "a.txt", "1\n2\n", "c2", BASE + 10)
    git(fx, "tag", "old", "HEAD~1", env=GIT_ENV)
    git(fx, "tag", "-a", "-m", "release one", "rel1", "HEAD~1", env=GIT_ENV)
    head, _, _ = git(fx, "rev-parse", "HEAD")
    s = Session(binpath, fx)
    s.send("T")
    t = s.text()
    check("tags: T lists existing tags, annotated ones with their message", "old" in t and "rel1" in t and "release one" in t, t)
    s.send("n")
    type_text(s, "v1")
    s.send("\r")
    out, _, _ = git(fx, "rev-parse", "v1")
    check("tags: n creates a lightweight tag at HEAD (git: v1 = HEAD)", out == head, out)
    s.send("a")
    type_text(s, "v2")
    s.send("\r")
    type_text(s, "second release")
    s.send("\r")
    kind, _, _ = git(fx, "cat-file", "-t", "v2")
    msg, _, _ = git(fx, "tag", "-n1", "v2")
    peeled, _, _ = git(fx, "rev-parse", "v2^{commit}")
    check("tags: a creates an annotated tag (git: a tag object, message kept, points at HEAD)", kind == "tag" and "second release" in msg and peeled == head, "%s %s %s" % (kind, msg, peeled))
    fsck_out, _, fsck_rc = git(fx, "fsck", "--strict")
    check("tags: git fsck --strict accepts the tag the client wrote", fsck_rc == 0, fsck_out)
    s.send("\x1b")
    s.send("@")
    t = s.text()
    check("tags: the command log has both creations", "tag v1" in t and "tag -a v2" in t, t)
    s.send("q")
    s.send("T")
    s.send("n")
    type_text(s, "bad name")
    s.send("\r")
    out, _, _ = git(fx, "tag", "-l", "bad*")
    check("tags: an invalid name is refused and nothing is written", out == "" and "bad name" in s.text(), s.text())
    # delete: list is sorted -- old, rel1, v1, v2 -- v1 is the third
    s.send("jj")
    s.send("d")
    type_text(s, "y")
    s.send("\r")
    names, _, _ = git(fx, "tag", "-l")
    check("tags: d then y deletes the tag under the cursor (git tag -l agrees)", names.split("\n") == ["old", "rel1", "v2"], names)
    s.send("d")
    s.send("\r")  # empty answer: cancelled
    names2, _, _ = git(fx, "tag", "-l")
    check("tags: d without y keeps the tag", names2 == names, names2)
    s.send("\x1b")
    rc = s.quit()
    check("tags: the client exits cleanly", rc == 0, "rc=%r" % rc)

    # --------------------------------------------- ahead / behind decoration
    origin = os.path.join(root, "origin.git")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", origin], check=True)
    seed = make_fixture(root, "seed")
    commit(seed, "a.txt", "1\n", "base", BASE)
    git(seed, "remote", "add", "origin", origin)
    git(seed, "push", "-q", "origin", "main", env=GIT_ENV)
    fx = os.path.join(root, "track")
    subprocess.run(["git", "clone", "-q", origin, fx], check=True)
    commit(fx, "l1.txt", "l\n", "local one", BASE + 10)
    commit(fx, "l2.txt", "l\n", "local two", BASE + 20)
    commit(seed, "r1.txt", "r\n", "remote one", BASE + 30)
    git(seed, "push", "-q", "origin", "main", env=GIT_ENV)
    git(fx, "fetch", "-q", "origin")
    want, _, _ = git(fx, "for-each-ref", "--format=%(upstream:track)", "refs/heads/main")
    s = Session(binpath, fx)
    t = s.text()
    check("ahead/behind: git says " + want, want == "[ahead 2, behind 1]", want)
    check("ahead/behind: the header shows it", "on main @" in t and "[ahead 2, behind 1]" in t.split("on main @")[1].split("\n")[0], t)
    branch_row = [row for row in t.split("\n") if "* main" in row]
    check("ahead/behind: the Branches row shows it", branch_row and "[ahead 2, behind 1]" in branch_row[0], t)
    s.send("b")
    s.send("/")
    check("ahead/behind: the branch picker shows it", "[ahead 2, behind 1]" in s.text().split("check out a branch")[-1], s.text())
    s.send("\x1b")
    s.send("\x1b")
    rc = s.quit()

    # ------------------------------------- auto-refresh of the outline
    fx = make_fixture(root, "autorefresh")
    commit(fx, "a.txt", "1\n", "first", BASE)
    commit(fx, "b.txt", "2\n", "second", BASE + 10)
    s = Session(binpath, fx)
    idle = s.drain(2.6)
    check("auto-refresh: an idle second writes nothing to the terminal (no flicker)", idle == b"", repr(idle[:80]))
    s.send("jjjj")  # Untracked, Unstaged, Staged, Commits -> first commit row
    with open(os.path.join(fx, "a.txt"), "a") as f:
        f.write("edited elsewhere\n")
    with open(os.path.join(fx, "new.txt"), "w") as f:
        f.write("n\n")
    seen = wait_for(s, lambda t: "Unstaged changes (1)" in t and "Untracked files (1)" in t, 4.0)
    check("auto-refresh: an external edit and a new file appear without a key press", seen, s.text())
    s.send("\r")
    check("auto-refresh: the cursor stayed on the commit row (Enter unfolds it)", "Files changed" in s.text(), s.text())
    s.send("\r")
    git(fx, "add", "a.txt")
    seen = wait_for(s, lambda t: "Staged changes (1)" in t and "Unstaged changes (0)" in t, 4.0)
    check("auto-refresh: an external git add moves the file to Staged", seen, s.text())
    git(fx, "checkout", "-q", "-b", "other")
    seen = wait_for(s, lambda t: "on other @" in t, 4.0)
    check("auto-refresh: an external branch switch updates the header", seen, s.text())
    os.remove(os.path.join(fx, "new.txt"))
    seen = wait_for(s, lambda t: "Untracked files (0)" in t, 4.0)
    check("auto-refresh: an external delete disappears", seen, s.text())
    # while an overlay is open the outline is left alone, and catches up after
    s.send("?")
    with open(os.path.join(fx, "late.txt"), "w") as f:
        f.write("l\n")
    s.drain(2.4)
    check("auto-refresh: not while an overlay is open", "late.txt" not in s.text(), s.text())
    s.send("\x1b")
    seen = wait_for(s, lambda t: "late.txt" in t, 4.0)
    check("auto-refresh: it catches up once the overlay closes", seen, s.text())
    rc = s.quit()
    check("auto-refresh: the client exits cleanly", rc == 0, "rc=%r" % rc)

    # --------------------------------------------- push -u over smart HTTP
    backend = os.path.join(subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip(), "git-http-backend")
    if not os.path.exists(backend):
        print("gitui pty: push -u check skipped, no git-http-backend", file=sys.stderr)
        return
    pu_root = os.path.join(root, "pushu")
    os.makedirs(os.path.join(pu_root, "www", "cgi-bin"))
    os.makedirs(os.path.join(pu_root, "srv"))
    srv = os.path.join(pu_root, "srv", "repo.git")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", srv], check=True)
    git(srv, "config", "http.receivepack", "true")
    wrapper = os.path.join(pu_root, "www", "cgi-bin", "git-http-backend")
    with open(wrapper, "w") as f:
        f.write("#!/bin/sh\nexport GIT_PROJECT_ROOT=%s\nexport GIT_HTTP_EXPORT_ALL=1\nexec %s\n" % (os.path.join(pu_root, "srv"), backend))
    os.chmod(wrapper, 0o755)

    class Handler(http.server.CGIHTTPRequestHandler):
        cgi_directories = ["/cgi-bin"]

        def log_message(self, fmt, *args):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=os.path.join(pu_root, "www")))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    fx = make_fixture(root, "push-u")
    commit(fx, "a.txt", "1\n", "first", BASE)
    git(fx, "checkout", "-q", "-b", "feat")
    commit(fx, "a.txt", "1\n2\n", "on feat", BASE + 10)
    git(fx, "remote", "add", "origin", "http://127.0.0.1:%d/cgi-bin/git-http-backend/repo.git" % port)
    s = Session(binpath, fx)
    s.send("P")
    check("push -u: the push menu offers u", "set origin/<branch> as the upstream" in s.text(), s.text())
    s.send("u")
    time.sleep(1.0)
    s.drain()
    want, _, _ = git(fx, "rev-parse", "HEAD")
    got, _, _ = git(srv, "rev-parse", "-q", "--verify", "refs/heads/feat")
    remote_cfg, _, _ = git(fx, "config", "branch.feat.remote")
    merge_cfg, _, _ = git(fx, "config", "branch.feat.merge")
    tracking, _, _ = git(fx, "rev-parse", "-q", "--verify", "refs/remotes/origin/feat")
    check("push -u: the server has the branch, git config has remote/merge, the tracking ref is at HEAD", got == want and remote_cfg == "origin" and merge_cfg == "refs/heads/feat" and tracking == want, "got=%r remote=%r merge=%r tracking=%r" % (got, remote_cfg, merge_cfg, tracking))
    sb, _, _ = git(fx, "status", "-sb")
    check("push -u: git status -sb sees the upstream and nothing ahead", sb.split("\n")[0] == "## feat...origin/feat", sb)
    reflog_out, _, _ = git(fx, "reflog", "show", "refs/remotes/origin/feat", "-1", "--format=%gs")
    check("push -u: the tracking ref's reflog says 'update by push'", reflog_out == "update by push", reflog_out)
    s.send("@")
    check("push -u: the command log has the push and the upstream", "branch --set-upstream-to origin/feat" in s.text(), s.text())
    s.send("q")
    rc = s.quit()
    fsck_out, _, fsck_rc = git(srv, "fsck", "--full")
    check("push -u: the server repository is clean", fsck_rc == 0, fsck_out)
    httpd.shutdown()
