#!/usr/bin/env python3
"""Check how the tests find the engine build, without a phone or a build.

    tests/scripts/build-lookup.py

The rule under test: a build tree is one that holds conan/ios6-deps.env, and
when an older layout is still lying beside the current one the nearer tree
wins. Nothing here names build/system or build/engine, which is the point.
"""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MARKER = Path("conan") / "ios6-deps.env"


def tests_module():
    spec = importlib.util.spec_from_file_location("revenant_run_tests", ROOT / "tests" / "run-tests.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def tree(root: Path, *parts: str) -> Path:
    built = root.joinpath(*parts)
    (built / MARKER.parent).mkdir(parents=True, exist_ok=True)
    (built / MARKER).write_text("IOS6_HOST_LIBCXX=/nowhere\n")
    return built


def report(passed: bool, claim: str) -> bool:
    print("{:<6} {}".format("ok" if passed else "FAIL", claim))
    return passed


def refusal(call) -> str:
    try:
        call()
    except SystemExit as stop:
        return str(stop)
    return ""


def main() -> int:
    tests = tests_module()
    os.environ.pop("ENGINE_BUILD", None)
    verdicts = []

    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        only = tree(root, "build", "system")
        verdicts.append(report(tests.default_engine_build(root) == only,
                               "one tree holding the dependency environment is the answer"))

        orphan = tree(root, "build", "engine", "armv7-system")
        verdicts.append(report(tests.default_engine_build(root) == only,
                               "with {} beside it, the nearer {} wins".format(
                                   orphan.relative_to(root), only.relative_to(root))))

        named = tree(root, "build", "elsewhere-system")
        said = refusal(lambda: tests.default_engine_build(root))
        verdicts.append(report(all(part in said for part in ("build/system", "build/elsewhere-system")),
                               "two trees at the same depth refuse and name both, not one: " + said))
        for path in (named / MARKER, orphan / MARKER):
            path.unlink()

        os.environ["ENGINE_BUILD"] = str(root / "somewhere-else")
        verdicts.append(report(tests.default_engine_build(root) == root / "somewhere-else",
                               "ENGINE_BUILD names the build and nothing is searched"))
        os.environ.pop("ENGINE_BUILD")

    with tempfile.TemporaryDirectory() as folder:
        said = refusal(lambda: tests.default_engine_build(Path(folder)))
        verdicts.append(report("no built engine" in said,
                               "no tree at all refuses and says so: " + said))

    print("build lookup intact" if all(verdicts) else "BUILD LOOKUP BROKEN")
    return 0 if all(verdicts) else 1


if __name__ == "__main__":
    sys.exit(main())
