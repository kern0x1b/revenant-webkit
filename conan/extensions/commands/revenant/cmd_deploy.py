import subprocess
from pathlib import Path

from conan.api.output import ConanOutput
from conan.cli.command import conan_command
from conan.errors import ConanException

import revenant_checkout


def frameworks_of(staged: Path):
    return sorted(path.stem for path in staged.glob(f"*{revenant_checkout.FRAMEWORK}"))


def back_up_engine(device, remote: str, frameworks, out):
    out.info(f"backing up current engine -> {remote}.bak")
    names = " ".join(frameworks)
    device.run(30, f"mkdir -p {remote}.bak; for fw in {names}; do "
                   f"cp -f {remote}/$fw{revenant_checkout.FRAMEWORK}/$fw {remote}.bak/$fw 2>/dev/null || true; done",
               capture=False, check=True)


def install_binaries(device, staged: Path, remote: str, frameworks, out):
    for framework in frameworks:
        out.info(f"installing {framework}")
        bundle = f"{framework}{revenant_checkout.FRAMEWORK}"
        if not device.copy(staged / bundle / framework, f"{remote}/{bundle}/{framework}", capture=False):
            raise ConanException(f"copying {framework} to the phone failed")


def install_resources(device, staged: Path, remote: str, frameworks, out):
    for framework in frameworks:
        bundle = staged / f"{framework}{revenant_checkout.FRAMEWORK}"
        entries = sorted(entry.name for entry in bundle.iterdir()
                         if not entry.name.startswith(".") and entry.name != framework)
        if not entries:
            continue
        out.info(f"installing {framework} resources ({len(entries)} entries)")
        status = device.pipe_into(["tar", "czf", "-", *entries],
                                  f"cd {remote}/{bundle.name} && tar xzf - && chmod -R 755 . 2>/dev/null",
                                  cwd=bundle)
        if status:
            raise ConanException(f"streaming {framework} resources to the phone failed (exit {status})")


@conan_command(group="Revenant")
def deploy(conan_api, parser, *args):
    """
    Install the built engine frameworks where the package puts them on the phone and restart Mobile Safari.
    """
    revenant_checkout.add_root_argument(parser)
    parser.add_argument("--build", help="engine build folder whose stage holds the laid-out frameworks; "
                                        "default: build/engine/armv7-system of the checkout")
    parsed = parser.parse_args(*args)

    out = ConanOutput()
    root = revenant_checkout.find_checkout(parsed.root)
    if parsed.build:
        staged = revenant_checkout.frameworks_in(Path(parsed.build).expanduser().resolve(), root)
    else:
        staged = revenant_checkout.staged_frameworks(root)
    remote = revenant_checkout.device_location(staged)
    frameworks = frameworks_of(staged)
    device = revenant_checkout.device_module(root, conan_api)
    out.info(f"deploying {staged} to {device.HOST}:{device.PORT} {remote}")

    probe = device.run(12, "echo ok")
    if probe.returncode:
        raise ConanException(f"the phone at {device.HOST}:{device.PORT} is unreachable: "
                             f"{(probe.stderr or '').strip() or f'exit {probe.returncode}'}")

    try:
        back_up_engine(device, remote, frameworks, out)
        install_binaries(device, staged, remote, frameworks, out)
        install_resources(device, staged, remote, frameworks, out)
        device.run(20, f"chmod 755 {remote}/*/* 2>/dev/null; echo installed", capture=False, check=True)
    except subprocess.CalledProcessError as error:
        raise ConanException(f"remote step failed (exit {error.returncode}): {error.cmd}") from error

    out.info("restarting Mobile Safari (no respring)")
    device.run(15, "killall MobileSafari")
    out.success("engine deployed - verify the engine reports AppleWebKit/605")
