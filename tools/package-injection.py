#!/usr/bin/env python3
"""Copy a web app manifest's injected stylesheet and script into its bundle.

    package-injection.py manifest.json App.app

The runtime reads them back as inject.css and inject.js, so the names in the
manifest can change without the app binary knowing about it.
"""
import json
import os
import shutil
import sys

manifest, app = sys.argv[1], sys.argv[2]
directory = os.path.dirname(os.path.abspath(manifest))
data = json.load(open(manifest))

for key, name in (("inject_css", "inject.css"), ("inject_js", "inject.js")):
    relative = data.get(key)
    if not relative:
        continue
    source = os.path.normpath(os.path.join(directory, relative))
    shutil.copyfile(source, os.path.join(app, name))
    print(f"packaged {name} from {relative}")
