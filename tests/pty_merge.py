#!/usr/bin/env python3
"""The merge UI of the compiled `ourgitui`, driven under a real pty against
disposable git fixtures this script builds and destroys itself. Real `git` is
the oracle both ways: what the UI leaves is read back with `git status`,
`ls-files -u`, `cat-file`, `reflog` and `fsck --strict`, and merges that real
git started are finished in the UI (and the other way round).

    python3 tests/pty_merge.py <ourgitui-binary> <scratch-dir>

Every `ok` / `FAIL` line is one check; the exit status says whether any failed.
"""
import os
import shutil
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_e2e as P  # noqa: E402  (main() there is guarded)

failures = 0
passed = 0


def check(name, condition, detail=""):
    global failures, passed
    if condition:
        passed += 1
        print("ok   " + name)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail)


def git(fx, *args):
    return P.git(fx, *args, env=P.GIT_ENV)


def write(fx, name, text):
    path = os.path.join(fx, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(fx, name):
    with open(os.path.join(fx, name)) as f:
        return f.read()


def commit_all(fx, message):
    git(fx, "add", "-A")
    git(fx, "commit", "-q", "-m", message)


def fsck_clean(fx):
    out, err, rc = git(fx, "fsck", "--strict")
    return rc == 0 and "error" not in out + err


BASE = "a\nb\nc\nd\ne\nf\ng\nh\n"
TWO = "a\nb\nOURS1\nd\ne\nf\ng\nOURS2\n"
THEIRS_TWO = "a\nb\nTHEIRS1\nd\ne\nf\ng\nTHEIRS2\n"


def fixture(root, name, base_files, side_files, main_files, diff3=False):
    """main and side both descend from one base commit and each changes files."""
    fx = P.make_fixture(root, name)
    if diff3:
        git(fx, "config", "merge.conflictstyle", "diff3")
    for k, v in base_files.items():
        write(fx, k, v)
    commit_all(fx, "base")
    git(fx, "checkout", "-q", "-b", "side")
    for k, v in side_files.items():
        if v is None:
            git(fx, "rm", "-q", k)
        else:
            write(fx, k, v)
    commit_all(fx, "side change")
    git(fx, "checkout", "-q", "main")
    for k, v in main_files.items():
        if v is None:
            git(fx, "rm", "-q", k)
        else:
            write(fx, k, v)
    commit_all(fx, "main change")
    return fx


def cursor_to(s, needle):
    """Select the outline row containing `needle`: go to the top, then down
    to that row's screen line (the first row is on line 1, under the border)."""
    for _ in range(14):
        s.send("k")
    for i, ln in enumerate(s.text().split("\n")):
        if needle in ln and ln.startswith("\u2502"):
            for _ in range(i - 1):
                s.send("j")
            return True
    return False


def open_merge_picker(s, key, branch):
    s.send("m")
    s.send(key)
    s.send(branch)
    s.send("\r")


def editor_script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


def start_server(root):
    """A throwaway smart-HTTP server (git http-backend under python's CGI
    handler) over `<root>/srv`; None if this machine has no http-backend."""
    exec_path = subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip()
    backend = os.path.join(exec_path, "git-http-backend")
    if not os.path.exists(backend):
        return None
    www = os.path.join(root, "www")
    os.makedirs(os.path.join(www, "cgi-bin"))
    wrapper = os.path.join(www, "cgi-bin", "git-http-backend-srv")
    with open(wrapper, "w") as f:
        f.write('#!/bin/sh\nexport GIT_PROJECT_ROOT="%s"\nexport GIT_HTTP_EXPORT_ALL=1\nexec "%s"\n' % (os.path.join(root, "srv"), backend))
    os.chmod(wrapper, 0o755)
    serve = os.path.join(root, "serve.py")
    with open(serve, "w") as f:
        f.write(
            "import http.server, os, sys\n"
            "os.chdir(sys.argv[2])\n"
            "class H(http.server.CGIHTTPRequestHandler):\n"
            "    cgi_directories = ['/cgi-bin']\n"
            "    def log_message(self, fmt, *args):\n"
            "        pass\n"
            "http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()\n"
        )
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    proc = subprocess.Popen([sys.executable, serve, str(port), www], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return proc, "http://127.0.0.1:%d/cgi-bin/git-http-backend-srv/repo.git" % port
        except OSError:
            time.sleep(0.1)
    proc.kill()
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: pty_merge.py <ourgitui-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # --- a clean merge from the menu: m n (no-ff), then m f (fast-forward) -------
    fx = fixture(root, "clean", {"f": BASE, "g": "g\n"}, {"g": "g side\n"}, {"f": "A\nb\nc\nd\ne\nf\ng\nh\n"})
    s = P.Session(binpath, fx)
    s.send("m")
    t = s.text()
    check("menu: m opens the merge menu with its keys", "merge a branch you pick" in t and "abort the merge" in t, t)
    s.send("n")
    t = s.text()
    check("menu: m n opens the branch picker, without the current branch", "(always a merge commit)" in t and "side" in t and "main" not in t.split("│ > ")[-1], t)
    s.send("side")
    s.send("\r")
    parents, _, _ = git(fx, "log", "-1", "--format=%p", "HEAD")
    side_tip, _, _ = git(fx, "rev-parse", "side")
    tree, _, _ = git(fx, "rev-parse", "HEAD^{tree}")
    status, _, _ = git(fx, "status", "--short")
    subject, _, _ = git(fx, "log", "-1", "--format=%s")
    check(
        "menu: m n side makes a two-parent merge commit (parent 2 = side), clean status, fsck --strict clean",
        len(parents.split()) == 2 and parents.split()[1] == side_tip[:7] and status == "" and fsck_clean(fx) and subject == "Merge branch 'side'",
        "parents=%r status=%r subject=%r" % (parents, status, subject),
    )
    both, _, _ = git(fx, "show", "HEAD:f")
    both_g, _, _ = git(fx, "show", "HEAD:g")
    check("menu: the merge commit holds both sides' changes", both.startswith("A\n") and both_g == "g side", "f=%r g=%r" % (both, both_g))
    rl, _, _ = git(fx, "reflog", "-1", "--format=%gs", "main")
    check("menu: the branch reflog says 'merge side: ...'", rl.startswith("merge side:"), rl)
    s.send("@")
    check("menu: the command log records 'merge --no-ff side'", "merge --no-ff side" in s.text(), s.text())
    s.send("\x1b")
    s.quit()

    fx = P.make_fixture(root, "ff")
    write(fx, "f", "1\n")
    commit_all(fx, "one")
    git(fx, "checkout", "-q", "-b", "side")
    write(fx, "f", "1\n2\n")
    commit_all(fx, "two")
    git(fx, "checkout", "-q", "main")
    s = P.Session(binpath, fx)
    open_merge_picker(s, "f", "side")
    head, _, _ = git(fx, "rev-parse", "HEAD")
    side_tip, _, _ = git(fx, "rev-parse", "side")
    status, _, _ = git(fx, "status", "--short")
    check("menu: m f fast-forwards when it can (HEAD = side, clean, fsck clean)", head == side_tip and status == "" and fsck_clean(fx) and read(fx, "f") == "1\n2\n", "head=%s side=%s" % (head, side_tip))
    rl, _, _ = git(fx, "reflog", "-1", "--format=%gs", "HEAD")
    check("menu: the fast-forward logs 'merge side: Fast-forward'", rl == "merge side: Fast-forward", rl)
    s.quit()

    fx = fixture(root, "ffonly", {"f": BASE}, {"f": "A\nb\nc\nd\ne\nf\ng\nh\n"}, {"f": BASE + "i\n"})
    s = P.Session(binpath, fx)
    before, _, _ = git(fx, "rev-parse", "HEAD")
    open_merge_picker(s, "o", "side")
    after, _, _ = git(fx, "rev-parse", "HEAD")
    check("menu: m o refuses a merge that is not a fast-forward and changes nothing", before == after and "refused" in s.text() and git(fx, "status", "--short")[0] == "", s.text())
    s.quit()

    # --- conflicts: banner, Unmerged section, per-hunk resolution -------------------
    fx = fixture(root, "conf", {"f": BASE, "k": "k\n"}, {"f": THEIRS_TWO}, {"f": TWO})
    s = P.Session(binpath, fx)
    open_merge_picker(s, "f", "side")
    t = s.text()
    status, _, _ = git(fx, "status", "--short")
    stages, _, _ = git(fx, "ls-files", "-u")
    check("conflict: the outline shows the MERGING banner and the Unmerged paths section", "MERGING (1 conflict)" in t and "Unmerged paths (1)" in t and "UU  f" in t, t)
    check("conflict: git agrees (UU f, three stages, MERGE_HEAD present)", status == "UU f" and len(stages.split("\n")) == 3 and os.path.exists(os.path.join(fx, ".git", "MERGE_HEAD")), "%r %r" % (status, stages))
    check("conflict: the file holds the markers git would write", "<<<<<<< HEAD\nOURS1\n=======\nTHEIRS1\n>>>>>>> side\n" in read(fx, "f"), read(fx, "f"))
    s.send("m")
    s.send("f")
    check("menu: m f during a merge says one is already under way", "already under way" in s.text() and "branch into" not in s.text(), s.text())
    cursor_to(s, "UU  f")
    s.send("\r")
    t = s.text()
    check("resolve: Enter on an unmerged path opens the view on conflict 1 of 2", "resolve f" in t and "(conflict 1 of 2)" in t and "> OURS1" in t and "  OURS2" in t, t)
    s.send("j")
    check("resolve: j moves to conflict 2 of 2", "(conflict 2 of 2)" in s.text(), s.text())
    s.send("k")
    s.send("a")
    check("resolve: a takes ours for conflict 1 and leaves 1 of 1", "(conflict 1 of 1)" in s.text() and "THEIRS1" not in s.text() and read(fx, "f").startswith("a\nb\nOURS1\nd"), s.text())
    s.send("u")
    check("resolve: u undoes it (file and view are back to 2 conflicts)", "(conflict 1 of 2)" in s.text() and read(fx, "f").count("<<<<<<<") == 2, s.text())
    s.send("a")
    s.send("B")
    fin = read(fx, "f")
    status, _, _ = git(fx, "status", "--short")
    stages, _, _ = git(fx, "ls-files", "-u")
    check(
        "resolve: a (ours) then B (both) settles the file: contents as chosen, staged by itself (git: M f, no stage 1/2/3)",
        fin == "a\nb\nOURS1\nd\ne\nf\ng\nOURS2\nTHEIRS2\n" and status == "M  f" and stages == "",
        "file=%r status=%r stages=%r" % (fin, status, stages),
    )
    t = s.text()
    check("resolve: the view closed, banner says no conflicts left, Unmerged section is gone", "resolve f" not in t and "no conflicts left" in t and "Unmerged paths" not in t, t)
    s.send("m")
    s.send("c")
    parents, _, _ = git(fx, "log", "-1", "--format=%p")
    mh = os.path.exists(os.path.join(fx, ".git", "MERGE_HEAD"))
    status, _, _ = git(fx, "status", "--short")
    side_tip, _, _ = git(fx, "rev-parse", "side")
    content, _, _ = git(fx, "show", "HEAD:f")
    check(
        "continue: m c commits the merge (two parents, parent 2 = side, state files gone, clean, fsck --strict clean)",
        len(parents.split()) == 2 and parents.split()[1] == side_tip[:7] and not mh and status == "" and fsck_clean(fx) and content.endswith("THEIRS2"),
        "parents=%r mh=%s status=%r" % (parents, mh, status),
    )
    subject, _, _ = git(fx, "log", "-1", "--format=%s")
    rl, _, _ = git(fx, "reflog", "-1", "--format=%gs", "main")
    check("continue: message from MERGE_MSG (comment lines stripped), reflog 'commit (merge): ...'", subject == "Merge branch 'side'" and rl.startswith("commit (merge): Merge branch 'side'"), "%r %r" % (subject, rl))
    s.quit()

    # theirs, base (diff3), navigation wraps
    fx = fixture(root, "conf3", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO}, diff3=True)
    s = P.Session(binpath, fx)
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    check("resolve: a diff3 file shows its base section, dimmed in place", "||||||| " in s.text() and "> c" in s.text(), s.text())
    s.send("z")
    check("resolve: z takes the base text for conflict 1", "(conflict 1 of 1)" in s.text() and read(fx, "f").startswith("a\nb\nc\nd\n"), s.text())
    s.send("b")
    fin = read(fx, "f")
    status, _, _ = git(fx, "status", "--short")
    check("resolve: b takes theirs for the last; file = base, then theirs; staged", fin == "a\nb\nc\nd\ne\nf\ng\nTHEIRS2\n" and status == "M  f", "%r %r" % (fin, status))
    s.quit()

    fx = fixture(root, "nobase", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    s = P.Session(binpath, fx)
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    before = read(fx, "f")
    s.send("z")
    check("resolve: z without diff3 says so and leaves the file alone", "no base text" in s.text() and read(fx, "f") == before, s.text())
    s.send("\x1b")
    check("resolve: Escape closes the view; the file still has its markers and is still unmerged", "resolve f" not in s.text() and git(fx, "status", "--short")[0] == "UU f", s.text())
    s.send("m")
    s.send("c")
    check("continue: m c with unmerged paths is refused, nothing committed", "refused" in s.text() and git(fx, "log", "-1", "--format=%s")[0] == "main change", s.text())
    s.send("c")
    s.send("f")
    check("commit overlay: finishing while paths are unmerged is refused", "unmerged paths remain" in s.text() and git(fx, "log", "-1", "--format=%s")[0] == "main change", s.text())
    s.send("a")
    s.quit()

    # --- $EDITOR from the view -----------------------------------------------------------
    fx = fixture(root, "edit", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    ed = os.path.join(root, "ed_resolve.sh")
    editor_script(ed, 'printf "a\\nmanual\\nz\\n" >"$1"')
    s = P.Session(binpath, fx, env=P.env_with_editor(ed))
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("e")
    time.sleep(0.8)
    s.drain(1.0)
    status, _, _ = git(fx, "status", "--short")
    stages, _, _ = git(fx, "ls-files", "-u")
    check(
        "edit: e runs $EDITOR on the file; once no markers remain it is staged by itself (git: M f, no unmerged stages)",
        read(fx, "f") == "a\nmanual\nz\n" and status == "M  f" and stages == "",
        "file=%r status=%r" % (read(fx, "f"), status),
    )
    t = s.text()
    check("edit: the view is closed and the client is back on the outline", "resolve f" not in t and "MERGING" in t, t)
    s.quit()

    fx = fixture(root, "edit2", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    ed2 = os.path.join(root, "ed_partial.sh")
    editor_script(ed2, "sed -i 's/OURS1/EDITED1/' \"$1\"")
    s = P.Session(binpath, fx, env=P.env_with_editor(ed2))
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("e")
    time.sleep(0.8)
    s.drain(1.0)
    t = s.text()
    check(
        "edit: an edit that leaves markers keeps the view open, re-read from disk, file still unmerged",
        "resolve f" in t and "> EDITED1" in t and "(conflict 1 of 2)" in t and git(fx, "status", "--short")[0] == "UU f",
        t,
    )
    s.quit()

    # --- abort -------------------------------------------------------------------------------
    fx = fixture(root, "abort", {"f": BASE, "k": "k\n"}, {"f": THEIRS_TWO, "k": "k side\n"}, {"f": TWO})
    s = P.Session(binpath, fx)
    head0, _, _ = git(fx, "rev-parse", "HEAD")
    open_merge_picker(s, "f", "side")
    s.send("m")
    s.send("a")
    check("abort: m a asks first", "discard its changes?" in s.text(), s.text())
    s.send("x")
    check("abort: any other key declines; the merge is still under way", os.path.exists(os.path.join(fx, ".git", "MERGE_HEAD")) and "MERGING" in s.text(), s.text())
    s.send("m")
    s.send("a")
    s.send("y")
    status, _, _ = git(fx, "status", "--short")
    head1, _, _ = git(fx, "rev-parse", "HEAD")
    rl, _, _ = git(fx, "reflog", "-1", "--format=%gs", "HEAD")
    check(
        "abort: y restores HEAD, index and tree (git: clean, no MERGE_HEAD), HEAD reflog 'reset: moving to HEAD', fsck clean",
        head0 == head1 and status == "" and not os.path.exists(os.path.join(fx, ".git", "MERGE_HEAD")) and read(fx, "f") == TWO and fsck_clean(fx) and rl == "reset: moving to HEAD",
        "status=%r rl=%r" % (status, rl),
    )
    check("abort: the banner and section are gone", "MERGING" not in s.text() and "Unmerged" not in s.text(), s.text())
    s.send("m")
    s.send("c")
    check("continue: m c with no merge says so", "no merge in progress" in s.text(), s.text())
    s.quit()

    # --- a path with no markers: modify/delete ------------------------------------------------
    for key, expect_exists, word in (("a", True, "ours"), ("b", False, "theirs")):
        fx = fixture(root, "md" + key, {"f": BASE, "k": "k\n"}, {"f": None}, {"f": BASE + "more\n"})
        s = P.Session(binpath, fx)
        open_merge_picker(s, "f", "side")
        cursor_to(s, "UD  f")
        s.send("\r")
        t = s.text()
        shown = "no conflict markers" in t
        s.send(key)
        status, _, _ = git(fx, "status", "--short")
        exists = os.path.exists(os.path.join(fx, "f"))
        stages, _, _ = git(fx, "ls-files", "-u")
        check(
            "whole file: a modify/delete conflict shows no markers; %s (%s) settles it and stages (git: no unmerged stages)" % (key, word),
            shown and exists == expect_exists and stages == "" and "resolved f" in s.text(),
            "exists=%s stages=%r status=%r t=%r" % (exists, stages, status, s.text()[:200]),
        )
        s.quit()

    # --- the other direction: a merge real git started, finished in the UI -------------------
    fx = fixture(root, "gitstart", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    subprocess.run(["git", "-C", fx, "merge", "side"], capture_output=True, env=P.GIT_ENV)
    s = P.Session(binpath, fx)
    t = s.text()
    check("interop: a merge started by git shows the banner and the Unmerged section", "MERGING (1 conflict)" in t and "UU  f" in t, t)
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("b")
    s.send("b")
    s.send("c")
    s.send("f")
    parents, _, _ = git(fx, "log", "-1", "--format=%p")
    status, _, _ = git(fx, "status", "--short")
    check(
        "interop: resolving in the UI and committing with the ordinary commit overlay (c f) makes git's merge commit (2 parents, MERGE_HEAD gone, clean)",
        len(parents.split()) == 2 and status == "" and not os.path.exists(os.path.join(fx, ".git", "MERGE_HEAD")) and fsck_clean(fx),
        "parents=%r status=%r" % (parents, status),
    )
    rl, _, _ = git(fx, "reflog", "-1", "--format=%gs", "main")
    subject, _, _ = git(fx, "log", "-1", "--format=%s")
    check("interop: that commit is a 'commit (merge)' with the MERGE_MSG subject", rl.startswith("commit (merge):") and subject == "Merge branch 'side'", "%r %r" % (rl, subject))
    s.quit()

    # the commit overlay's own editor starts from MERGE_MSG, not from a stale COMMIT_EDITMSG
    fx = fixture(root, "msgedit", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    seen = os.path.join(root, "seen_first_line")
    ed3 = os.path.join(root, "ed_msg.sh")
    editor_script(ed3, 'head -1 "$1" >"%s"; printf "Merge side, resolved by hand\\n" >"$1"' % seen)
    s = P.Session(binpath, fx, env=P.env_with_editor(ed3))
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("a")
    s.send("a")
    s.send("c")
    s.send("e")
    time.sleep(0.8)
    s.drain(1.0)
    first = open(seen).read().strip() if os.path.exists(seen) else None
    subject, _, _ = git(fx, "log", "-1", "--format=%s")
    parents, _, _ = git(fx, "log", "-1", "--format=%p")
    check(
        "commit overlay: e during a merge opens MERGE_MSG's text (not the previous commit's), and the edited message is the merge commit's",
        first == "Merge branch 'side'" and subject == "Merge side, resolved by hand" and len(parents.split()) == 2,
        "first=%r subject=%r parents=%r" % (first, subject, parents),
    )
    s.quit()

    # ... and a merge the UI started, finished by git
    fx = fixture(root, "uistart", {"f": BASE}, {"f": THEIRS_TWO}, {"f": TWO})
    s = P.Session(binpath, fx)
    open_merge_picker(s, "f", "side")
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("a")
    s.send("a")
    s.quit()
    out = subprocess.run(["git", "-C", fx, "merge", "--continue"], capture_output=True, text=True, env=dict(P.GIT_ENV, GIT_EDITOR="true"))
    parents, _, _ = git(fx, "log", "-1", "--format=%p")
    check(
        "interop: git merge --continue finishes the merge the UI started and resolved (2 parents, fsck clean)",
        out.returncode == 0 and len(parents.split()) == 2 and fsck_clean(fx),
        out.stdout + out.stderr,
    )

    # --- pull of a diverged branch: offer to merge --------------------------------------------
    srvroot = os.path.join(root, "pullsrv")
    os.makedirs(srvroot)
    server = None
    try:
        bare = os.path.join(srvroot, "srv", "repo.git")
        os.makedirs(bare)
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
        subprocess.run(["git", "-C", bare, "config", "http.receivepack", "true"], check=True)
        seed = P.make_fixture(srvroot, "seed")
        write(seed, "a", "a\n")
        write(seed, "b", "b\n")
        commit_all(seed, "base")
        git(seed, "push", "-q", bare, "main")
        server = start_server(srvroot)
        if server is None:
            print("note pull offer: skipped, no git-http-backend or the server did not start")
        else:
            url = server[1]
            cl = os.path.join(srvroot, "client")
            subprocess.run(["git", "clone", "-q", url, cl], check=True, capture_output=True)
            write(seed, "a", "a upstream\n")
            commit_all(seed, "upstream")
            git(seed, "push", "-q", bare, "main")
            write(cl, "b", "b local\n")
            git(cl, "add", "-A")
            git(cl, "commit", "-q", "-m", "local")
            local_tip, _, _ = git(cl, "rev-parse", "HEAD")
            upstream_tip, _, _ = git(seed, "rev-parse", "HEAD")
            s = P.Session(binpath, cl)
            s.send("F")
            s.send("p")
            time.sleep(1.5)
            s.drain(1.0)
            t = s.text()
            check("pull: a diverged branch offers to merge origin/main", "origin/main has diverged" in t and "merge it?" in t, t)
            s.send("x")
            check("pull: declining changes nothing (HEAD unmoved)", git(cl, "rev-parse", "HEAD")[0] == local_tip, s.text())
            s.send("F")
            s.send("p")
            time.sleep(1.5)
            s.drain(1.0)
            s.send("y")
            parents, _, _ = git(cl, "log", "-1", "--format=%H", "--min-parents=2")
            ps, _, _ = git(cl, "rev-list", "--parents", "-n1", "HEAD")
            status, _, _ = git(cl, "status", "--short")
            check(
                "pull: y merges the fetched tip: a two-parent commit of local and origin/main, clean, fsck --strict clean",
                ps.split()[1:] == [local_tip, upstream_tip] and status == "" and fsck_clean(cl) and read(cl, "a") == "a upstream\n" and read(cl, "b") == "b local\n",
                "parents=%r status=%r" % (ps, status),
            )
            s.quit()
    finally:
        if server is not None:
            server[0].kill()

    print("pty_merge: %d checks passed, %d failed" % (passed, failures))
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
