#!/usr/bin/env python3
"""Time 1git against real git on three repository sizes.

    python3 scripts/bench_1git.py [options]

    --one PATH      the 1git binary             (default ./1git)
    --git PATH      the reference git           (default: `git` on PATH)
    --runs N        timed runs per case          (default 7; min and median reported)
    --warmup N      untimed runs first           (default 1)
    --sizes LIST    small,medium,large-packed,large-loose  (default: all)
    --only SUBSTR   run only the cases whose name contains SUBSTR
    --medium-src X  what the medium repository is cloned from (path or URL;
                    default https://github.com/qrazil/m31)
    --work DIR      keep the generated repositories here (default: a fresh
                    temporary directory, removed at the end unless --keep)
    --files N --commits N   shape of the synthetic large repository
                    (default 20000 files, 5000 commits)
    --json FILE     also write the raw numbers as JSON
    --md FILE       also write the table as Markdown

Needs only python3 (3.6+) and a git for building the fixtures; nothing is
GNU-specific and every path comes from tempfile / argv. Output is read through
a pipe (git short-circuits some work when stdout is /dev/null). A case that
1git does not implement (non-zero exit where git succeeds) is reported as
"n/a" rather than timed.
"""
import argparse, json, os, shutil, statistics, subprocess, sys, tempfile, time

TIMEOUT = 120      # seconds per timed run; a run that exceeds it is recorded as that long, rc 124
HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, cwd, env, inp=None):
    env = dict(env, PWD=cwd)     # 1git (like a shell child) reads $PWD
    t = time.perf_counter()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, input=inp, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        p = subprocess.CompletedProcess(cmd, 124, b"", b"timeout after %ds" % TIMEOUT)
    return time.perf_counter() - t, p


def sh(cmd, cwd, env, inp=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, env=env, input=inp, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if check and p.returncode != 0:
        sys.exit("fixture command failed: %r\n%s" % (cmd, p.stderr.decode(errors="replace")))
    return p


def make_env(work):
    home = os.path.join(work, "home")
    os.makedirs(home, exist_ok=True)
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("GIT_"):
            del env[k]
    env.update(HOME=home, XDG_CONFIG_HOME=home, GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.path.join(home, "gitconfig"), GIT_PAGER="cat",
               GIT_AUTHOR_NAME="Bench", GIT_AUTHOR_EMAIL="bench@example.com",
               GIT_COMMITTER_NAME="Bench", GIT_COMMITTER_EMAIL="bench@example.com",
               GIT_AUTHOR_DATE="1700000000 +0000", GIT_COMMITTER_DATE="1700000000 +0000",
               LC_ALL="C", TERM="dumb", NO_COLOR="1")
    with open(env["GIT_CONFIG_GLOBAL"], "w") as f:
        f.write("[user]\n\tname = Bench\n\temail = bench@example.com\n[init]\n\tdefaultBranch = main\n")
    return env


def synth(path, git, env, nfiles, ncommits, loose):
    """A synthetic repository through fast-import: nfiles files in ~200 directories,
    ncommits commits each touching a handful of files, a few big blobs.
    About 20 files per directory (so 20000 files are 1000 directories)."""
    os.makedirs(path)
    sh([git, "init", "-q", "-b", "main"], path, env)
    out = []
    w = out.append
    mark = [0]

    def blob(data):
        mark[0] += 1
        w(b"blob\nmark :%d\ndata %d\n" % (mark[0], len(data)))
        w(data + b"\n")
        return mark[0]

    def body(i, rev):
        lines = [("line %d of file %d rev %d the quick brown fox\n" % (n, i, rev)) for n in range(30)]
        return "".join(lines).encode()

    marks = {}
    for i in range(nfiles):
        marks[i] = blob(body(i, 0))
    big = []
    for b in range(3):
        data = b"".join(b"%08d the big blob line number %d\n" % (n, b) for n in range(80000 + b * 40000))
        big.append(blob(data))

    def p(i):
        d = i // 20          # about 20 files per directory, 10 directories per parent
        return "d%03d/s%02d/f%05d.txt" % (d // 10, d % 10, i)

    ts = 1700000000
    for c in range(ncommits):
        touched = []
        if c > 0:
            for k in range(5):
                i = (c * 7919 + k * 104729) % nfiles
                marks[i] = blob(body(i, c))      # blobs go before the commit that uses them
                touched.append(i)
        w(b"commit refs/heads/main\ncommitter Bench <bench@example.com> %d +0000\n" % (ts + c * 60))
        msg = ("commit %d\n\nsome body text for the commit\nmore text\n" % c).encode()
        w(b"data %d\n" % len(msg))
        w(msg + b"\n")
        if c == 0:
            w(b"deleteall\n")
            for i in range(nfiles):
                w(b"M 100644 :%d %s\n" % (marks[i], p(i).encode()))
            for b, m in enumerate(big):
                w(b"M 100644 :%d big/blob%d.dat\n" % (m, b))
        else:
            for i in touched:
                w(b"M 100644 :%d %s\n" % (marks[i], p(i).encode()))
        w(b"\n")
    sh([git, "fast-import", "--quiet"], path, env, inp=b"".join(out))
    sh([git, "reset", "-q", "--hard"], path, env)
    if loose:
        # explode every pack into loose objects
        pdir = os.path.join(path, ".git", "objects", "pack")
        for n in os.listdir(pdir):
            if n.endswith(".pack"):
                src = os.path.join(pdir, n)
                tmp = os.path.join(path, "x.pack")
                shutil.move(src, tmp)
                os.remove(src[:-5] + ".idx")
                for ext in (".rev", ".bitmap", ".mtimes"):
                    if os.path.exists(src[:-5] + ext):
                        os.remove(src[:-5] + ext)
                with open(tmp, "rb") as f:
                    sh([git, "unpack-objects", "-q"], path, env, inp=f.read())
                os.remove(tmp)
    else:
        sh([git, "repack", "-q", "-a", "-d"], path, env)
    sh([git, "update-index", "--refresh", "-q"], path, env, check=False)


def sources(args, work, git, env):
    repos = {}
    wants = args.sizes.split(",")
    if "small" in wants:
        top = sh([git, "rev-parse", "--show-toplevel"], HERE, env).stdout.decode().strip()
        d = os.path.join(work, "small")
        sh([git, "clone", "-q", "--no-local", top, d], work, env)
        sh([git, "checkout", "-q", "-B", "main"], d, env)
        repos["small"] = d
    if "medium" in wants:
        d = os.path.join(work, "medium")
        sh([git, "clone", "-q", "--no-local", args.medium_src, d], work, env)
        sh([git, "checkout", "-q", "-B", "main"], d, env)
        repos["medium"] = d
    for name, loose in (("large-packed", False), ("large-loose", True)):
        if name in wants:
            d = os.path.join(work, name)
            sys.stderr.write("building %s ...\n" % name)
            synth(d, git, env, args.files, args.commits, loose)
            repos[name] = d
    return repos


def dirty(repo, env, git):
    """Modify a handful of tracked files and add a few untracked ones."""
    files = sh([git, "ls-files"], repo, env).stdout.decode().split("\n")
    files = [f for f in files if f][:2000:50][:40]
    for f in files:
        with open(os.path.join(repo, f), "ab") as fh:
            fh.write(b"changed line\n")
    os.makedirs(os.path.join(repo, "untracked"), exist_ok=True)
    for i in range(10):
        with open(os.path.join(repo, "untracked", "u%d.txt" % i), "w") as fh:
            fh.write("new %d\n" % i)


def stage_some(repo, env, git):
    sh([git, "add", "-u"], repo, env)


def restore(repo, env, git):
    """Back to the pristine state: main at refs/bench/base, clean tree, no extra refs."""
    sh([git, "checkout", "-q", "-f", "-B", "main", "refs/bench/base"], repo, env)
    sh([git, "clean", "-qfdx", "-e", "/.git"], repo, env)
    for b in ("other", "side", "newbranch"):
        sh([git, "branch", "-q", "-D", b], repo, env, check=False)
    sh([git, "stash", "clear"], repo, env, check=False)


class Case:
    def __init__(self, name, argv, setup=None, per=None, sizes=None):
        self.name, self.argv, self.setup, self.per, self.sizes = name, argv, setup, per, sizes


def cases(repo, env, git):
    """(name, argv, per-run setup callable or None). `per` runs untimed before each
    timed run, with the repository reset to the state the case wants."""
    def reset(extra=None):
        def f():
            restore(repo, env, git)
            if extra:
                extra()
        return f
    cs = []
    A = cs.append
    A(Case("startup: git --version / 1git --help", ["--version"], per=None))
    A(Case("status (clean)", ["status"]))
    A(Case("status -sb (clean)", ["status", "-sb"]))
    A(Case("log -n 20", ["log", "-n", "20"]))
    A(Case("log --oneline -n 20", ["log", "--oneline", "-n", "20"]))
    A(Case("log --oneline (full)", ["log", "--oneline"]))
    A(Case("log (full)", ["log"]))
    A(Case("log --stat -n 20", ["log", "--stat", "-n", "20"]))
    A(Case("log -- <path>", ["log", "--oneline", "-n", "20", "--", "core/"]))
    A(Case("show HEAD", ["show", "HEAD"]))
    A(Case("show --stat HEAD~5", ["show", "--stat", "HEAD~5"]))
    A(Case("diff (clean)", ["diff"]))
    A(Case("diff HEAD~1 HEAD", ["diff", "HEAD~1", "HEAD"]))
    A(Case("diff HEAD~50 HEAD (large)", ["diff", "HEAD~50", "HEAD"]))
    A(Case("diff --stat HEAD~50 HEAD", ["diff", "--stat", "HEAD~50", "HEAD"]))
    A(Case("status (dirty)", ["status"], per=reset(lambda: dirty(repo, env, git))))
    A(Case("diff (dirty)", ["diff"], per=reset(lambda: dirty(repo, env, git))))
    A(Case("diff --cached (staged)", ["diff", "--cached"],
           per=reset(lambda: (dirty(repo, env, git), stage_some(repo, env, git)))))
    A(Case("blame <file>", ["blame", "README.md"]))
    A(Case("branch", ["branch"]))
    A(Case("branch -a -vv", ["branch", "-a", "-vv"]))
    A(Case("rev-parse HEAD", ["rev-parse", "HEAD"]))
    A(Case("rev-parse HEAD~100^{tree}", ["rev-parse", "HEAD~100^{tree}"]))
    A(Case("ls-files", ["ls-files"]))
    A(Case("cat-file -p HEAD", ["cat-file", "-p", "HEAD"]))
    A(Case("ls-tree -r HEAD", ["ls-tree", "-r", "HEAD"]))

    def many():
        d = os.path.join(repo, "many")
        os.makedirs(d, exist_ok=True)
        for i in range(500):
            with open(os.path.join(d, "m%04d.txt" % i), "w") as f:
                f.write("many %d\n" % i)
    A(Case("add 500 new files", ["add", "many"], per=reset(many)))

    def many_staged():
        many()
        sh([git, "add", "many"], repo, env)
    A(Case("commit 500 staged files", ["commit", "-q", "-m", "bench"], per=reset(many_staged)))

    def edit_one():
        sh([git, "branch", "-f", "other", "HEAD~30"], repo, env)
    A(Case("switch other (30 commits back)", ["switch", "-q", "other"], per=reset(edit_one)))
    A(Case("checkout -b new", ["checkout", "-q", "-b", "newbranch"], per=reset()))

    def merge_setup():
        sh([git, "branch", "-f", "side", "HEAD~20"], repo, env)
        sh([git, "checkout", "-q", "side"], repo, env)
        with open(os.path.join(repo, "side-only.txt"), "w") as f:
            f.write("side\n")
        sh([git, "add", "side-only.txt"], repo, env)
        sh([git, "commit", "-q", "-m", "side"], repo, env)
        sh([git, "checkout", "-q", "main"], repo, env)
    A(Case("merge side (no-ff clean)", ["merge", "--no-edit", "--no-ff", "-q", "side"],
           per=reset(merge_setup)))

    def stash_setup():
        dirty(repo, env, git)
    A(Case("stash push", ["stash", "push", "-q"], per=reset(stash_setup)))
    return cs


def stats(xs):
    return min(xs), statistics.median(xs)


def fmt(t):
    if t is None:
        return "n/a"
    if t < 1:
        return "%.1f ms" % (t * 1000)
    return "%.2f s" % t


def bench(argv, repo, env, runs, warmup, per):
    ts = []
    first = None
    for i in range(warmup + runs):
        if per:
            per()
        t, p = run(argv, repo, env)
        if first is None:
            first = p
        if i >= warmup:
            ts.append(t)
    return ts, first


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--one", default=os.path.join(HERE, "..", "1git"))
    ap.add_argument("--git", default=shutil.which("git") or "git")
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--sizes", default="small,medium,large-packed,large-loose")
    ap.add_argument("--only", default="")
    ap.add_argument("--medium-src", default="https://github.com/qrazil/m31")
    ap.add_argument("--work", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--files", type=int, default=20000)
    ap.add_argument("--commits", type=int, default=5000)
    ap.add_argument("--json", default="")
    ap.add_argument("--md", default="")
    args = ap.parse_args()
    one = os.path.abspath(args.one)
    git = args.git
    made = not args.work
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="bench1git.")
    os.makedirs(work, exist_ok=True)
    env = make_env(work)
    ver = sh([git, "--version"], work, env).stdout.decode().strip()
    sys.stderr.write("%s ; 1git = %s ; work = %s\n" % (ver, one, work))
    repos = {}
    for n in args.sizes.split(","):
        d = os.path.join(work, n)
        if os.path.isdir(d):
            repos[n] = d
    missing = [n for n in args.sizes.split(",") if n not in repos]
    if missing:
        a = argparse.Namespace(**vars(args))
        a.sizes = ",".join(missing)
        repos.update(sources(a, work, git, env))
    rows = []
    for size in args.sizes.split(","):
        repo = repos[size]
        nfiles = len([f for f in sh([git, "ls-files"], repo, env).stdout.split(b"\n") if f])
        sys.stderr.write("== %s (%d files)\n" % (size, nfiles))
        sh([git, "checkout", "-q", "-f", "main"], repo, env, check=False)
        sh([git, "update-ref", "refs/bench/base", "main"], repo, env)
        # a fixed-size repository for blame / large paths: the cases use paths that
        # exist everywhere (README.md); the synthetic one has none, so aim at a file
        readme = "README.md"
        if not os.path.exists(os.path.join(repo, readme)):
            readme = sh([git, "ls-files"], repo, env).stdout.split(b"\n")[0].decode()
        for c in cases(repo, env, git):
            if args.only and args.only not in c.name:
                continue
            argv = [readme if a == "README.md" else a for a in c.argv]
            if size.startswith("large") and argv[:1] == ["log"] and "core/" in argv:
                argv = [a if a != "core/" else "d001/" for a in argv]
            if size.startswith("large") and c.name == "log (full)" or \
                    size.startswith("large") and c.name == "log --oneline (full)":
                runs = max(1, min(args.runs, 3))
            else:
                runs = args.runs
            if size == "small" and c.name == "diff HEAD~50 HEAD (large)":
                pass
            row = {"size": size, "case": c.name}
            for tool, exe in (("git", git), ("1git", one)):
                av = argv
                if c.name.startswith("startup") and tool == "1git":
                    av = ["--help"]      # 1git has no --version; --help is its trivial path
                ts, first = bench([exe] + av, repo, env, runs, args.warmup, c.per)
                row[tool] = ts
                row[tool + "_rc"] = first.returncode
                row[tool + "_out"] = first.stdout
                row[tool + "_err"] = first.stderr.decode(errors="replace").strip()[:200]
            # reset after mutating cases
            if c.per:
                restore(repo, env, git)
            if row["git_rc"] != 0 and not c.name.startswith("startup"):
                row["note"] = "git rc=%d: %s" % (row["git_rc"], row["git_err"].split("\n")[0][:60])
            if row["1git_rc"] != 0 and row["git_rc"] == 0:
                row["1git"] = None
                row["note"] = "1git rc=%d: %s" % (row["1git_rc"], row["1git_err"].split("\n")[0][:60])
            elif row["git_out"] != row["1git_out"] and not c.per and not c.name.startswith("startup"):
                row["note"] = "bytes differ"
            rows.append(row)
            sys.stderr.write("  %-36s git %-10s 1git %s\n" % (
                c.name, fmt(stats(row["git"])[0]),
                fmt(stats(row["1git"])[0]) if row["1git"] else "n/a"))
    lines = ["| size | case | git min | git med | 1git min | 1git med | ratio (med) | note |",
             "|---|---|---:|---:|---:|---:|---:|---|"]
    for r in rows:
        gmin, gmed = stats(r["git"])
        if r["1git"]:
            omin, omed = stats(r["1git"])
            ratio = "%.1fx" % (omed / gmed) if gmed > 0 else "-"
        else:
            omin = omed = None
            ratio = "-"
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["size"], r["case"], fmt(gmin), fmt(gmed), fmt(omin), fmt(omed), ratio, r.get("note", "")))
    table = "\n".join(lines)
    print(table)
    if args.md:
        with open(args.md, "w") as f:
            f.write("<!-- %s -->\n%s\n" % (ver, table))
    if args.json:
        with open(args.json, "w") as f:
            json.dump([{k: v for k, v in r.items() if not k.endswith("_out")} for r in rows], f, indent=1)
    if made and not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        sys.stderr.write("repositories kept in %s\n" % work)


if __name__ == "__main__":
    main()
