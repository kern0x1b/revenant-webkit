# ARMv7Assembler.h: 2017 → trunk API deltas

Notes taken while porting `webkit-603/.../ARMv7Assembler.h` (2017 vintage) onto current
trunk in `webkit-trunk-jit`. Superseded for now — `webkitglib/2.54` still ships a working
ARMv7 JIT, so we take that branch instead of writing an encoder. Keep this only in case a
future branch drops ARMv7 as well.

The port did reach the point of compiling: `MacroAssembler.h` (which pulls in both
`ARMv7Assembler.h` and `MacroAssemblerARMv7.h`) built clean for armv7 with zero errors and
zero warnings, as did `MacroAssemblerARMv7.cpp`, `AbstractMacroAssembler.cpp`,
`MacroAssembler.cpp`, `ProbeContext.cpp` and `ProbeStack.cpp`. The file is on branch
`ios6-armv7-jit` if it is ever wanted as a reference.

## Where the contract lives

The authority is not the old assembler — it is what `LinkBuffer.cpp`
(`copyCompactAndLinkCode`), `AbstractMacroAssembler.h` (`Jump::link`, `Call::linkThunk`,
`repatchNearCall`, `flushNearCall`) and the ported `MacroAssemblerARMv7.h` actually call.
`ARM64Assembler.h` in the same tree is the living example to copy shape from. Compiling
`MacroAssembler.h` on its own is a fast, complete check of the whole interface.

## 1. `AssemblerLabel::m_offset` is private

Every `label.m_offset` becomes `label.offset()`. Construction is
`explicit AssemblerLabel(uint32_t)`. Affects `getRelocatedAddress`,
`getDifferenceBetweenLabels`, `getCallReturnOffset`, `linkJump`, `linkCall`,
`linkPointer`, `labelForWatchpoint`, `label`.

## 2. `performJITMemcpy` is templated on a repatching mode

`AssemblerCommon.h` defines `RepatchingFlag { Atomic, Memcpy, Flush }`,
`using RepatchingInfo = WTF::ConstexprOptionSet<RepatchingFlag>`, and the constants
`jitMemcpyRepatch`, `jitMemcpyRepatchAtomic`, `jitMemcpyRepatchFlush`, `memcpyRepatch`,
`memcpyRepatchFlush`, plus `noFlush(RepatchingInfo)`.

Plain `performJITMemcpy(dst, src, n)` is replaced by
`machineCodeCopy<repatch>(dst, src, n)`. This matters for correctness, not just typing:
`LinkBuffer` calls `link<memcpyRepatch>` when writing into a scratch buffer and
`link<jitMemcpyRepatch>` when writing straight into the JIT region. So **every** static
link/patch helper has to become `template<RepatchingInfo repatch>` and thread it through:
`linkJumpT1/T2/T3/T4`, `linkConditionalJumpT4`, `linkBX`, `linkConditionalBX`,
`linkJumpAbsolute`, `setInt32`, `setPointer`.

The `bool flush` trailing parameter of `setInt32`/`setPointer` disappears; the flush is
driven by the flag instead:

    machineCodeCopy<noFlush(repatch)>(...);
    if constexpr ((*repatch).contains(RepatchingFlag::Flush))
        cacheFlush(...);

Public entry points that are also called untemplated take a default:
`template<RepatchingInfo repatch = jitMemcpyRepatchFlush>`.

## 3. `fillNops` is templated, and loses its bool

Old: `fillNops(void*, size_t, bool isCopyingToExecutableMemory)`.
New: `template<RepatchingInfo repatch> static void fillNops(void* base, size_t size)`,
with `static_assert(!(*repatch).contains(RepatchingFlag::Flush))`. `LinkBuffer` calls
both `Assembler::fillNops<memcpyRepatch>` and `<jitMemcpyRepatch>`.

## 4. `LinkRecord` grew three members

`LinkBuffer::copyCompactAndLinkCode` now calls, generically:

- `linkRecord.to(&macroAssembler.m_assembler)` — takes the assembler pointer
- `linkRecord.setFrom(&macroAssembler.m_assembler, writePtr)` — likewise
- `linkRecord.isThunk()`

The assembler argument exists only so ARM64E can diversify a signed `m_to` by the
assembler's address. On ARMv7 both just ignore it (`UNUSED_PARAM`-style). `isThunk()` can
be `static constexpr bool isThunk() { return false; }` — jump islands are ARM64-only, and
`Jump::linkThunk` / `Call::linkThunk` only call `m_assembler.linkJumpThunk` under
`#if CPU(ARM64)`; every other CPU goes through `masm->addLinkTask(...)`. So ARMv7 needs
**no** `linkJumpThunk` / `linkNearCallThunk`.

Also: define both a copy constructor and `operator=` (returning `LinkRecord&`), or clang
warns `-Wdeprecated-copy-with-user-provided-copy` when `std::sort` moves records.

## 5. Near calls are now real `BL`, and tail calls real `B`

This is the biggest behavioural change and the easiest thing to get wrong. The ported
`MacroAssemblerARMv7::linkCall` dispatches three ways:

    if (!call.isFlagSet(Call::Near))
        Assembler::linkPointer(code, call.m_label.labelAtOffset(-2), fn);  // far: MOV/MOVT + BLX
    else if (call.isFlagSet(Call::Tail))
        Assembler::linkTailCall(code, call.m_label, fn);                   // near tail: B (T4)
    else
        Assembler::linkCall(code, call.m_label, fn);                       // near: BL

Consequences:

- `bl()` must exist as an emitter and `linkCall` must relocate a **BL immediate**, not
  patch a MOV/MOVT pointer the way the 2017 `linkCall` did.
- `linkTailCall(void*, AssemblerLabel, void*)` is new and has no ARM64 counterpart to copy.
  It is just `linkJumpT4`, since `nearJumpRange` is 16 MB, comfortably inside B T4 range.
- `AbstractMacroAssembler::repatchNearCall` calls
  `AssemblerType::template relinkCall<repatch>` and `relinkTailCall<repatch>`, while
  `MacroAssemblerARMv7::repatchCall(CodeLocationCall, …)` calls plain `relinkCall(a, b)`
  for the **far** form. One name, two instruction shapes. A default template argument makes
  both call sites compile, but the body has to tell them apart at runtime. The reliable
  discriminator: `from` is always the return address, so look at `from[-1]` — a far call
  ends in `BLX <reg>` (`0x4780 | (Rm << 3)`, mask `0xff87`), whereas the last halfword of a
  `BL` is `>= 0xD000`. No overlap.
- `flushNearCall` wants `flushCall` / `flushTailCall`; `repatchJump` wants `relinkJump`.
  `prepareForAtomicRelinkJumpConcurrently` / `…CallConcurrently` are behind
  `ENABLE(JUMP_ISLANDS)` and are not needed.

## 6. Registers moved out of the assembler header

`ARMv7Registers.h` (which upstream kept, and which comes back cleanly from the removal
patch) owns `FOR_EACH_GP_REGISTER`, `FOR_EACH_REGISTER_ALIAS`, `FOR_EACH_SP_REGISTER`,
`FOR_EACH_FP_SINGLE_REGISTER`, `FOR_EACH_FP_DOUBLE_REGISTER`, `FOR_EACH_FP_QUAD_REGISTER`.
The 2017 header's hand-written `FOR_EACH_CPU_*` macros and enums must be deleted and the
enums generated from those macros instead, exactly as `ARM64Assembler.h` does, inside
`namespace RegisterNames` (`ARMv7Registers.h` does `#define RegisterNames ARMRegisters`).

Required because `RegisterInfo.h`, `RegisterSet.cpp` and `ProbeContext.h` consume the same
macros. `ProbeContext.h` additionally needs `gprName` / `sprName` / `fprName` returning
`ASCIILiteral`, and therefore a real `SPRegisterID` enum (`apsr`, `fpscr`) plus
`firstSPRegister()` / `lastSPRegister()` / `numberOfSPRegisters()` — none of which the
2017 file had.

Two more register-level gaps the ported `MacroAssemblerARMv7.h` depends on:
`ARMRegisters::asSingleUpper(FPDoubleRegisterID)` (the high half of a double as a single,
i.e. `(reg << 1) + 1`), and — because `CPU(ARM_NEON)` is on for armv7 iOS — a
`FPDoubleRegisterID` enum running to `d31`, so `lastFPRegister()` has to be conditional.

Note that the enums are now `enum : int8_t`, which makes `op | reg` an enum-enum operation
and trips `-Wdeprecated-enum-enum-conversion` in the instruction formatter. Cast the
register to `int` at those three sites.

## 7. Smaller renames

- `UNLIKELY(x)` is gone → `if (x) [[unlikely]]`.
- `bitwise_cast` → `std::bit_cast`.
- `COMPILE_ASSERT` → `static_assert`.
- `WTF::bitCount` → `std::popcount` (needs `<bit>`).
- `cacheFlush` on Darwin: `sys_icache_invalidate(code, size)` (per `ARM64Assembler.h`),
  not the 2017 `sys_cache_control(kCacheFunctionPrepareForExecution, …)`. Needs
  `<libkern/OSCacheControl.h>`.
- Include style is `<JavaScriptCore/Foo.h>`, not `"Foo.h"`.
- `buffer()` accessor is required (`LinkBuffer` calls
  `m_assembler.buffer().releaseAssemblerData()`); mark it `LIFETIME_BOUND`, as should
  `jumpsToLink()`.
- `replaceWithNops(void*, size_t)` is new (non-templated), and `invert(Condition)` and
  `isBkpt(const void*)` are called by `MacroAssemblerARMv7.h` but absent from 2017.
- `ENABLE(BRANCH_COMPACTION)` is on, so the `copyCompactAndLinkCode<uint16_t>` path — and
  hence `canCompact` / `computeJumpType` / `jumpSizeDelta` / `link` — is live.

## 8. Instruction-set gap, if this is ever redone

A static comparison of what `MacroAssemblerARMv7` calls against what the 2017 file provides
found ~33 missing `m_assembler.X()` emitters. Beyond the obvious ones, three are easy to
miss because the name exists but the needed overload does not:

- `adc(rd, rn, rm)` — 2017 has only the immediate form; the register form (`0xEB40`) is
  needed for `add64`.
- `ldrsb` / `ldrsh` with an `ARMThumbImmediate` or an `(offset, index, wback)` triple —
  2017 has only the register-offset forms.
- the whole single-precision family (`vadd`, `vsub`, `vmul`, `vdiv`, `vsqrt`, `vabs`,
  `vneg`, `vcmp`, `vcmpz`, and the `vcvt` float-source variants), which is the same
  encoding with the `sz` bit clear.

Two encodings needed genuinely new machinery rather than a new opcode constant:

- `vand` / `vorr` are **Advanced SIMD**, not VFP — VFP has no bitwise ops. They need their
  own formatter, because the existing `vfpOp` puts `size` at bit 8 of the second halfword,
  which for SIMD three-registers-same-length is part of the opcode. The D/N/M register
  extension bits also attach to Vd/Vn/Vm respectively, unlike `vfpOp`'s layout.
- `vldmia` / `vstmia` need a load/store-multiple formatter (`imm8` is *twice* the number of
  doubleword registers).

And one trap worth writing down: `LDREX` and `LDRD (immediate)` share the first-halfword
base `0xE850`. They are distinguished by P:W — `P == 0 && W == 0` is the exclusive-access
encoding space, so `ldrd` must assert `index || wback`.

## 9. One bug found in the ported MacroAssembler (not fixed here)

`MacroAssemblerARMv7.h`, in `absoluteAddressWithinShortOffset`:

    return reinterpret_cast<int32_t>(addressDelta);   // addressDelta is intptr_t

`reinterpret_cast` between two integer types is ill-formed; it must be `static_cast`. This
was the only error left in the whole assembler directory once the encoder was in place.
Whoever owns `MacroAssemblerARMv7.h` should make that change — it is presumably present in
the `webkitglib/2.54` copy too, or was introduced when the file was extracted from the
removal patch, and is worth checking either way.
