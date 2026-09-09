# Keeping the engine current

The engine here is a graft: the port branch carries five commits of its own and
no ancestry to upstream, so how far it has drifted cannot be read from the log.
It can be read from the diff against the upstream branch the snapshot was cut
from, and `scripts/port-delta.sh` prints exactly that. Today, against
`origin/webkitglib/2.54`:

```
1389 files changed, 53291 insertions(+), 10124 deletions(-)

  Source/WebCore          580 files  +25151  -5207
  Source/WebKitLegacy     389 files  +5268   -306
  Source/JavaScriptCore   174 files  +15064  -1177
  Source/bmalloc           56 files  +5392   -13
  Source/WTF               55 files  +2075   -237

1247 modified, 82 added, 60 deleted
```

## How far behind the snapshot is

`scripts/port-delta.sh --freshness` answers that from content rather than dates,
because a graft has no dates to compare: for each commit on the upstream branch
it takes a line that commit added and looks for it in our tree, and the first
one we already carry is where the snapshot sits. Today:

```
branch tip: 2026-09-03  Cherry-pick 305413.1005@safari-7624.5.1.10-branch
we carry:   2026-09-03  Cherry-pick 305413.982@safari-7624.5.1.10-branch
behind by:  5 commits
```

So the engine is not on an old WebKit: it is on the current stable series,
version 626.1.1, five commits behind that branch's tip. The series is alive -
`webkitglib/2.54` last moved on 2026-09-03 and `2.52` on 2026-09-04, both taking
cherry-picks from Safari's branch, while `2.50` stopped in March.

Distance from `main` cannot be answered from this clone: `main` is fetched as a
single commit, so its history is not here. The relationship is the usual one -
the 2.54 branch is cut from main and receives security and stability picks,
while main is where new work lands.

## What that delta actually is

Two thirds of it is not port-specific logic:

- **JavaScriptCore, +15k.** The ARMv7 JIT, which upstream deleted. This is
  restored code rather than new code, and it moves only when upstream changes the
  JIT's interfaces.
- **WebKitLegacy, +5.3k across 389 files.** The WebKit1 API, which upstream keeps
  but no longer builds for iOS. Mostly reinstatement and build plumbing.
- **bmalloc, 50 new files.** The allocator's iOS 6 variant, self-contained.

The part that has to be understood on every update is the rest: the changes that
adapt current WebKit to a 2012 system.

## Why a re-graft is realistic

Of the 1298 files changed under `Source`, **367 carry the `WEBKIT_IOS6` guard**
and announce themselves - 1014 occurrences of it in the tree. Those hunks say
what they are and where they belong, and they can be replayed onto a newer tree
by matching the guard rather than by matching context lines.

**931 do not**, and they are where the cost is. By area:

```
Source/WebKitLegacy   374
Source/WebCore        328
Source/JavaScriptCore 111
Source/bmalloc         56
```

The WebKitLegacy and bmalloc ones are wholesale reinstatement, so they move as
files rather than as hunks. The WebCore and JavaScriptCore ones - some 440 files -
are the real work of an update.

## The procedure this argues for

1. Run `scripts/port-delta.sh` against the current base and keep the output. It
   is the before picture, and the after picture has to be explainable.
2. Fetch the new upstream branch and diff it against the current base to see
   which of the 440 unguarded WebCore/JSC files upstream also touched. Only those
   need reading; the rest carry over.
3. Take the new tree, apply the reinstatement wholesale (WebKitLegacy, bmalloc,
   the JIT), then the guarded hunks, then the read set from step 2 by hand.
4. Build, then run `tests/device/run.sh`. The suite is the acceptance test: it
   is numeric, it runs on the device, and it stands at 24 of 24 today.
5. Anything the suite does not cover that the update touches gets a check added
   to it first, not after.

## What makes this cheaper next time

Every unguarded change that could carry a guard should get one. The guard is not
decoration: it is what lets the next graft find the change without reading the
file. That is worth doing incrementally, in the areas an update will have to
read anyway - `Source/WebCore/platform/graphics`, `Source/WebCore/loader`, and
the JIT's platform layer.
