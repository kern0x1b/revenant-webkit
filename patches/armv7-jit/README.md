# Restoring the ARMv7 JIT

Two upstream commits stand between current trunk and a JIT for this device.
Both patches here are the upstream changes as they landed; applying them in
reverse puts the JIT back.

| Commit | Date | Effect | Size |
|---|---|---|---|
| `653075383222` | 2026-03-13 | `[ARMv7] Disable JIT` — *"no longer working after recent breakage, disabling to keep EWS green"* | 9 files, +19 / -51 |
| `857bd4334690` | 2026-08-01 | `[armv7] Remove ARMv7 JIT support` — *"ARMv7 runs on CLoop now"* | 187 files, +455 / -16789 |

Most of the second commit deletes whole files, which come back cleanly:

    Source/JavaScriptCore/assembler/MacroAssemblerARMv7.h / .cpp
    Source/JavaScriptCore/assembler/ARMv7Registers.h
    Source/JavaScriptCore/dfg/DFGSpeculativeJIT32_64.cpp
    Source/JavaScriptCore/jit/JITOpcodes32_64.cpp
    Source/JavaScriptCore/jit/CallFrameShuffler32_64.cpp
    Source/JavaScriptCore/offlineasm/arm.rb

Reverting restores the code **and the breakage that caused it to be disabled**.
The March commit points at where that breakage lives: `Repatch.cpp`
(`linkPolymorphicCall`, `tryCacheArrayGetByVal` / `PutByVal` / `InByVal`) and
`DFGJITCompiler.cpp` (`link`, `addPropertyInlineCache`) — that is, polymorphic
call linking and property inline caches.

Both of those are DFG and inline-cache territory, so the cheap experiment is to
revert both patches, then build with the baseline JIT only and the DFG off. If
the breakage is confined to the optimising tier, that sidesteps it entirely and
still buys most of the speedup over the interpreter.

The JIT also needs executable memory. The device is jailbroken and does not
enforce code signing, so `PROT_EXEC` mappings should be available — untested.

Carrying this is a permanent ~17k-line fork, re-applied on every WebKit update.
