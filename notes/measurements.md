# Measurements on the device

iPhone 4S, armv7 Cortex-A9, 512 MB, iOS 6.1.3. Taken through `headless`, which
runs from a shell and needs no SpringBoard. `bench.sh` produces the table.

## Page loads, 2026-08-25

Seconds to load-committed and to load-finished, and peak resident MB.

| site | commit | finish | peak MB | status |
|---|---|---|---|---|
| example.com | 0.15 | 0.49 | 27.7 | ok |
| news.ycombinator.com | 0.07 | 3.20 | 46.7 | ok |
| en.wikipedia.org (article) | 0.47 | 9.12 | 66.5 | ok |
| threads.com | 0.41 | — | 101.1 | feed never stops loading |
| web.telegram.org | 0.05 | 4.11 | — | crashed, since fixed |
| instagram.com | 0.78 | 19.86 | 123.4 | ok |
| m.youtube.com | 0.34 | 5.21 | 73.2 | ok |

## Where the time goes

Three consecutive loads of threads.com, so the second and third have a warm HTTP
cache and a warm TLS session:

    8.86 s    10.94 s    9.50 s

A warm cache does not help. The load is not network-bound.

## JavaScript, on the CLoop interpreter

    loop, 50M iterations   19004 ms     380 ns per iteration, 2.6M ops/s
    regex, 200 passes      13442 ms
    sort, 200k elements     3110 ms
    object churn, 300k      2501 ms
    string build, 200k      1185 ms

This is where the ten seconds are. It is also the number that decides priorities:
a working JIT is worth more than every other optimisation together, which is why
the 2.54 branch port is the main line of work rather than a curiosity.

## Soft-linked constants

140 present, 135 missing, seven frameworks absent entirely. See notes/soft-links.md.

## With the ARMv7 JIT, 2026-08-25

The baseline JIT and the YARR regex JIT are both on. Same device, same harness.

JavaScript, `/tmp/js.html`:

| | CLoop | LLInt only | baseline + YARR JIT |
|---|---|---|---|
| loop, 50M | 19004 ms | 11173 ms | **5472 ms** |
| regex, 200 | 13442 ms | 13351 ms | **1997 ms** |
| sort, 200k | 3110 ms | 2216 ms | **1859 ms** |
| string, 200k | 1185 ms | 1049 ms | **1050 ms** |
| object, 300k | 2501 ms | 2656 ms | 2865 ms |

Regular expressions are 6.7x. The `object` case is the one that got slower, and
it is a garbage-collection knob rather than codegen: turning the JIT on takes the
VM out of mini mode, so the 4 MB `largeHeapSize` in notes/tuning.md no longer
matches the configuration it was chosen for.

Pages, load-committed and load-finished in seconds, peak resident MB:

| site | commit | finish | peak MB |
|---|---|---|---|
| news.ycombinator.com | 0.16 | **1.94** | 49.1 |
| web.telegram.org | 0.27 | 3.65 | 68.0 |
| en.wikipedia.org | 0.39 | 4.06 | 81.4 |
| m.youtube.com | 0.33 | 5.81 | 146.4 |
| instagram.com | 0.42 | 13.32 | 143.9 |
| threads.com | 0.79 | 15.24 | 154.1 |

Hacker News was 3.6 s before any of this. Nothing crashes any more.

## The memory ceiling is now the binding constraint

threads.com peaks at 154 MB and instagram at 144 MB, against a jetsam limit of
about 122 MB. `headless` runs as root and raises its own limit, so it survives;
an application launched by SpringBoard runs as `mobile` and cannot.

Two things were measured rather than assumed:

- `memorystatus_control` **can** be used by a root process to raise *another*
  process's high-water mark. `tools/raise-memory-limit.c` does it and it works —
  the earlier conclusion that this was impossible was wrong, and was drawn from
  an experiment where the entitlement had been stripped by a stray re-sign.
- Forcing the VM back into mini mode does **not** get the memory back:
  135.3 MB against 136.9 MB with it on, and 2.5 s slower. So this is page
  memory, not a GC setting.
