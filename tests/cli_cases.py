#!/usr/bin/env python3
"""Check tests/cli_cases.txt: for every case, the line in 1git's grammar becomes
the argv of git's grammar (`t_cli`, the unit over GIT_cli.to_git), and every
git spelling listed with it is rewritten back to that line (`1git -migrate`).
Also checks that every option of every command's --help has a case.

    python3 tests/cli_cases.py <t_cli> <1git> [cases-file]
    python3 tests/cli_cases.py --update <t_cli> <1git> [cases-file]   rewrite the `=` lines

The `=` lines are what GIT_cli.to_git answers (options in the table's order, then
the operands, then `--` and the paths); `--update` writes them, read the diff.
A git spelling passes when its rewrite, run through t_cli, gives the same argv
as the line it is listed under: the order words are typed in does not matter.

Prints one `FAIL ...` line per mismatch and `cases: N lines, M git spellings,
K options covered` at the end; the exit status is the number of failures.
"""
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

args = sys.argv[1:]
update = False
if args and args[0] == "--update":
    update = True
    args = args[1:]
t_cli, one_git = args[0], args[1]
path = args[2] if len(args) > 2 else "tests/cli_cases.txt"

cases = []  # (new line, git line, [old spellings])
for raw in open(path, encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    if line.startswith("= "):
        cases[-1][1] = line[2:]
    elif line.startswith("< "):
        cases[-1][2].append(line[2:])
    else:
        cases.append([line, None, []])

fails = 0
norepo = tempfile.mkdtemp(prefix="cli-cases.")  # outside any repository: revisions and paths are told apart by shape only


def fail(msg):
    global fails
    fails += 1
    print("FAIL " + msg)


def run_t_cli(lines):
    out = subprocess.run([t_cli], input="\n".join(lines) + "\n", capture_output=True, text=True, cwd=norepo).stdout
    return out.split("\n")


got = run_t_cli([c[0] for c in cases])
if update:
    out_lines = []
    index = -1
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#") or line.startswith("< "):
            out_lines.append(line)
        elif line.startswith("= "):
            continue
        else:
            index += 1
            out_lines.append(line)
            out_lines.append("= " + got[index])
    open(path, "w", encoding="utf-8").write("\n".join(out_lines) + "\n")
    cases = []
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("= "):
            cases[-1][1] = line[2:]
        elif line.startswith("< "):
            cases[-1][2].append(line[2:])
        else:
            cases.append([line, None, []])
    got = run_t_cli([c[0] for c in cases])
for index, case in enumerate(cases):
    new, git, olds = case
    if git is None:
        fail("no `=` line for: " + new)
    elif got[index] != git:
        fail("%s\n     want: %s\n     got:  %s" % (new, git, got[index]))
    elif got[index].startswith("error") or got[index].startswith("usage"):
        fail("%s is refused: %s" % (new, got[index]))


def migrate(git_line):
    words = shlex.split(git_line)
    if words and words[0] == "git":
        words = words[1:]
    data = b"".join(w.encode() + b"\0" for w in words)
    proc = subprocess.run([one_git, "-migrate", "--nul"], input=data, capture_output=True, cwd=norepo)
    if proc.returncode != 0:
        return None, "ERROR: " + proc.stderr.decode().strip()
    return " ".join(shlex.quote(w) for w in [x.decode() for x in proc.stdout.split(b"\0")[:-1]]), ""


spellings = 0
for index, (new, git, olds) in enumerate(cases):
    for old in olds:
        spellings += 1
        rewritten, why = migrate(old)
        if rewritten is None:
            fail("%s\n     %s" % (old, why))
            continue
        again = run_t_cli([rewritten])[0]
        if again != got[index]:
            fail("%s\n     rewrites to: %s\n     which is git: %s\n     want:         %s" % (old, rewritten, again, got[index]))

# every option of every command is exercised
helps = subprocess.run([one_git, "--help"], capture_output=True, text=True).stdout
commands = re.findall(r"^\s+(?:-\w, )?-(\S+)\s", helps.split("options:")[0], re.M)
covered = 0
for command in commands:
    text = subprocess.run([one_git, "-" + command, "--help"], capture_output=True, text=True).stdout
    options = re.findall(r"^\s+(?:--\w, )?--([a-z][a-z0-9-]*)", text.split("options:")[1] if "options:" in text else "", re.M)
    used = " ".join(c[0] for c in cases if c[0].split()[0] == "-" + command)
    for option in options:
        if option == "help" or command == "migrate":
            continue
        if re.search(r"--%s(\s|=|$)" % re.escape(option), used):
            covered += 1
        else:
            fail("-%s --%s has no case in %s" % (command, option, path))

shutil.rmtree(norepo, ignore_errors=True)
print("cases: %d lines, %d git spellings, %d options covered" % (len(cases), spellings, covered))
sys.exit(min(fails, 255))
