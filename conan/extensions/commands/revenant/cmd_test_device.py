import logging
import sys
from pathlib import Path

from conan.api.output import ConanOutput
from conan.cli.command import conan_command
from conan.errors import ConanException

import revenant_checkout

TIERS = ("gate", "batteries")


class ConanOutputHandler(logging.Handler):
    def emit(self, record):
        message = self.format(record)
        if record.levelno >= logging.ERROR:
            ConanOutput().error(message)
        elif record.levelno >= logging.WARNING:
            ConanOutput().warning(message)
        else:
            ConanOutput().info(message)


def exit_status(run, *arguments) -> int:
    try:
        return run(*arguments)
    except SystemExit as stop:
        return stop.code if isinstance(stop.code, int) else 1


def run_gate(root: Path, host: str | None) -> int:
    gate = revenant_checkout.import_file(root / "tests" / "device" / "run.py", "revenant_device_gate")
    return exit_status(gate.run_gate, host)


def run_batteries(root: Path, build: Path) -> int:
    batteries = revenant_checkout.import_file(root / "tests" / "run-tests.py", "revenant_run_tests")
    logger = logging.getLogger("run-tests")
    handler = ConanOutputHandler()
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    try:
        return exit_status(batteries.run_device_tests, root, build)
    finally:
        logger.removeHandler(handler)
        sys.stdout.flush()


@conan_command(group="Revenant")
def test_device(conan_api, parser, *args):
    """
    Run the device tiers on the phone: the Safari page gate, the JavaScript batteries, or both.
    """
    revenant_checkout.add_root_argument(parser)
    parser.add_argument("--host", help="address the phone reaches this Mac on; default: this Mac's en0")
    parser.add_argument("--tier", choices=(*TIERS, "all"), default="all", help="which tier to run (default: all)")
    parser.add_argument("--engine-build", help="engine build folder the batteries take jsc and frameworks from; "
                                               "default: build/engine/armv7-system of the checkout")
    parsed = parser.parse_args(*args)

    out = ConanOutput()
    root = revenant_checkout.find_checkout(parsed.root)
    tiers = TIERS if parsed.tier == "all" else (parsed.tier,)
    build = None
    if "batteries" in tiers:
        if parsed.engine_build:
            build = Path(parsed.engine_build).expanduser().resolve()
        else:
            build = revenant_checkout.engine_build(root, "system")
    device = revenant_checkout.device_module(root, conan_api)
    out.info(f"device: {device.HOST}:{device.PORT}")

    results = {}
    for tier in tiers:
        out.title(f"device tier: {tier}")
        sys.stdout.flush()
        results[tier] = run_gate(root, parsed.host) if tier == "gate" else run_batteries(root, build)

    out.title("device tiers")
    for tier, status in results.items():
        if status:
            out.error(f"{tier}: FAILED ({status})")
        else:
            out.success(f"{tier}: PASSED")
    failed = [tier for tier, status in results.items() if status]
    if failed:
        raise ConanException(f"device tiers failed: {', '.join(failed)}")
