import time
from pathlib import Path

from conan.api.output import ConanOutput
from conan.cli.command import conan_command
from conan.errors import ConanException

import revenant_checkout

SCHEME = "revwebviewhost"
INSTALL = "cd /Applications && tar xzf - && chmod +x /Applications/RevWebViewHost.app/RevWebViewHost"


def human_size(path: Path) -> str:
    total = sum(entry.stat().st_size for entry in path.rglob("*") if entry.is_file())
    for unit in ("B", "K", "M", "G"):
        if total < 1024:
            return f"{total:.0f}{unit}" if unit == "B" else f"{total:.1f}{unit}"
        total /= 1024
    return f"{total:.1f}T"


def launch_script(wait: int, url: str) -> str:
    lines = ["rm -f /tmp/rev-webview-host.log /tmp/rev-url.txt"]
    if url:
        lines.append(f"echo '{url}' > /tmp/rev-url.txt")
    lines += [
        "su mobile -c uicache >/dev/null 2>&1",
        "sleep 4",
        f"uiopen {SCHEME}://",
        f"sleep {wait}",
        "echo '--- rev-webview-host.log ---'",
        "cat /tmp/rev-webview-host.log 2>&1",
    ]
    return "\n".join(lines)


def wait_for_phone(device, attempts=3, pause=5) -> bool:
    for attempt in range(attempts):
        if "up" in device.output(20, "echo up"):
            return True
        if attempt + 1 < attempts:
            time.sleep(pause)
    return False


@conan_command(group="Revenant")
def run_app(conan_api, parser, *args):
    """
    Install the standalone RevWebViewHost.app on the phone, launch it and print its log.
    """
    revenant_checkout.add_root_argument(parser)
    parser.add_argument("--wait", type=int, default=20, help="seconds to let the app run (default: 20)")
    parser.add_argument("--url", default="", help="page the app opens first")
    parsed = parser.parse_args(*args)

    out = ConanOutput()
    root = revenant_checkout.find_checkout(parsed.root)
    app = revenant_checkout.standalone_app(root)
    device = revenant_checkout.device_module(root, conan_api)

    out.info(f"device: {device.HOST}:{device.PORT}")
    if not wait_for_phone(device):
        out.warning("the phone did not answer; trying anyway")
    device.run(40, "killall -9 RevWebViewHost 2>/dev/null; rm -rf /Applications/RevWebViewHost.app")

    out.info(f"copying {human_size(app)}")
    status = device.pipe_into(["tar", "-czf", "-", app.name], INSTALL, cwd=app.parent)
    if status:
        raise ConanException(f"copying {app.name} to the phone failed (exit {status})")

    result = device.run(parsed.wait + 60, launch_script(parsed.wait, parsed.url), capture=False)
    if result.returncode:
        raise ConanException(f"launching {app.name} failed (exit {result.returncode})")
