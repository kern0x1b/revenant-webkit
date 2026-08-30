#!/usr/bin/env bash
# The code generators are Python 2; python2 is gone from macOS. Converting them
# is less work than shipping an interpreter, and lib2to3 handles these five.
set -e
cd "$(dirname "$0")/webkit-603"
for f in Source/JavaScriptCore/generate-bytecode-files \
         Source/JavaScriptCore/disassembler/udis86/ud_opcode.py \
         Source/JavaScriptCore/replay/scripts/CodeGeneratorReplayInputs.py \
         Source/JavaScriptCore/inspector/scripts/generate-inspector-protocol-bindings.py \
         Source/JavaScriptCore/inspector/scripts/codegen/objc_generator.py; do
    python3 -m lib2to3 -w -n --no-diffs "$f" >/dev/null 2>&1 && echo "converted $f"
done
