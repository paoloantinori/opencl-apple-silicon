# Contributing

## The upstream patches

All three clspv bugs this project found are fixed in clspv main: #1662 merged on 2026-10-15, #1663 on 2026-10-19, and the GEP truncation landed on 2026-10-14 as #1666 (the reviewer's GCD approach, which superseded our #1660 during review). The patches in `tools/patches/clspv/` remain in the build only because clvk's submodule pins a clspv revision (`7ee3a40e`) that predates the merges; they apply against that pin. Once clvk's pin moves past 2026-10-19, drop both.

On the clvk side, #908 (device name override) merged upstream on 2026-10-09 and is part of the pinned build revision, while #907 (shell quoting, reviewer LGTM) is carried as `tools/patches/clvk/0001-shell-quote-build-options.patch` until it merges.

### Superseded: google/clspv#1660

`SimplifyPointerBitcastPass::runOnGEPFromGEP` merges two constant GEPs by adding their offsets in bits and dividing by the element width. When the sum is not evenly divisible (an 84-byte struct field over a 16-byte array member gives 800/128 = 6.25), the integer division truncated, the rebuilt GEP pointed into the wrong array element, and the type walk aborted the compiler. Our PR skipped the simplification when the division would truncate. During review the maintainer observed that dividing by the GCD of the two element widths instead always represents the merged offset, opened #1666 with that fix, and we verified the GCD end to end on the hashcat workload before #1660 was closed in its favor. The patch carried here is the guard version, which applies against the pinned clspv revision; either form fixes the crash.

**What breaks if it regresses**: every hashcat mode, and any OpenCL kernel that takes the address of a struct member whose size is not a multiple of the pointee size. The compiler crashes with `Err: SrcTy ... CstVal = <offset>`, so the failure is loud, not silent.

### google/clspv#1662: switch table rehome to module-scope private

The optimizer creates `switch.table.*` globals in the Global address space with constant initializers. The producer emitted them as StorageBuffer `OpVariable`s with their initializers attached, violating three Vulkan validation rules: StorageBuffer variables must be struct-typed, initializers are not allowed in that storage class, and SPIR-V 1.4+ requires them to be listed as entry point interfaces.

**What breaks if it regresses**: any kernel compiled at `-O2` or above whose source contains a dense enough switch statement (the optimizer turns it into a lookup table). The module fails `spirv-val` with three errors; hashcat kernels hit it on every mode.

### Superseded: google/clspv#1661

An earlier attempt at fixing the array-type-id duplication that fix #1662 makes moot. With the switch tables rehomed to Private, the initializer and its variable land in the same layout variant and the mismatch does not arise. The dedup also regressed a separate validation case (ArrayStride leaking onto a Workgroup variable). Closed on 2026-10-11 after the type identity test moved into #1662.

## Testing

Both PRs carry end-to-end OpenCL C regression tests in clspv's `test/` directory. If you modify the patches, verify both directions: the test input must fail on unpatched main and pass with the patch applied.

## Style

Short comments that state the constraint the code cannot express. Multi-paragraph block comments explaining what a patch does belong in the PR description or the commit message, not in the source. This is the clspv maintainers' stated preference and this project follows it.
