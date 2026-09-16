#!/usr/bin/env python3
"""Compare charon.toml against conanfile.py, value by value.

    tests/scripts/declaration-matches-recipe.py

The declaration was transcribed from the recipe by hand, which is where a silent
error hides: a wrong CMake flag shows up as a differently built engine, hours
later. This reads both - the recipe through its syntax tree, so nothing is
executed - and refuses on any difference. It exists only until the recipe is
generated from the declaration, and then it has nothing left to compare.
"""
import ast
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ROOT / "conanfile.py"
MANIFEST = ROOT / "charon.toml"
PLACEHOLDER = "{"


def declared():
    with MANIFEST.open("rb") as handle:
        return tomllib.load(handle)


def recipe_tree():
    return ast.parse(RECIPE.read_text())


def literal(node):
    try:
        return ast.literal_eval(node)
    except (ValueError, SyntaxError):
        return None


def cache_variables(tree):
    found = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        if node.func.attr != "update" or not node.args or not isinstance(node.args[0], ast.Dict):
            continue
        for key, value in zip(node.args[0].keys, node.args[0].values):
            name = literal(key)
            if isinstance(name, str):
                found.setdefault(name, []).append(literal(value))
    return found


def called_with(tree, method):
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == method:
            if node.args:
                reference = literal(node.args[0])
                if isinstance(reference, str):
                    found.append(reference)
    return found


def references(section):
    return ["{}/{}".format(name, version) for name, version in section.items()]


def compare_requirements(spec, tree, failures):
    for method, section, what in (("requires", "requires", "libraries"),
                                  ("tool_requires", "tools", "build tools")):
        wanted = references(spec.get(section, {}))
        found = called_with(tree, method)
        for reference in sorted(set(found) - set(wanted)):
            failures.append("the recipe {} {} and the declaration does not".format(what, reference))
        for reference in sorted(set(wanted) - set(found)):
            failures.append("the declaration {} {} and the recipe does not".format(what, reference))
        if set(found) == set(wanted) and found != wanted:
            failures.append("the {} are declared in a different order than the recipe requires them, and the "
                            "order decides which include and library folder CMake searches first: recipe {}, "
                            "declaration {}".format(what, found, wanted))


def compare_options(spec, tree, failures):
    options = spec.get("engine", {}).get("options", {})
    overrides = spec.get("variants", {}).get("prefixed", {}).get("engine-options", {})
    in_recipe = cache_variables(tree)
    for name, values in sorted(in_recipe.items()):
        if name.startswith("CMAKE_") or name in ("IOS6_SDK", "IOS6_DEPLOYMENT_TARGET", "PYTHON_EXECUTABLE"):
            continue
        constants = [value for value in values if isinstance(value, str)]
        if name in overrides and len(values) > 1:
            continue
        if name not in options:
            failures.append("the recipe sets {} and the declaration does not".format(name))
            continue
        declared_value = options[name]
        if constants and constants[0] != declared_value:
            failures.append("{}: the recipe says {} and the declaration says {}".format(
                name, constants[0], declared_value))
        if not constants and PLACEHOLDER not in str(declared_value):
            failures.append("{}: the recipe computes it, so the declaration must use a substitution, "
                            "not {}".format(name, declared_value))
    for name in sorted(options):
        if name not in in_recipe:
            failures.append("the declaration sets {} and the recipe does not".format(name))


def main():
    spec, tree = declared(), recipe_tree()
    failures = []
    compare_requirements(spec, tree, failures)
    compare_options(spec, tree, failures)
    for line in failures:
        print("FAIL  {}".format(line))
    if failures:
        print("{} differences between the declaration and the recipe".format(len(failures)))
        return 1
    print("ok    {} engine options, {} libraries and {} build tools agree with the recipe".format(
        len(spec.get("engine", {}).get("options", {})), len(spec.get("requires", {})), len(spec.get("tools", {}))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
