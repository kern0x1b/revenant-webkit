import importlib.util
import re
import sys
from pathlib import Path

from conan.errors import ConanException

RECIPE_NAME = re.compile(r"""^\s*name\s*=\s*["']revenant-webkit["']""", re.MULTILINE)
DEVICE_CONF = {
    "host": "user.revenant:device_host",
    "port": "user.revenant:device_port",
    "password": "user.revenant:device_password",
    "udid": "user.revenant:device_udid",
}


def is_checkout(folder: Path) -> bool:
    recipe = folder / "conanfile.py"
    try:
        return recipe.is_file() and bool(RECIPE_NAME.search(recipe.read_text()))
    except OSError:
        return False


def add_root_argument(parser) -> None:
    parser.add_argument("--root", help="revenant-webkit checkout; default: the one holding the current directory")


def find_checkout(root_argument: str | None) -> Path:
    if root_argument:
        root = Path(root_argument).expanduser().resolve()
        if not is_checkout(root):
            raise ConanException(f"{root} is not a revenant-webkit checkout: "
                                 f"it has no conanfile.py declaring name = \"revenant-webkit\"")
        return root
    here = Path.cwd().resolve()
    for folder in (here, *here.parents):
        if is_checkout(folder):
            return folder
    raise ConanException(f"{here} is not inside a revenant-webkit checkout; "
                         f"run from one or pass --root")


def import_file(path: Path, name: str):
    path = Path(path)
    if not path.is_file():
        raise ConanException(f"{path} does not exist")
    loaded = sys.modules.get(name)
    if loaded is not None and Path(getattr(loaded, "__file__", "")).resolve() == path.resolve():
        return loaded
    folder = str(path.parent)
    if folder not in sys.path:
        sys.path.insert(0, folder)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def device_module(root: Path, conan_api):
    device = import_file(root / "tools" / "device.py", "device")
    overrides = {key: conan_api.config.get(conf) for key, conf in DEVICE_CONF.items()}
    device.configure(**overrides)
    return device


def engine_build(root: Path, variant: str) -> Path:
    build = root / "build" / "engine" / f"armv7-{variant}"
    if not build.is_dir():
        options = " -o prefixed=True" if variant == "prefixed" else ""
        raise ConanException(f"{build} does not exist - run conan build{options} at {root} first")
    return build


def staged_frameworks(root: Path) -> Path:
    return frameworks_in(engine_build(root, "system"), root)


def frameworks_in(build: Path, root: Path) -> Path:
    staged = build / "rev-sys-fw"
    if not (staged / "WebCore.framework" / "WebCore").is_file():
        raise ConanException(f"{staged} holds no laid-out frameworks - run conan build at {root} first")
    return staged


def standalone_app(root: Path) -> Path:
    app = engine_build(root, "prefixed") / "RevWebViewHost.app"
    if not (app / "RevWebViewHost").is_file():
        raise ConanException(f"{app} holds no RevWebViewHost binary - "
                             f"run conan build -o prefixed=True at {root} first")
    return app
