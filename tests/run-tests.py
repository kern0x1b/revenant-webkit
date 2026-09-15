#!/usr/bin/env python3
"""Run the host checks, the JavaScript batteries on the phone, or both.

    tests/run-tests.py [host|device|all]
    ENGINE_BUILD=build/... tests/run-tests.py device
"""
import glob
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import device  # noqa: E402

DEVICE_DIR = "/tmp/jscrun"
BLANK = " \t\n\v\f\r"
VERDICT = re.compile(r"ALL OK|FAILURE", re.IGNORECASE)
BROKEN = re.compile(r"^FAIL|Exception|Segmentation", re.IGNORECASE)
REPORTED = re.compile(r"^FAIL|Exception|Segmentation|FAILURE", re.IGNORECASE)

SOURCE = '''set -uo pipefail
env -0 >&"$1"
printf '\\1' >&"$1"
set -a
%s
set -- "$?" "$@"
set +a
env -0 >&"$2"
exit "$1"
'''


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


def parse_env(data):
    values = {}
    for entry in data.split(b"\0"):
        key, sep, value = entry.partition(b"=")
        if sep:
            values[os.fsdecode(key)] = os.fsdecode(value)
    return values


def source(path, log=None):
    line = '. "$2" > "$3" 2>&1' if log else '. "$2"'
    read_end, write_end = os.pipe()
    argv = ["bash", "-c", SOURCE % line, "bash", str(write_end), path] + ([log] if log else [])
    sys.stdout.flush()
    child = subprocess.Popen(argv, pass_fds=(write_end,))
    os.close(write_end)
    chunks = []
    with os.fdopen(read_end, "rb") as reader:
        for chunk in iter(lambda: reader.read(65536), b""):
            chunks.append(chunk)
    code = child.wait()
    before, sep, after = b"".join(chunks).partition(b"\1")
    if not sep or not after:
        sys.exit(code or 1)
    old = parse_env(before)
    for key, value in parse_env(after).items():
        if old.get(key) != value:
            os.environ[key] = value
    return code


def variable(name):
    if name not in os.environ:
        sys.stderr.write("%s: %s: unbound variable\n" % (sys.argv[0], name))
        sys.exit(1)
    return os.environ[name]


def out(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def err(text):
    sys.stdout.flush()
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def text_of(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value or ""


def passthrough_stderr(result):
    sys.stderr.write(text_of(result.stderr))
    sys.stderr.flush()


def tail_lines(data, count):
    if not data:
        return b""
    return b"".join(data.splitlines(True)[-count:])


def piped_to_tail(argv, count):
    sys.stdout.flush()
    try:
        child = subprocess.run(argv, stdout=subprocess.PIPE)
    except OSError as e:
        err("%s: %s: %s" % (sys.argv[0], argv[0], e.strerror))
        return 126 if isinstance(e, PermissionError) else 127
    sys.stdout.buffer.write(tail_lines(child.stdout, count))
    sys.stdout.buffer.flush()
    return child.returncode


def remote_sizes(listing):
    rows = []
    for line in listing.split("\n"):
        fields = line.split()
        if len(fields) >= 9:
            rows.append("%s %s" % (fields[-1], fields[4]))
    return "\n".join(rows)


def remote_size_of(sizes, remote_path):
    found = []
    for line in (sizes + "\n").split("\n")[:-1]:
        fields = line.split()
        if fields and fields[0] == remote_path:
            found.append(fields[1] if len(fields) > 1 else "")
    return "\n".join(found)


def push_if_changed(local_path, remote_path, sizes):
    try:
        local_size = str(os.stat(local_path).st_size)
    except OSError as e:
        err("stat: %s: stat: %s" % (local_path, e.strerror))
        local_size = ""
    if local_size == remote_size_of(sizes, remote_path):
        return True
    kb = int(local_size) // 1024 if local_size else 0
    err("  syncing %s (%d KB)" % (os.path.basename(remote_path), kb))
    return device.copy(local_path, remote_path)


def battery_verdict(output):
    head, sep, tail = output.rpartition("EXIT=")
    status = tail if sep else output
    body = head if sep else output
    kept = [line for line in (body + "\n").split("\n")[:-1] if line.strip(BLANK)]
    lines = "\n".join(kept).rstrip("\n").split("\n")
    verdicts = [line for line in lines if VERDICT.search(line)]
    verdict = verdicts[-1] if verdicts else ""
    failed = status != "0" or not verdict or any(BROKEN.search(line) for line in lines)
    reported = [line for line in lines if REPORTED.search(line)][:10]
    return status, verdict, failed, reported


class Runner(object):
    def __init__(self, root):
        self.root = root
        self.failures = 0

    def run_host_tests(self):
        root = self.root
        deps = root + "/build/host-tests"
        os.makedirs(deps, exist_ok=True)
        sys.stdout.flush()
        with open(deps + "/conan-install.log", "wb") as log:
            try:
                installed = subprocess.run(
                    ["conan", "install", root + "/tests/host", "-pr:h", "default", "-pr:b", "default",
                     "--build=missing", "--lockfile=%s/conan.lock" % root, "--lockfile-partial",
                     "--output-folder=%s" % deps], stdout=log, stderr=subprocess.STDOUT).returncode
            except OSError as e:
                log.write(("conan: %s\n" % e.strerror).encode())
                installed = 127
        if installed:
            err("host tests: conan install failed, see %s/conan-install.log" % deps)
            self.failures += 1
            return
        source(deps + "/ios6-deps.env")
        bin_dir = (os.environ.get("TMPDIR") or "/tmp") + "/revenant-tests"
        os.makedirs(bin_dir, exist_ok=True)

        subprocess.run([sys.executable, root + "/tests/host/gen-required-encodings.py"], stdout=subprocess.DEVNULL)

        for name in ("icu-sanity", "icu-locales"):
            icu = variable("IOS6_HOST_ICU")
            try:
                compiled = subprocess.run(
                    ["clang++", "-o", "%s/%s" % (bin_dir, name), "%s/tests/host/%s.cpp" % (root, name),
                     "-I", icu + "/include", "-L", icu + "/lib", "-licui18n", "-licuuc", "-licudata"]).returncode
            except OSError as e:
                err("%s: clang++: %s" % (sys.argv[0], e.strerror))
                compiled = 127
            if compiled:
                self.failures += 1

        out("== icu-sanity ==")
        if piped_to_tail([bin_dir + "/icu-sanity", root + "/tests/host/required-encodings.txt",
                          root + "/tests/host/known-missing-encodings.txt"], 6):
            self.failures += 1
        out("== icu-locales ==")
        if piped_to_tail([bin_dir + "/icu-locales"], 2):
            self.failures += 1

    def device_ready(self):
        return device.reachable(12)

    def sync_engine(self):
        root = self.root
        built = os.environ.get("ENGINE_BUILD") or root + "/build/engine/armv7-system"
        if source(root + "/scripts/deps.sh", root + "/build/deps-install.log"):
            err("device tests: conan install failed, see %s/build/deps-install.log" % root)
            return False
        if not os.path.isfile(built + "/jsc"):
            if os.path.isdir(built):
                try:
                    subprocess.run(["ninja", "jsc"], cwd=built, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except OSError:
                    pass
            else:
                err("%s: cd: %s: No such file or directory" % (sys.argv[0], built))
        if not os.path.isfile(built + "/jsc"):
            err("cannot build jsc")
            return False

        passthrough_stderr(device.run(30, "mkdir -p %s/Frameworks" % DEVICE_DIR))

        listing = device.run(30, "ls -l %s/jsc %s/Frameworks/*.dylib %s/Frameworks/*.framework/* 2>/dev/null"
                             % (DEVICE_DIR, DEVICE_DIR, DEVICE_DIR))
        passthrough_stderr(listing)
        sizes = remote_sizes(text_of(listing.stdout))

        if not push_if_changed(built + "/jsc", DEVICE_DIR + "/jsc", sizes):
            return False
        libcxx = None
        for lib in ("libc++.1.0.dylib", "libc++abi.1.0.dylib"):
            base = lib.replace(".1.0.", ".1.", 1)
            if libcxx is None:
                libcxx = variable("IOS6_HOST_LIBCXX")
            if not push_if_changed("%s/lib/%s" % (libcxx, lib), "%s/Frameworks/%s" % (DEVICE_DIR, base), sizes):
                return False

        for framework in ("JavaScriptCore", "WebCore", "WebKitLegacy"):
            binary = "%s/%s.framework/%s" % (built, framework, framework)
            if not os.path.isfile(binary):
                continue
            passthrough_stderr(device.run(30, "mkdir -p %s/Frameworks/%s.framework" % (DEVICE_DIR, framework)))
            if not push_if_changed(binary, "%s/Frameworks/%s.framework/%s" % (DEVICE_DIR, framework, framework), sizes):
                return False
        return True

    def run_device_tests(self):
        if not self.device_ready():
            err("device tests: the phone is not reachable - check device.env (see device.env.example)")
            self.failures += 1
            return

        if not self.sync_engine():
            self.failures += 1
            return

        pattern = self.root + "/tests/js/*.js"
        batteries = sorted(glob.glob(pattern)) or [pattern]
        for battery in batteries:
            device.copy(battery, DEVICE_DIR + "/")

        for script in batteries:
            name = os.path.basename(script)
            result = device.run(300, "cd %s && DYLD_FRAMEWORK_PATH=%s/Frameworks ./jsc %s 2>&1; echo EXIT=$?"
                                % (DEVICE_DIR, DEVICE_DIR, name))
            passthrough_stderr(result)
            output = text_of(result.stdout).rstrip("\n")
            status, verdict, failed, reported = battery_verdict(output)
            if failed:
                out("== %s FAILED (exit %s) ==" % (name, status))
                for line in reported:
                    out(line)
                if not verdict:
                    out("  no verdict line: battery did not finish")
                self.failures += 1
            else:
                out("%s: %s" % (name, verdict))


def main(argv):
    root = repo_root(sys.argv[0], 1)
    what = argv[0] if argv and argv[0] else "all"
    runner = Runner(root)
    if what == "host":
        runner.run_host_tests()
    elif what == "device":
        runner.run_device_tests()
    elif what == "all":
        runner.run_host_tests()
        runner.run_device_tests()
    else:
        err("usage: %s [host|device|all]" % sys.argv[0])
        return 2

    out("")
    if runner.failures == 0:
        out("run-tests: PASSED")
    else:
        out("run-tests: FAILED (%d)" % runner.failures)
    return 1 if runner.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
