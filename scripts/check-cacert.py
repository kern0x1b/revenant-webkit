#!/usr/bin/env python3
"""Verify the trust store the standalone application carries.

    scripts/check-cacert.py [--upstream]
"""
import hashlib
import os
import sys
import urllib.error
import urllib.request

EXPECTED = "f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"
UPSTREAM = "https://curl.se/ca/cacert.pem"


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
    bundle = repo_root(sys.argv[0], 1) + "/app/cacert.pem"
    try:
        with open(bundle, "rb") as f:
            actual = hashlib.sha256(f.read()).hexdigest()
    except OSError as e:
        sys.stderr.write("shasum: %s: %s\n" % (bundle, e.strerror))
        return 1
    if actual != EXPECTED:
        sys.stderr.write("app/cacert.pem is not the reviewed bundle\n")
        sys.stderr.write("  expected %s\n" % EXPECTED)
        sys.stderr.write("  found    %s\n" % actual)
        return 1
    print("app/cacert.pem matches the reviewed bundle (%s)" % EXPECTED)
    sys.stdout.flush()

    if len(sys.argv) > 1 and sys.argv[1] == "--upstream":
        try:
            with urllib.request.urlopen(UPSTREAM) as response:
                remote = hashlib.sha256(response.read()).hexdigest()
        except urllib.error.HTTPError:
            return 22
        except (urllib.error.URLError, OSError):
            return 1
        if remote == actual:
            print("and it is byte-for-byte what %s serves today" % UPSTREAM)
        else:
            print("%s now serves a different extract (%s)." % (UPSTREAM, remote))
            print("A trust store changes only after somebody reads the change:")
            print("  1. diff the two files and see which authorities moved")
            print("  2. replace app/cacert.pem")
            print("  3. put the new hash in EXPECTED above, in the same commit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
