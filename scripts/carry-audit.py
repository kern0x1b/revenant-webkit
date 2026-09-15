#!/usr/bin/env python3
"""List files whose port adaptations thinned out against a reference branch.

    scripts/carry-audit.py [ref] [path ...]
    scripts/carry-audit.py --stale [base] [path ...]

The count of port markers per file is compared with the same file on the
reference branch; --stale instead lists the files that still carry the content
of the graft base, which are the ones an update left behind entirely.

A file that carries fewer markers than the reference is either an upstream
refactor or a carry that was dropped when the file was taken from trunk, and
every one of them is worth reading before a release.
"""
import os
import re
import subprocess
import sys

MARKERS = re.compile(rb"WEBKIT_IOS6|USE\(JSVALUE64\)|JSVALUE32_64|CPU\(ARM_THUMB2\)|payloadGPR|tagGPR")
SOURCE_SUFFIX = re.compile(rb"\.(cpp|h|mm|m|asm)$")


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


def git_lines(args):
    result = subprocess.run(["git"] + args, stdout=subprocess.PIPE)
    return [line.strip(b" \t") for line in result.stdout.split(b"\n")[:-1]]


def resolve_all(rev, paths):
    if not paths:
        return []
    request = b"".join(rev + b":" + path + b"\n" for path in paths)
    result = subprocess.run(["git", "cat-file", "--batch-check=ok %(objectname)"],
                            input=request, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    answers = result.stdout.split(b"\n")
    oids = []
    for i in range(len(paths)):
        answer = answers[i] if i < len(answers) else b""
        oids.append(answer[3:] if answer.startswith(b"ok ") and b" " not in answer[3:] else None)
    return oids


def count_markers(data):
    return sum(1 for line in data.split(b"\n") if MARKERS.search(line))


class BlobReader(object):
    def __init__(self):
        self.proc = subprocess.Popen(["git", "cat-file", "--batch"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def read(self, name):
        self.proc.stdin.write(name + b"\n")
        self.proc.stdin.flush()
        header = self.proc.stdout.readline()
        fields = header.rstrip(b"\n").split(b" ")
        if len(fields) < 3 or not fields[-1].isdigit():
            return b""
        size = int(fields[-1])
        data = self.proc.stdout.read(size)
        self.proc.stdout.read(1)
        return data

    def close(self):
        self.proc.stdin.close()
        self.proc.wait()


def enter_engine(engine):
    try:
        os.chdir(engine)
    except OSError as e:
        sys.stderr.write("%s: cd: %s: %s\n" % (os.path.basename(sys.argv[0]), engine, e.strerror))
        sys.exit(2)


def stale(engine, args):
    base = args[0] if args and args[0] != "" else "1b78c03f880e"
    paths = args[1:] or ["Source/JavaScriptCore", "Source/WTF", "Source/WebCore", "Source/WebKitLegacy"]
    enter_engine(engine)
    files = [f for f in git_lines(["ls-files"] + paths) if os.path.isfile(os.fsdecode(f))]
    ours = resolve_all(b"HEAD", files)
    bases = resolve_all(os.fsencode(base), files)
    upstream = resolve_all(b"upstream/main", files)
    out = sys.stdout.buffer
    count = 0
    for f, o, b, u in zip(files, ours, bases, upstream):
        if o is None or b is None or u is None:
            continue
        if o == b and o != u:
            out.write(f + b"\n")
            count += 1
    out.write(b"%d files the port never touched and the merge never moved\n" % count)
    out.flush()
    return 0


def markers(engine, args):
    ref = args[0] if args and args[0] != "" else "main"
    paths = args[1:] or ["Source/WebCore", "Source/WebKitLegacy", "Source/JavaScriptCore", "Source/WTF"]
    enter_engine(engine)
    listed = [f for f in git_lines(["ls-tree", "-r", "--name-only", ref, "--"] + paths)
              if SOURCE_SUFFIX.search(f)]
    out = sys.stdout.buffer
    reader = BlobReader()
    gaps = 0
    ref_bytes = os.fsencode(ref)
    for f in listed:
        path = os.fsdecode(f)
        if not os.path.isfile(path):
            continue
        a = count_markers(reader.read(ref_bytes + b":" + f))
        if a <= 0:
            continue
        try:
            with open(path, "rb") as handle:
                b = count_markers(handle.read())
        except OSError as e:
            sys.stderr.write("grep: %s: %s\n" % (path, e.strerror))
            continue
        if b < a:
            out.write(b"%-4s %s (%s has %d, here %d)\n" % (b"-%d" % (a - b), f, ref_bytes, a, b))
            gaps += 1
    reader.close()
    out.write(b"%d files carry fewer markers than %s\n" % (gaps, ref_bytes))
    out.flush()
    return 0


def main():
    engine = repo_root(sys.argv[0], 1) + "/webkit-254"
    args = sys.argv[1:]
    if args and args[0] == "--stale":
        return stale(engine, args[1:])
    return markers(engine, args)


if __name__ == "__main__":
    sys.exit(main())
