# Keeping the engine current

The engine is a real fork. `main` in this fork is upstream's history with this
port's commits on top of `1b78c03f880e`, so upstream is an ancestor and a merge
is a merge. It was a graft until 2026-09-11 - a snapshot with no shared
ancestry, updated by applying other people's diffs - and
[maintaining.md](maintaining.md) is what that fork is carried by now.

How far the port has drifted is still a question about content rather than about
the log, and `scripts/port-delta.sh` answers it. Today, against
`origin/webkitglib/2.54`:

```
1396 files changed, 52650 insertions(+), 9987 deletions(-)

  Source/WebCore          585 files  +24105  -5358
  Source/WebKitLegacy     389 files  +5181   -313
  Source/JavaScriptCore   169 files  +14478  -1107
  Source/bmalloc           56 files  +5392   -13
  Source/WTF               56 files  +1851   -328
```

## How far behind the snapshot is

`scripts/port-delta.sh --freshness` answers that from content rather than dates,
because content is what the question is really about: for each commit on the upstream branch
it takes a line that commit added and looks for it in our tree, and the first
one we already carry is where the snapshot sits. Today:

```
branch tip: 2026-09-03  Cherry-pick 305413.1005@safari-7624.5.1.10-branch
we carry:   2026-09-03  Cherry-pick 305413.1005@safari-7624.5.1.10-branch
behind by:  0 commits
```

So the engine is not on an old WebKit: it is on the current stable series,
version 626.1.1, level with that branch's tip. The series is alive -
`webkitglib/2.54` last moved on 2026-09-03 and `2.52` on 2026-09-04, both taking
cherry-picks from Safari's branch, while `2.50` stopped in March.

Distance from `main` cannot be answered from this clone: `main` is fetched as a
single commit, so its history is not here. The relationship is the usual one -
the 2.54 branch is cut from main and receives security and stability picks,
while main is where new work lands.

## What that delta actually is

Two thirds of it is not port-specific logic:

- **JavaScriptCore, +14.5k across 174 files** — but two thirds of that is four
  files: the ARMv7 disassembler, which the base branch does not build, and the
  unexported-libc++ list, together 9321 lines that move only when the toolchain
  does. The ARMv7 JIT itself is *not* in this delta: `webkitglib/2.54` still
  ships it, wired into `CMakeLists.txt`, and the port builds with
  `ENABLE_JIT=ON`, `ENABLE_DFG_JIT=ON`, `ENABLE_C_LOOP=OFF`. What is left, some
  five thousand lines, is this port's own tuning of the collector, the inline
  caches, the code cache and the ARMv7 macro assembler.
- **WebKitLegacy, +5.3k across 389 files.** The WebKit1 API, which upstream keeps
  but no longer builds for iOS. Mostly reinstatement and build plumbing.
- **bmalloc, 50 new files.** The allocator's iOS 6 variant, self-contained.

The part that has to be understood on every update is the rest: the changes that
adapt current WebKit to a 2012 system.

## Why changing base is realistic

Of the 1309 files changed under `Source`, **375 carry the `WEBKIT_IOS6` guard**
and announce themselves. Those hunks say
what they are and where they belong, and they can be replayed onto a newer tree
by matching the guard rather than by matching context lines.

**934 do not**, and they are where the cost is. By area:

```
Source/WebKitLegacy   373
Source/WebCore        328
Source/JavaScriptCore 106
Source/bmalloc         56
```

The WebKitLegacy and bmalloc ones are wholesale reinstatement, so they move as
files rather than as hunks. The WebCore and JavaScriptCore ones - some 440 files -
are the real work of an update.

## Two kinds of update

They cost very different things.

**Inside the series** — `webkitglib/2.54` taking security and stability picks
from Safari's branch. With ancestry this is an ordinary merge:

```sh
git -C webkit-254 fetch upstream 'refs/heads/webkitglib/2.54:refs/remotes/upstream/webkitglib/2.54'
git -C webkit-254 merge upstream/webkitglib/2.54
```

Conflicts land only where a pick touches a file this port also changed, which
`scripts/port-delta.sh` lists, and `rerere.enabled` means a resolution is only
made once. Then the carry check, the build, and `tests/device/run.sh`.

The last update done the old way, on 2026-09-10, took the branch's five newest
picks as a diff: none touched a port-changed file, the engine rebuilt whole
because one of them changed a WebCore base class, and the suite stayed at 55 of
55.

**Changing series** — 2.54 to 2.56 or later, or to `main`. That is the work
below, and it is the one that also has to carry the ARMv7 JIT forward.

## The trunk attempt, 2026-09-11

Tried for real, on a branch, to see what it costs rather than to guess. What the
merge with `upstream/main` produced, and what came out of working through it:

**202 conflicted paths.** 179 both-modified, 16 files this port changed that
upstream deleted, 6 added on both sides, 1 the other way round. Of those, 21
were upstream against upstream - the series' own cherry-picks against trunk's
evolution, in files this port never touched - and taking trunk's side is right
for all of them. 35 more are in code this port does not build. That leaves
**about 145 files that have to be read**, 199 conflict hunks, and roughly half
carry a `WEBKIT_IOS6` guard on one side.

**476 files the merge deleted without conflicting at all.** Most are upstream's
own removals over 3222 commits, but five were load-bearing here - the 32-bit
LLInt, the ARMv7 registers and macro assembler, two 32-bit JIT sources - and
nothing in git said so, because this port had not touched them since the branch
point. `scripts/carry-check.sh` named all five in under a second. That is the
clearest argument for the manifest that exists.

**Two build systems have to be carried, not merged.** Upstream removed the iOS
CMake port outright: `Source/cmake/OptionsIOS.cmake` and every
`PlatformIOS.cmake` are gone from trunk, so they become this port's files rather
than edits to upstream's. The offlineasm backend list and the JavaScriptCore
source list lost their ARMv7 entries the same silent way the sources did.

**Preferences changed shape.** `UnifiedWebPreferences.yaml` is validated far
more strictly on trunk: a frontend that only carries a default must be written
as a scalar, frontends must appear in the order WebKitLegacy, WebKit, WebCore,
and a value equal to the shared default has to be left out. The port's 33
enabled features transplant cleanly once written that way, and the list of
exactly which 33 comes out of `git diff` rather than memory.

Where it stopped: JavaScriptCore and WTF are fully merged, 68 files in WebCore
and below are not, and the 32-bit JavaScriptCore build against trunk gets as far
as compiling WTF. `JSCJSValue.h` needs its 32-bit half re-threaded into a
conditional chain trunk rewrote around it - that one is real work, not a
mechanical merge.

The branch is `trunk-integration` in the engine fork, and `git rerere` recorded
183 resolutions along the way, so redoing the merge replays them instead of
asking again.

## The procedure this argues for

1. Run `scripts/port-delta.sh` against the current base and keep the output. It
   is the before picture, and the after picture has to be explainable.
2. Fetch the new upstream branch and diff it against the current base to see
   which of the 440 unguarded WebCore/JSC files upstream also touched. Only those
   need reading; the rest carry over.
3. Take the new tree, apply the reinstatement wholesale (WebKitLegacy, bmalloc),
   then the guarded hunks, then the read set from step 2 by hand.
4. **If the new series has dropped ARMv7** — trunk did on 2026-08-01, so any
   series cut after that has — the JIT has to be carried over as well, and the
   copy to carry is this fork's own branch, which builds and runs it today.
   `webkitglib/2.54` is the last base that supplies it for free. What comes
   across is `assembler/{ARMv7Assembler,ARMv7Registers,MacroAssemblerARMv7}.h`,
   `MacroAssemblerARMv7.cpp`, the 32-bit tiers
   (`dfg/DFGSpeculativeJIT32_64.cpp`, `jit/JITOpcodes32_64.cpp`,
   `jit/CallFrameShuffler32_64.cpp`), `offlineasm/arm.rb` and the build entries
   that name them — plus this port's own fixes on top of them, which are in the
   delta above. Expect the JSValue representation to be the hard part: see
   [armv7-jit.md](armv7-jit.md).
5. Build, then run `tests/device/run.sh`. The suite is the acceptance test: it
   is numeric, it runs on the device, and it stands at 55 of 55 today.
6. Anything the suite does not cover that the update touches gets a check added
   to it first, not after.

## What the guard is for now

Of the 1309 files changed under `Source`, 375 carry the `WEBKIT_IOS6` guard and
920 do not. That number used to matter a great deal: with a graft, the guard was
the only way a future re-graft could find this port's changes without reading
every file.

Ancestry changed that. A merge finds the changes by history, so the guard's
remaining job is narrower and still worth something: it tells a person reading a
conflict which side is the port and why it is there. That is a reason to guard a
subtle hunk in code upstream is actively changing - the graphics platform layer,
the loader, JavaScriptCore's platform code - and not a reason to wrap 460 files
mechanically, which would change meaning in some of them for no benefit.

For triage during a merge:

```sh
scripts/port-delta.sh --unguarded Source/WebCore/platform
```

lists the changed files in an area that carry no guard, largest diff first -
that is the read-by-hand set if a conflict lands there.

Of the 920, 81 are files that exist only in this port, 26 are build and
generator files, and 460 are source files outside the wholesale reinstatements
of WebKitLegacy and bmalloc. Their median diff is ten lines.
