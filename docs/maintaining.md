# Carrying this port against a moving engine

The engine under this port is not ours, and the platform it targets was deleted
from it: upstream removed the ARMv7 JIT on 2026-08-01 and, with it, the whole
32-bit JSValue world — `main` today has no `LowLevelInterpreter32_64.asm`, no
`ARMv7Assembler.h`, and no `USE(JSVALUE32_64)` left in `Source/JavaScriptCore/runtime`.

Two consequences decide everything below. The port has to **own** that code
rather than inherit it, and it has to **find out early** when an upstream change
breaks it, because nothing upstream will ever tell us.

## The shape of the fork

| | |
| --- | --- |
| `main` in this fork | the product: upstream's tree plus this port, as commits |
| `upstream` remote | `WebKit/WebKit`. Never a branch of ours, only a remote |
| Topic branches | one per concern, each explaining in its commits why it exists |
| Frozen `ios6-armv7` | the original graft, kept as a tag so nothing is lost |

Two rules, both borrowed from projects that do this at scale:

- **Upstream first for anything generic.** A bug we fix in OpenSSL paths, in the
  Cairo gamma handling, in ICU's grapheme iterator is not port-specific, and
  every such fix we send upstream is one we stop carrying. Android's kernel team
  and Asahi both converged on this for the same reason.
- **Every carried change justifies itself in its commit message.** Electron's
  rule for its Chromium patches, and it is the only thing that keeps a carry
  reviewable years later.

## What "owning" means: the carry manifest

An upstream merge can break this port in three ways, and only one of them is
loud:

1. **It stops compiling.** Loud, and the build catches it.
2. **Something we carry silently disappears** — a file upstream deleted again, a
   feature flag that flipped, a symbol that stopped being exported. Nothing
   catches this until the device behaves strangely, or a page renders blank.
3. **Behaviour changes** under the same code. Only tests catch it.

For (2) the answer is a declarative manifest, checked before anything is built:

```
scripts/carry-check.sh        # reads carry-manifest.txt, exits non-zero with a list
```

What it asserts about a merged tree:

- **Files that must exist**, because the port cannot run without them:
  `assembler/{ARMv7Assembler,ARMv7Registers,MacroAssemblerARMv7}.h`,
  `MacroAssemblerARMv7.cpp`, `llint/LowLevelInterpreter32_64.asm`,
  `dfg/DFGSpeculativeJIT32_64.cpp`, `jit/JITOpcodes32_64.cpp`,
  `jit/CallFrameShuffler32_64.cpp`, `offlineasm/arm.rb`, the `bmalloc` iOS 6
  variant, the WebKitLegacy tree, the ANGLE EAGL backend this port wrote.
- **Build facts that must hold**: `ENABLE_JIT` on and `ENABLE_C_LOOP` off for
  armv7, `USE(JSVALUE32_64)` reached by the armv7 configuration, the CMake
  entries that name the files above.
- **Symbols that must stay exported**: the 147 imports the system's own
  libraries take from WebKit, WebCore and JavaScriptCore, pinned as a file and
  compared with `nm` against the built frameworks. UIKit needs 80 of them, and a
  missing one is a launch-time death with no crash log.
- **The guard census**: how many files carry `WEBKIT_IOS6`, by area. A merge that
  reverts one of our hunks usually shows up here first — the count drops in one
  directory.

The manifest is the cheapest tier by an order of magnitude: it reads the tree,
needs no compiler and no phone, and it is the thing that answers "what did this
merge quietly take away from us".

## The test pyramid, and what needs the phone

| Tier | Needs | Cost | What it catches |
| --- | --- | --- | --- |
| 1. Carry manifest | nothing | seconds | our code deleted, a flag flipped, a symbol gone |
| 2. Host checks | Mac | seconds | ICU data damage, the CA bundle's pin, generated encoding lists |
| 3. armv7 build | Mac | minutes | every API change upstream made to code we touch |
| 4. 32-bit JSC suites | Mac + container | tens of minutes | our own 32-bit JSValue and JIT carry, against upstream's own test262 and stress suites |
| 5. Device suite | the iPhone | minutes | UIKit, CoreText, CoreGraphics, the GPU, and whether pages actually paint |
| 6. Device long runs | the iPhone | tens of minutes | WebGL conformance, memory bands over cold launches, a crash sweep |

Tiers 1 to 4 are the answer to the question of testing without a phone, and tier
4 is the one worth building next. The trick is that the 32-bit value
representation is not iOS-specific: a JSCOnly build for 32-bit ARM Linux, run
under `qemu-user`, exercises the same `JSVALUE32_64` code and the same ARMv7 JIT
that the phone runs, and it can be driven by JavaScriptCore's own suites -
`run-javascriptcore-tests` with test262 and the stress tests, thousands of cases
per run. That is coverage of our largest and most fragile carry, on the host, in
a container, with no device in the loop.

What the phone remains irreplaceable for is everything the manifest cannot
describe and a Linux container does not have: a 2012 UIKit, this CoreText, this
CoreGraphics, the PowerVR driver, jetsam, and the question of whether a real
page paints. That is what `tests/device/` measures, and why it reports numbers
rather than screenshots.

## How an update actually runs

```sh
scripts/integrate.sh upstream/main      # or a series branch
```

In order, stopping at the first failure that matters:

1. `git merge` the chosen upstream ref into an integration branch, with
   `rerere.enabled` so a conflict resolved once is replayed next time.
2. `scripts/carry-check.sh` — before a single file is compiled.
3. `scripts/port-delta.sh` — the delta and the guard census, against the new
   base, kept as the before-and-after of the merge.
4. The armv7 build.
5. Host tests, then the 32-bit JSC suites.
6. The device suite, if the phone answers; otherwise the run is marked as
   unverified and is not shippable.

Only a run that reached the end green becomes `main`. The integration branch is
allowed to be red for as long as it takes — that is what it is for.

### Cadence

- **Per upstream release or release candidate**: merge, tiers 1 to 4. Frequent
  small merges are cheaper than rare large ones, and the kernel's own guidance
  for downstream trees says the same: merge at release points, not continuously,
  and keep topic branches narrow so each one moves independently.
- **Weekly**: the base series' own security picks, then the full pyramid, with
  the device.
- **Per series hop, or before anything is published**: tier 6 as well.

## The one thing standing between this and tracking `main`

`main` has no 32-bit JSValue at all, so basing on it requires carrying a 64-bit
NaN-boxed JSValue on ARMv7 — designed in [armv7-jit.md](armv7-jit.md), not
written. Until that exists, the integration branch against `main` is a
measurement, not a candidate, and shipping happens from the newest live series
of the GLib ports, which still carries the 32-bit world.

That is not a dependency on someone's goodwill: with a real merge base, the
choice of upstream ref is a one-line change, and every piece of the port,
including the 32-bit engine world, is a commit in this fork. If upstream deleted
its own history tomorrow, the port would still build.

## Order of work

1. **Ancestry.** A branch from the exact upstream commit this snapshot is based
   on, with the port replayed on top, verified by an empty `git diff` against the
   frozen graft. Then `main` is ours, `upstream` is a remote, and merges are
   merges.
2. **The manifest and its check.** Cheapest tier, largest return.
3. **Topic branches.** Split the carry by concern so a merge conflict lands in
   one subject at a time.
4. **32-bit JSC coverage on the host.** The container, the build, the suites.
5. **The integration branch against `main`**, to measure the real cost and to
   host the 64-bit JSValue work.
6. **Guards.** Of 1309 changed files under `Source`, 375 announce themselves with
   `WEBKIT_IOS6` and 934 do not. Every file moved into that column makes every
   future merge cheaper; this is the work that decides whether tracking `main`
   is sustainable.
