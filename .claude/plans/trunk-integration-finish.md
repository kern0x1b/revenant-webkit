# Finishing the trunk integration

## Goal

The port runs on the tip of upstream `main`, with every carried adaptation
intact, on the iPhone 4S and the iPad 2. Nothing hardcoded, nothing stubbed,
nothing lost.

## Where this starts

- `webkit-254` branch `trunk-integration`, grafted onto `upstream/main` of
  2026-09-11 (`9b092940764f`).
- Device gate 55/55 on the phone, 52/55 on the iPad (three are a missing emoji
  font, not code).
- All 5725 of `JSTests/stress` run on the phone; the thirteen that do not pass
  are memory limits, an on-purpose crash, and tests wanting harness flags.
- Everything is committed locally; nothing is pushed.

## Step 1 - catch up with upstream (143 commits)

`upstream/main` is at `c70a794b0341` of 2026-09-14, 143 commits ahead of the
graft base.

1. Merge `upstream/main` into `trunk-integration`.
2. Resolve conflicts by the rule the port already uses: the carried side wins
   where `carry-manifest.txt` pins it, upstream wins everywhere else, and every
   resolution that is neither gets read by hand.
3. `scripts/carry-check.sh` must pass - it is what proves nothing carried was
   dropped in the merge.
4. Build `build-254-trunk`, deploy, run the device gate on the phone.
5. Re-run the parts of `JSTests/stress` that the merge touched; a full sweep
   only if the gate or the build says something changed under JavaScriptCore.

Done when: the gate is 55/55 on the merged engine and `carry-check.sh` is
clean.

## Step 2 - the 220 files still at the 2023 base

277 files under `Source/JavaScriptCore` and `Source/WTF` were byte-for-byte the
2023 base; 57 are adopted, 220 remain. They work, but they are the fork's
content, not trunk's.

Per family, smallest blast radius first:

- `yarr` - trunk's files plus the ARMv7 register carries and the JIT log.
- `bytecode` - first answer whether the 32-bit `ConcurrentJSLocker` carry is
  still needed now that `decodeConcurrent()` exists.
- `jit` - blocked on the SnippetReg family and `JITCode`'s 64-bit pointer
  packing; both need a 32-bit answer before the files can be taken.
- `dfg` - last, it depends on the three above.

Each family: take trunk's files, re-apply the carries, build, run the gate,
commit. A family that does not build cleanly gets backed out with
`git show HEAD:<file> > <file>` and written up rather than forced.

Done when: the stale count is zero, or every remaining file has a written
reason to stay.

## Step 3 - the 32-bit varargs miscompilation

DFG inlining of a varargs call returns a JSValue with its halves swapped.
Not a graft regression - the fork does the same. Mitigated by
`Options::maximumVarargsForInlining() = 0` on `USE(JSVALUE32_64)`, which is a
lost optimization, not a fix.

Narrowed already: needs varargs inlining specifically; not about constructors;
not the 32-bit store protocol; `operationLoadVarargs` gets its arguments right;
DFG assertions and graph validation are silent; disabling OSR entry makes it
worse, so the bug is in the compiled code itself.

Next probe: compare the DFG graph and the generated code for the inlined
varargs call against the same function compiled with inlining off, and find
where the tag and payload registers part company.

Done when: the option default can go back to upstream's value and the repro
passes.

## Step 4 - the iPad's emoji font

Three gate checks want a modern `AppleColorEmoji.ttf`. The installer resprings
and assumes an `@2x` file; the iPad is 1x and has 133MB free on the system
partition against a 63MB font. Needs a 1x-only path and no respring, or an
explicit decision to leave the iPad at 52/55.

## Out of scope

- Pushing anything. Everything stays local until asked.
- The tweak's first-load window-object gap; it lives in the other repo.

## Verification, every step

`scripts/carry-check.sh`, a build of `build-254-trunk`, `scripts/deploy-engine.sh`,
`tests/device/run.sh` against the phone. The iPad gets the same engine once the
phone's gate is green.
