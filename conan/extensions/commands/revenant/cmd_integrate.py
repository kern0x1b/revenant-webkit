import os
import subprocess
import sys

from conan.api.output import ConanOutput
from conan.cli.command import conan_command
from conan.errors import ConanException

import revenant_checkout
from revenant_checkout import add_root_argument, device_module, engine_build, find_checkout

ENGINE = "webkit-254"
PORT_DELTA_LINES = 14


def _run(command, **kwargs):
    return subprocess.run([str(part) for part in command], **kwargs)


def _must(command, reason, **kwargs):
    try:
        return _run(command, check=True, **kwargs)
    except OSError as error:
        raise ConanException(f"{command[0]}: {error.strerror}") from error
    except subprocess.CalledProcessError as error:
        raise ConanException(reason) from error


def _script(root, relative, *arguments):
    return [sys.executable, str(root / relative), *arguments]


def _engine_head(engine):
    return _run(["git", "-C", str(engine), "rev-parse", "HEAD"],
                stdout=subprocess.PIPE, text=True, check=True).stdout.strip()


def _merge(root, reference, out):
    engine = root / ENGINE
    remote, _, branch = reference.partition("/")
    _must(["git", "-C", engine, "fetch", "--filter=blob:none", remote,
           f"refs/heads/{branch or reference}:refs/remotes/{reference}"], f"fetching {reference} failed")
    before = _engine_head(engine)
    _must(["git", "-C", engine, "merge", "--no-edit", reference],
          f"merge conflicts left in {ENGINE}: resolve them, commit, then run again with --no-merge")
    if _engine_head(engine) == before:
        out.info("already up to date")


def _carry(root):
    result = _run(_script(root, "scripts/carry-check.py"), stdout=subprocess.PIPE, text=True, errors="replace")
    for line in result.stdout.splitlines():
        if not line.startswith("ok"):
            print(line)
    if result.returncode:
        raise ConanException("the engine tree no longer holds what this port depends on")


def _delta(root):
    result = _run(_script(root, "scripts/port-delta.py"), stdout=subprocess.PIPE,
                  stderr=subprocess.DEVNULL, text=True, errors="replace")
    for line in result.stdout.splitlines()[:PORT_DELTA_LINES]:
        print(line)


def _build(root, profile):
    _must(["conan", "build", root, "-pr:h", profile, "-pr:b", "default", "--build=missing"],
          "the build failed")


def _host_checks(root):
    result = _must(_script(root, "tests/run-tests.py", "host"), "the host checks failed",
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    for line in result.stdout.rstrip("\n").splitlines()[-4:]:
        print(line)


def _deploy(root, build, device, out):
    deploy = revenant_checkout.import_file(
        root / "conan" / "extensions" / "commands" / "revenant" / "cmd_deploy.py", "revenant_cmd_deploy")
    deploy.deploy_engine(root, build, device, out)


def _gate(root, host):
    gate = revenant_checkout.import_file(root / "tests" / "device" / "run.py", "revenant_device_gate")
    if gate.run_gate(host):
        raise ConanException("the device gate failed; the verdicts are above")


def _device(root, conan_api, host, out):
    device = device_module(root, conan_api)
    if not device.reachable(10):
        raise ConanException("the phone is not reachable, so this integration is unverified "
                             "and must not be shipped")
    _deploy(root, engine_build(root, "system"), device, out)
    _gate(root, host)


@conan_command(group="Revenant")
def integrate(conan_api, parser, *args):
    """
    Take one upstream update through every gate this port has, in the order that fails cheapest
    first: the carry manifest, the build, the host checks, the phone.
    """
    target = parser.add_mutually_exclusive_group()
    target.add_argument("ref", nargs="?",
                        help=f"upstream ref to merge into {ENGINE}, e.g. upstream/main")
    target.add_argument("--no-merge", action="store_true",
                        help="run the gates on the engine tree as it is")
    add_root_argument(parser)
    parser.add_argument("--profile", default=os.path.join("profiles", "revenant-armv7"),
                        help="host profile the build uses; default: profiles/revenant-armv7")
    parser.add_argument("--host", help="address the phone reaches this Mac on, for the gate's page server")
    args = parser.parse_args(*args)

    out = ConanOutput()
    root = find_checkout(args.root)
    _run(["git", "-C", str(root / ENGINE), "config", "rerere.enabled", "true"])

    steps = []
    if args.ref:
        steps.append((f"merging {args.ref}", lambda: _merge(root, args.ref, out)))
    steps += [
        ("carry manifest", lambda: _carry(root)),
        ("port delta", lambda: _delta(root)),
        ("build, symbols and stage", lambda: _build(root, args.profile)),
        ("host checks", lambda: _host_checks(root)),
        ("the phone", lambda: _device(root, conan_api, args.host, out)),
    ]

    for title, step in steps:
        out.info(f"\n=== {title}")
        step()
    out.success("\nintegration green")
