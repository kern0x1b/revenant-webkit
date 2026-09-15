#!/usr/bin/env python3
"""Regenerate required-encodings.txt from the engine's ICU codec table.

    tests/host/gen-required-encodings.py
"""
import os
import re
import sys

DECLARATION = re.compile(rb'DECLARE_ENCODING_NAME(?:_NO_ALIASES)?\("([^"]+)"')


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


def main():
    root = repo_root(sys.argv[0], 2)
    source_file = root + "/webkit-254/Source/WebCore/PAL/pal/text/TextCodecICU.cpp"
    out = root + "/tests/host/required-encodings.txt"
    try:
        with open(source_file, "rb") as f:
            data = f.read()
    except OSError as e:
        sys.stderr.write("grep: %s: %s\n" % (source_file, e.strerror))
        return 2
    names = set()
    for line in data.split(b"\n"):
        for match in DECLARATION.finditer(line):
            names.add(match.group(1))
    if not names:
        return 1
    names.add(b"UTF-8")
    with open(out, "wb") as f:
        f.write(b"".join(name + b"\n" for name in sorted(names)))
    sys.stdout.buffer.write(b"%d encodings -> %s\n" % (len(names), os.fsencode(out)))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
