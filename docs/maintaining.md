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

```sh
scripts/carry-check.sh        # reads carry-manifest.txt, exits non-zero with a list
```

It found its first real problem on the day it was written - an assertion that
named the wrong header for `-[WAKWindow _windowRef]`, the accessor UIKit uses to
get its window and the last thing that had to be restored before the engine
would load at all.

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
- **The symbol surface**, in `carry-symbols.txt` and checked by
  `scripts/symbol-check.sh` once a build exists: every symbol the three
  frameworks leave undefined - 6603 of them - and every Objective-C class they
  export by name. A *new* undefined symbol is the important one: it means an
  upstream change reached for API this system may not have, and dyld kills the
  process at load with no crash log. A lost exported class is the same death
  from the other side, since UIKit and Safari link `WebView` and its siblings by
  name.
- **The guard census**: how many files carry `WEBKIT_IOS6`, by area. A merge that
  reverts one of our hunks usually shows up here first — the count drops in one
  directory.

The manifest is the cheapest tier by an order of magnitude: it reads the tree,
needs no compiler and no phone, and it is the thing that answers "what did this
merge quietly take away from us".

### When the symbol gate fires

It is a question, not a verdict. Each new undefined symbol is looked up against
what iOS 6 has, and there are only two outcomes: either the system has it - the
engine loads, the suite passes, and the pin is regenerated with
`scripts/symbol-check.sh --pin` so the new baseline is one the device has
verified - or it does not, and something has to provide it.

The first time this ran in anger, on 2026-09-11, it was the second case: an
ANGLE roll had started calling `crc32_z`, which zlib gained in 1.2.9 and this
system's 1.2.5 does not have. Nothing in a build would have said so. On the
device it is a refusal at load, with no crash log and no output - the failure
this port has spent the most time chasing blind.

## The test pyramid, and what needs the phone

| Tier | Needs | Cost | What it catches |
| --- | --- | --- | --- |
| 1. Carry manifest | nothing | seconds | our code deleted, a flag flipped, a guard reverted |
| 2. Host checks | Mac | seconds | ICU data damage, the CA bundle's pin, generated encoding lists |
| 3. armv7 build, then the symbol check | Mac | minutes | every API change upstream made to code we touch, and any new dependency on API iOS 6 may not have |
| 4. 32-bit JSC build, then its suites | Mac + container | tens of minutes | our own 32-bit JSValue and JIT carry. The build is live; running the binary under emulation aborts at startup and is not solved yet - see tests/README.md |
| 5. Device suite | the iPhone | minutes | UIKit, CoreText, CoreGraphics, the GPU, and whether pages actually paint |
| 6. Device long runs | the iPhone | tens of minutes | WebGL conformance, memory bands over cold launches, a crash sweep |

Tiers 1 to 4 are the answer to the question of testing without a phone, and tier
4 exists: `tests/jsc32/`. The 32-bit value representation is not iOS-specific, so
a JSCOnly build for 32-bit ARM Linux exercises the same `JSVALUE32_64` code, the
same macro assembler and the same DFG that the phone runs. A container
cross-compiles it at native speed and `qemu-arm-static` runs it, driven by
JavaScriptCore's own suites. That is coverage of this port's largest and most
fragile carry, on the host, with no device in the loop - and it found a real
missing include the device build hides inside a unified source on the first run
it completed.

What the phone remains irreplaceable for is everything the manifest cannot
describe and a Linux container does not have: a 2012 UIKit, this CoreText, this
CoreGraphics, the PowerVR driver, jetsam, and the question of whether a real
page paints. That is what `tests/device/` measures, and why it reports numbers
rather than screenshots.

## How an update actually runs

```sh
scripts/integrate.sh upstream/webkitglib/2.54   # the series' own picks
scripts/integrate.sh upstream/main              # the base change, when it is time
scripts/integrate.sh --no-merge                 # just run the gates on what is here
```

In order, stopping at the first failure that matters:

1. `git merge` the chosen upstream ref into an integration branch, with
   `rerere.enabled` so a conflict resolved once is replayed next time.
2. `scripts/carry-check.sh` — before a single file is compiled.
3. `scripts/port-delta.sh` — the delta and the guard census, against the new
   base, kept as the before-and-after of the merge.
4. The armv7 build.
5. `scripts/symbol-check.sh` against the pin.
6. Host tests.
7. Deploy, then the device suite — if the phone answers. If it does not, the run
   exits 3 and says the integration is unverified and must not be shipped.

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

### Running it on a schedule

Nothing here needs a service. One crontab line takes the series' own picks every
Monday morning and leaves a log to read:

```
0 9 * * 1  cd ~/path/to/port && scripts/integrate.sh upstream/webkitglib/2.54 >> ~/port-integration.log 2>&1
```

It stops at the first gate that fails, and a run that cannot reach the phone
exits 3 rather than reporting success - so an unattended run either produces a
green log or a reason. What it must never do is push: a merge that nobody has
read is not a release, and the only thing that makes a run shippable is a person
looking at the device.

## What tracking `main` costs today, measured

`git merge-tree` computes the merge without touching a working tree, so the
question can be answered before anyone commits to it. Merging this port's `main`
with upstream's, on 2026-09-11:

```
337 files conflict
  150  Source/ThirdParty      ANGLE rolled forward on trunk
   99  Source/WebCore
   30  Source/JavaScriptCore
   16  Source/WebKit
   15  Source/WTF
```

Of those 337, **143 are files this port changed**. The rest is the year of
divergence between the 2.54 branch and trunk, which any base change would have
to absorb once and then never again.

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
