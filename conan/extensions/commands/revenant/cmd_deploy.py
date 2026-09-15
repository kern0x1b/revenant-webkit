import subprocess
from pathlib import Path

from conan.api.output import ConanOutput
from conan.cli.command import conan_command
from conan.errors import ConanException

import revenant_checkout

REMOTE = "/usr/lib/rev-fw"
FRAMEWORKS = ("JavaScriptCore", "WebCore", "WebKit")


def back_up_engine(device, out):
    out.info(f"backing up current engine -> {REMOTE}.bak")
    names = " ".join(FRAMEWORKS)
    device.run(30, f"mkdir -p {REMOTE}.bak; for fw in {names}; do "
                   f"cp -f {REMOTE}/$fw.framework/$fw {REMOTE}.bak/$fw 2>/dev/null || true; done",
               capture=False, check=True)


def install_binaries(device, staged: Path, out):
    for framework in FRAMEWORKS:
        out.info(f"installing {framework}")
        if not device.copy(staged / f"{framework}.framework" / framework,
                           f"{REMOTE}/{framework}.framework/{framework}", capture=False):
            raise ConanException(f"copying {framework} to the phone failed")


def install_webcore_resources(device, staged: Path, out):
    webcore = staged / "WebCore.framework"
    if not ((webcore / "modern-media-controls").is_dir() or (webcore / "Info.plist").is_file()):
        return
    entries = sorted(entry.name for entry in webcore.iterdir()
                     if not entry.name.startswith(".") and entry.name != "WebCore")
    out.info(f"installing WebCore resources ({len(entries)} entries)")
    status = device.pipe_into(["tar", "czf", "-", *entries],
                              f"cd {REMOTE}/WebCore.framework && tar xzf - && chmod -R 755 . 2>/dev/null",
                              cwd=webcore)
    if status:
        raise ConanException(f"streaming WebCore resources to the phone failed (exit {status})")


@conan_command(group="Revenant")
def deploy(conan_api, parser, *args):
    """
    Install the built engine frameworks into /usr/lib/rev-fw on the phone and restart Mobile Safari.
    """
    revenant_checkout.add_root_argument(parser)
    parser.add_argument("--build", help="engine build folder holding rev-sys-fw; "
                                        "default: build/engine/armv7-system of the checkout")
    parsed = parser.parse_args(*args)

    out = ConanOutput()
    root = revenant_checkout.find_checkout(parsed.root)
    if parsed.build:
        staged = revenant_checkout.frameworks_in(Path(parsed.build).expanduser().resolve(), root)
    else:
        staged = revenant_checkout.staged_frameworks(root)
    device = revenant_checkout.device_module(root, conan_api)
    out.info(f"deploying {staged} to {device.HOST}:{device.PORT}")

    probe = device.run(12, "echo ok")
    if probe.returncode:
        raise ConanException(f"the phone at {device.HOST}:{device.PORT} is unreachable: "
                             f"{(probe.stderr or '').strip() or f'exit {probe.returncode}'}")

    try:
        back_up_engine(device, out)
        install_binaries(device, staged, out)
        install_webcore_resources(device, staged, out)
        device.run(20, f"chmod 755 {REMOTE}/*/* 2>/dev/null; echo installed", capture=False, check=True)
    except subprocess.CalledProcessError as error:
        raise ConanException(f"remote step failed (exit {error.returncode}): {error.cmd}") from error

    out.info("restarting Mobile Safari (no respring)")
    device.run(15, "killall MobileSafari")
    out.success("engine deployed - verify the engine reports AppleWebKit/605")
