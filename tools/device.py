#!/usr/bin/env python3
"""Reach the phone named in device.env.

    tools/device.py run [SECONDS] COMMAND...
    tools/device.py copy LOCAL REMOTE
    tools/device.py fetch REMOTE LOCAL
    tools/device.py where

Scripts import it instead: device.run(20, "uiopen ..."), device.copy(...),
device.fetch(...). A dead USB tunnel is brought back before every command,
because a refused connection reads in a log exactly like a crashed browser.
"""
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SSH_OPTIONS = [
    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8",
    "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedKeyTypes=+ssh-rsa",
    "-o", "KexAlgorithms=+diffie-hellman-group1-sha1", "-o", "Ciphers=+aes128-cbc",
    "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
    "-o", "ControlPath=/tmp/rev-ssh-%h-%p",
]


def _read_env_file(path):
    values = {}
    if not path.is_file():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep or not key.isidentifier():
            continue
        value = value.strip()
        if value[:1] in ("'", '"'):
            quote = value[0]
            end = value.find(quote, 1)
            value = value[1:end] if end > 0 else value[1:]
        else:
            value = value.split(" #", 1)[0].split("\t#", 1)[0].strip()
        values[key] = value
    return values


def _settings():
    env = dict(os.environ)
    env.update(_read_env_file(ROOT / "device.env"))
    return {
        "host": env.get("DEVICE_HOST") or "127.0.0.1",
        "port": env.get("DEVICE_PORT") or "2222",
        "password": env.get("DEVICE_PASSWORD") or env.get("DEVICE_PASS") or "",
        "udid": env.get("DEVICE_UDID") or "",
    }


SETTINGS = _settings()
HOST = SETTINGS["host"]
PORT = SETTINGS["port"]


def _port_open(host, port):
    try:
        with socket.create_connection((host, int(port)), timeout=2):
            return True
    except OSError:
        return False


def tunnel():
    if HOST != "127.0.0.1" or _port_open(HOST, PORT) or not shutil.which("iproxy"):
        return
    udid = SETTINGS["udid"]
    if not udid and shutil.which("idevice_id"):
        attached = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True).stdout.split()
        if len(attached) == 1:
            udid = attached[0]
    if not udid:
        print(f"tunnel on {PORT} is down and DEVICE_UDID is not set", file=sys.stderr)
        return
    subprocess.run(["pkill", "-f", f"iproxy {PORT} "], capture_output=True)
    with open(f"/tmp/iproxy-{PORT}.log", "w") as log:
        subprocess.Popen(["iproxy", PORT, "22", "-u", udid], stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    time.sleep(3)


def _authenticated(argv):
    if not SETTINGS["password"]:
        return argv, None
    env = dict(os.environ, SSHPASS=SETTINGS["password"])
    return ["sshpass", "-e", *argv], env


def ssh_command(*extra):
    return ["ssh", *SSH_OPTIONS, "-p", PORT, *extra, f"root@{HOST}"]


def run(timeout, command, capture=True, input=None, check=False):
    tunnel()
    argv, env = _authenticated([*ssh_command(), command])
    try:
        result = subprocess.run(argv, env=env, input=input, timeout=timeout,
                                capture_output=capture, text=isinstance(input, str) or input is None)
    except subprocess.TimeoutExpired as expired:
        result = subprocess.CompletedProcess(argv, 124, expired.stdout or "", expired.stderr or "")
    if check and result.returncode:
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)
    return result


def output(timeout, command):
    return run(timeout, command).stdout or ""


def copy(local, remote, capture=True):
    tunnel()
    argv, env = _authenticated(["scp", *SSH_OPTIONS, "-P", PORT, str(local), f"root@{HOST}:{remote}"])
    return subprocess.run(argv, env=env, capture_output=capture, text=True).returncode == 0


def fetch(remote, local):
    tunnel()
    argv, env = _authenticated(["scp", *SSH_OPTIONS, "-P", PORT, f"root@{HOST}:{remote}", str(local)])
    return subprocess.run(argv, env=env, capture_output=True, text=True).returncode == 0


def reverse_tunnel(port):
    tunnel()
    argv, env = _authenticated([*ssh_command("-N", "-R", f"{port}:127.0.0.1:{port}")])
    return subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def reachable(timeout=12):
    return "ok" in output(timeout, "echo ok")


def restart_safari(settle):
    run(20, "killall MobileSafari 2>/dev/null")
    time.sleep(settle)


def open_url(url):
    run(20, f"uiopen '{url}'")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    verb, args = argv[0], argv[1:]
    if verb == "run":
        timeout = 60
        if args and args[0].isdigit():
            timeout, args = int(args[0]), args[1:]
        if not args:
            print("run needs a command", file=sys.stderr)
            return 2
        result = run(timeout, " ".join(args), capture=False)
        return result.returncode
    if verb == "copy" and len(args) == 2:
        return 0 if copy(*args) else 1
    if verb == "fetch" and len(args) == 2:
        return 0 if fetch(*args) else 1
    if verb == "where" and not args:
        print(f"{HOST}:{PORT}")
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
