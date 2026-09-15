#!/usr/bin/env python3
"""How far the engine tree has moved from its upstream base.

    scripts/port-delta.py [base]
    scripts/port-delta.py --freshness [base]
    scripts/port-delta.py --unguarded [area] [base]

LIMIT caps the --unguarded list (default 40).
"""
import os
import re
import subprocess
import sys

AWK_BLANKS = re.compile(rb"[ \t\n]+")
SORT_NUMBER = re.compile(rb"[ \t]*(-?[0-9]+)")
AWK_NUMBER = re.compile(rb"[ \t\n]*([+-]?[0-9]+)")
SOURCE_FILE = re.compile(rb"^Source/.*\.(cpp|h|mm)$")
HEAD_COUNT = re.compile(r"[ \t]*\+?[0-9]+")


def logical_cwd():
    pwd = os.environ.get("PWD")
    if pwd and os.path.isabs(pwd):
        try:
            if os.path.samefile(pwd, "."):
                return pwd
        except OSError:
            pass
    return os.getcwd()


def repo_root(script, levels):
    parts = [os.path.dirname(script)] + [".."] * levels
    return os.path.normpath(os.path.join(logical_cwd(), *parts))


class Engine(object):
    def __init__(self, path):
        self.path = path

    def run(self, args, quiet=False):
        result = subprocess.run(["git", "-C", self.path] + args, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL if quiet else None)
        return result.returncode, result.stdout

    def must(self, args, quiet=False):
        rc, out = self.run(args, quiet)
        if rc != 0:
            sys.stdout.flush()
            sys.exit(rc)
        return out

    def verify(self, ref):
        rc, _ = self.run(["rev-parse", "--verify", "-q", ref])
        return rc == 0


def lines_of(data):
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def awk_fields(line):
    stripped = line.strip(b" \t\n")
    return AWK_BLANKS.split(stripped) if stripped else []


def field(fields, n):
    return fields[n - 1] if len(fields) >= n else b""


def awk_number(text):
    match = AWK_NUMBER.match(text)
    return int(match.group(1)) if match else 0


def sort_number(text):
    match = SORT_NUMBER.match(text)
    return int(match.group(1)) if match else 0


def cut_chars(data, limit):
    text = data.decode("utf-8", "surrogateescape")
    return b"\n".join(line[:limit].encode("utf-8", "surrogateescape") for line in text.split("\n"))


def substitution(data):
    return data.rstrip(b"\n")


def unguarded(engine, area, base, out):
    limit = os.environ.get("LIMIT") or "40"
    out.write(b"changed files under " + os.fsencode(area) + b" that carry no WEBKIT_IOS6 guard, largest first\n")
    out.write(b"  these are the ones a conflict here has to be read by hand\n")
    out.flush()
    guarded = engine.must(["grep", "-l", "WEBKIT_IOS6", "--", area], quiet=True)
    guarded_keys = set(lines_of(guarded))
    changed = []
    for line in lines_of(engine.must(["diff", "--numstat", base, "HEAD", "--", area])):
        fields = awk_fields(line)
        total = awk_number(field(fields, 1)) + awk_number(field(fields, 2))
        changed.append(b"%d\t%s" % (total, field(fields, 3)))
    if not HEAD_COUNT.fullmatch(limit) or int(limit) <= 0:
        sys.stderr.write("head: illegal line count -- %s\n" % limit)
        return 1
    rows = [row for row in changed if row.split(b"\t", 1)[1] not in guarded_keys]
    rows.sort(key=lambda row: (sort_number(row), row), reverse=True)
    for row in rows[:int(limit)]:
        out.write(row + b"\n")
    return 0


def freshness(engine, base, out):
    base_bytes = os.fsencode(base)
    out.write(b"how fresh the snapshot is, against " + base_bytes + b"\n")
    _, tip = engine.run(["log", "-1", "--format=%ad  %s", "--date=short", base])
    out.write(b"  branch tip: " + substitution(cut_chars(tip, 72)) + b"\n")
    out.flush()
    boundary = None
    _, commits = engine.run(["log", "--format=%H", "-n", "200", base])
    for commit in commits.split():
        commit = os.fsdecode(commit)
        _, names = engine.run(["show", "--name-only", "--format=", commit])
        source = next((name for name in lines_of(names) if SOURCE_FILE.search(name)), None)
        if not source:
            continue
        local = engine.path + "/" + os.fsdecode(source)
        if not os.path.isfile(local):
            continue
        _, patch = engine.run(["show", commit, "--", os.fsdecode(source)])
        added = None
        for line in lines_of(patch):
            if not line.startswith(b"+") or line.startswith(b"+++"):
                continue
            content = line[1:]
            if content.strip(b" \t\n\r\x0b\x0c") == b"":
                continue
            added = content
            break
        if not added:
            continue
        try:
            with open(local, "rb") as f:
                present = any(added in text for text in lines_of(f.read()))
        except OSError:
            present = False
        if present:
            boundary = commit
            break
    if boundary is None:
        out.write(b"  nothing on the branch matched - the snapshot is older than the 200 commits looked at\n")
        return 0
    _, carried = engine.run(["log", "-1", "--format=%ad  %h  %s", "--date=short", boundary])
    out.write(b"  we carry:   " + substitution(cut_chars(carried, 72)) + b"\n")
    _, behind = engine.run(["rev-list", "--count", boundary + ".." + base])
    out.write(b"  behind by:  " + substitution(behind) + b" commits\n")
    return 0


def size(engine, base, out):
    span = base + "..HEAD"
    out.write(b"port delta against " + os.fsencode(base) + b"\n")
    out.write(engine.must(["diff", "--shortstat", span]))
    out.write(b"\n")

    out.write(b"by area:\n")
    order = []
    added, deleted, files = {}, {}, {}
    for line in lines_of(engine.must(["diff", "--numstat", span])):
        fields = awk_fields(line)
        path = field(fields, 3)
        parts = path.split(b"/") if path else []
        key = field(parts, 1) + b"/" + field(parts, 2)
        if key not in added:
            order.append(key)
            added[key] = deleted[key] = files[key] = 0
        added[key] += awk_number(field(fields, 1))
        deleted[key] += awk_number(field(fields, 2))
        files[key] += 1
    areas = [(files[k], b"  %-34s %5d files  +%-7d -%d" % (k, files[k], added[k], deleted[k])) for k in order]
    areas.sort(reverse=True)
    for _, row in areas[:12]:
        out.write(row + b"\n")
    out.write(b"\n")

    out.write(b"kind of change:\n")
    kinds = {}
    for line in lines_of(engine.must(["diff", "--name-status", span])):
        kind = field(awk_fields(line), 1)
        kinds[kind] = kinds.get(kind, 0) + 1
    out.write(b"  %d modified, %d added, %d deleted\n" % (kinds.get(b"M", 0), kinds.get(b"A", 0), kinds.get(b"D", 0)))

    changed = set(lines_of(engine.must(["diff", "--name-only", span, "--", "Source"])))
    guarded = set(lines_of(engine.must(["grep", "-l", "defined(WEBKIT_IOS6)", "--", "Source"])))
    bare = sorted(changed - guarded)

    out.write(b"\n")
    out.write(b"how much of it announces itself:\n")
    out.write(b"  %5d files changed under Source\n" % len(changed))
    out.write(b"  %5d of them carry the WEBKIT_IOS6 guard\n" % len(changed & guarded))
    out.write(b"  %5d do not - these are the ones a re-graft has to be careful with\n" % len(bare))
    out.write(b"\n")
    out.write(b"  the unguarded ones, by area:\n")
    counts = {}
    for path in bare:
        parts = path.split(b"/")
        key = parts[0] + b"/" + field(parts, 2)
        counts[key] = counts.get(key, 0) + 1
    ranked = sorted(((n, k) for k, n in counts.items()), reverse=True)
    for n, key in ranked[:8]:
        out.write(b"    %-32s %d\n" % (field(awk_fields(key), 1), n))
    return 0


def main():
    engine = Engine(repo_root(sys.argv[0], 1) + "/webkit-254")
    args = sys.argv[1:]
    mode = "size"
    area = "Source"
    if args and args[0] == "--freshness":
        mode = "freshness"
        args = args[1:]
    elif args and args[0] == "--unguarded":
        mode = "unguarded"
        args = args[1:]
        if args:
            area = args[0]
            args = args[1:]
    default_base = "upstream/webkitglib/2.54"
    if not engine.verify(default_base):
        default_base = "origin/webkitglib/2.54"
    base = args[0] if args and args[0] != "" else default_base

    if not engine.verify(base):
        sys.stderr.write("no such ref: %s (fetch it first)\n" % base)
        return 1

    out = sys.stdout.buffer
    if mode == "unguarded":
        rc = unguarded(engine, area, base, out)
    elif mode == "freshness":
        rc = freshness(engine, base, out)
    else:
        rc = size(engine, base, out)
    out.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
