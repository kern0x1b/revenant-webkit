#!/usr/bin/env python3
"""Fetch the engine submodule.

    ./fetch-source.py
"""
import os
import subprocess
import sys


def logical_cwd():
    pwd = os.environ.get("PWD")
    if pwd and os.path.isabs(pwd):
        try:
            if os.path.samefile(pwd, "."):
                return pwd
        except OSError:
            pass
    return os.getcwd()


def substitution(args):
    result = subprocess.run(args, stdout=subprocess.PIPE)
    return result.stdout.rstrip(b"\n")


def main():
    root = os.path.normpath(os.path.join(logical_cwd(), os.path.dirname(sys.argv[0])))
    os.chdir(root)
    rc = subprocess.call(["git", "submodule", "update", "--init", "--depth", "1", "webkit-254"])
    if rc != 0:
        return rc
    rev = substitution(["git", "-C", "webkit-254", "rev-parse", "--short", "HEAD"])
    du = substitution(["du", "-sh", "webkit-254"])
    size = b"\n".join(line.split(b"\t", 1)[0] for line in du.split(b"\n"))
    out = sys.stdout.buffer
    out.write(b"webkit-254 at " + rev + b" (" + size + b")\n")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
