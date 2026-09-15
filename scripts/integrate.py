#!/usr/bin/env python3
"""One upstream update, in the order that fails cheapest first.

    scripts/integrate.py upstream/webkitglib/2.54     take the series' own picks
    scripts/integrate.py upstream/main                the base change, when it is time
    scripts/integrate.py --no-merge                   just run the gates on what is here

Add --with-jsc32 to also build JavaScriptCore for 32-bit ARM and run its own
suites in a container. That tier is slow and needs docker, so it is opt-in.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import device  # noqa: E402


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


def parse_args(argv):
    with_jsc32 = False
    rest = []
    for a in argv:
        if a == "--with-jsc32":
            with_jsc32 = True
        else:
            rest.append(a)
    ref = rest[0] if rest else ""
    return with_jsc32, ref


def split_ref(ref):
    remote = ref.split("/", 1)[0]
    branch = ref.split("/", 1)[1] if "/" in ref else ref
    return remote, branch


def say(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def emit(data):
    sys.stdout.flush()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def step(name):
    say("\n=== %s\n" % name)


def die(message):
    say("\nSTOPPED: %s\n" % message)
    sys.exit(1)


def status(argv, **kwargs):
    sys.stdout.flush()
    try:
        return subprocess.run(argv, **kwargs).returncode
    except OSError as e:
        sys.stderr.write("%s: %s\n" % (argv[0], e.strerror))
        return 127


def captured(argv):
    sys.stdout.flush()
    try:
        out = subprocess.run(argv, stdout=subprocess.PIPE).stdout
    except OSError as e:
        sys.stderr.write("%s: %s\n" % (argv[0], e.strerror))
        out = b""
    return out.rstrip(b"\n")


def tail_lines(data, count):
    if not data:
        return b""
    return b"".join(data.splitlines(True)[-count:])


def command_substitution(data):
    return data.rstrip(b"\n")


def echo_tail(data, count):
    return tail_lines(command_substitution(data) + b"\n", count)


def filter_not_ok(argv):
    sys.stdout.flush()
    child = subprocess.Popen(argv, stdout=subprocess.PIPE)
    for line in child.stdout:
        if not line.startswith(b"ok"):
            emit(line if line.endswith(b"\n") else line + b"\n")
    child.stdout.close()
    child.wait()


def head(argv, count):
    sys.stdout.flush()
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for _ in range(count):
        line = child.stdout.readline()
        if not line:
            break
        emit(line)
    child.stdout.close()
    child.wait()


def device_up():
    return "up" in (device.output(10, "echo up") or "")


def main(argv):
    p = repo_root(sys.argv[0], 1)
    e = p + "/webkit-254"
    py = sys.executable
    with_jsc32, ref = parse_args(argv)

    status(["git", "-C", e, "config", "rerere.enabled", "true"])

    if ref and ref != "--no-merge":
        step("merging %s" % ref)
        remote, branch = split_ref(ref)
        if status(["git", "-C", e, "fetch", "--filter=blob:none", remote,
                   "refs/heads/%s:refs/remotes/%s" % (branch, ref)]):
            die("fetch failed")
        before = captured(["git", "-C", e, "rev-parse", "HEAD"])
        if status(["git", "-C", e, "merge", "--no-edit", ref]):
            die("merge conflicts left in webkit-254 - resolve, commit, then rerun with --no-merge")
        if before == captured(["git", "-C", e, "rev-parse", "HEAD"]):
            say("already up to date\n")

    step("carry manifest")
    filter_not_ok([py, p + "/scripts/carry-check.py"])
    if status([py, p + "/scripts/carry-check.py"], stdout=subprocess.DEVNULL):
        die("the tree no longer holds what this port depends on")

    step("port delta")
    head([py, p + "/scripts/port-delta.py"], 14)

    step("build")
    if status(["conan", "build", p, "-pr:h", p + "/profiles/revenant-armv7", "-pr:b", "default"]):
        die("build failed")

    step("symbols")
    if status(["bash", p + "/scripts/symbol-check.sh"]):
        die("the symbol surface moved - check each line against the device")

    if with_jsc32:
        step("32-bit JavaScriptCore")
        if status([py, p + "/tests/jsc32/build-and-test.py", "stress"]):
            die("the 32-bit engine did not pass its own suites")

    step("host checks")
    sys.stdout.flush()
    host = subprocess.run([py, p + "/tests/run-tests.py", "host"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if host.returncode:
        die("host checks failed")
    emit(echo_tail(host.stdout, 4))
    if b"host tests: conan install failed" in host.stdout:
        say("WARNING: the ICU tier did not run - the ICU package for this Mac did not install\n")

    step("device")
    if device_up():
        if status([py, p + "/scripts/deploy-engine.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL):
            die("deploy failed")
        sys.stdout.flush()
        run = subprocess.run([py, p + "/tests/device/run.py"], stdout=subprocess.PIPE)
        emit(tail_lines(run.stdout, 3))
    else:
        say("no device - this integration is unverified and must not be shipped\n")
        return 3

    say("\nintegration green\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
