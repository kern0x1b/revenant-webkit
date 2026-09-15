#!/usr/bin/env python3
"""Check that the engine tree still holds what this port depends on.

    scripts/carry-check.py [manifest]
"""
import os
import re
import subprocess
import sys

IFS_WS = b" \t\n"


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


def read_fields(line, count):
    rest = line.strip(IFS_WS)
    fields = []
    for _ in range(count - 1):
        match = re.match(rb"[^ \t\n]*", rest)
        token = match.group(0)
        fields.append(token)
        rest = rest[len(token):].lstrip(IFS_WS)
    fields.append(rest)
    return fields


def lines_of(data):
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def contains_fixed(lines, text):
    if text == b"":
        return len(lines) > 0
    return any(text in line for line in lines)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def file_contains(path, text):
    try:
        data = read_file(path)
    except OSError as e:
        sys.stderr.write("grep: %s: %s\n" % (path, e.strerror))
        return False
    return contains_fixed(lines_of(data), text)


def pref_block(lines, key):
    out = []
    inside = False
    for line in lines:
        if line == key:
            inside = True
            continue
        if inside and line == b"":
            break
        if inside:
            out.append(line)
    return out


def pref_keeps(path, key, text):
    try:
        data = read_file(path)
    except OSError:
        sys.stderr.write("awk: can't open file %s\n" % path)
        return False
    return contains_fixed(pref_block(lines_of(data), key), text)


def guard_count(engine, area):
    try:
        result = subprocess.run(
            ["git", "-C", engine, "grep", "-l", "WEBKIT_IOS6", "--", area],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return 0
    return sum(1 for line in result.stdout.split(b"\n") if line != b"")


def main():
    root = repo_root(sys.argv[0], 1)
    engine = os.path.join(root, "webkit-254")
    manifest = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "" else os.path.join(root, "carry-manifest.txt")
    out = sys.stdout.buffer
    failed = False

    def report(status, message):
        nonlocal failed
        out.write(b"%-6s %s\n" % (status, message))
        if status == b"FAIL":
            failed = True

    try:
        data = read_file(manifest)
    except OSError as e:
        sys.stderr.write("%s: %s: %s\n" % (os.path.basename(sys.argv[0]), manifest, e.strerror))
        data = None

    if data is not None:
        for raw in lines_of(data):
            kind, a, b = read_fields(raw, 3)
            fs_a = os.fsdecode(a)
            if kind in (b"", b"#"):
                continue
            if kind == b"file":
                if os.path.isfile(engine + "/" + fs_a):
                    report(b"ok", a)
                else:
                    report(b"FAIL", b"missing: " + a)
            elif kind == b"grep":
                path = engine + "/" + fs_a
                if os.path.isfile(path) and file_contains(path, b):
                    report(b"ok", a + b" contains " + b)
                else:
                    report(b"FAIL", a + b" no longer contains: " + b)
            elif kind == b"pref":
                key = b.split(b" ", 1)[0]
                text = b.split(b" ", 1)[1] if b" " in b else b
                path = engine + "/" + fs_a
                if os.path.isfile(path) and pref_keeps(path, key + b":", text):
                    report(b"ok", a + b" " + key + b" keeps " + text)
                else:
                    report(b"FAIL", a + b" " + key + b" lost: " + text)
            elif kind == b"set":
                if file_contains(root + "/" + fs_a, b):
                    report(b"ok", a + b" keeps " + b)
                else:
                    report(b"FAIL", a + b" lost: " + b)
            elif kind == b"guard":
                n = guard_count(engine, fs_a)
                floor = re.fullmatch(rb"[+-]?[0-9]+", b)
                if floor is None:
                    sys.stderr.write("%s: %s: integer expression expected\n" % (os.path.basename(sys.argv[0]), os.fsdecode(b)))
                if floor is not None and n >= int(b):
                    report(b"ok", a + b" carries the guard in " + str(n).encode() + b" files (floor " + b + b")")
                else:
                    report(b"FAIL", a + b" carries the guard in only " + str(n).encode() + b" files, floor is " + b)
            else:
                report(b"FAIL", b"unknown directive: " + kind)

    if data is None:
        failed = True
    if failed:
        out.write(b"CARRY BROKEN - the tree no longer holds what this port depends on\n")
    else:
        out.write(b"carry intact\n")
    out.flush()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
