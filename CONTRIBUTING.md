# Contributing

## The upstream patches

This project currently depends on two unmerged clspv PRs. Until they land, the patches in `tools/patches/` must be applied to build a working clvk. Once both merge, the patches become unnecessary.

### google/clspv#1660: GEP offset truncation guard

`SimplifyPointerBitcastPass::runOnGEPFromGEP` merges two constant GEPs by adding their offsets in bits and dividing by the smaller element width. When the sum is not evenly divisible (an 84-byte struct field over a 16-byte array member gives 800/128 = 6.25), the integer division truncates, the rebuilt GEP points into the wrong array element, and the type walk aborts the compiler.

**What breaks if it regresses**: every hashcat mode, and any OpenCL kernel that takes the address of a struct member whose size is not a multiple of the pointee size. The compiler crashes with `Err: SrcTy ... CstVal = <offset>`, so the failure is loud, not silent.

### google/clspv#1662: switch table rehome to module-scope private

The optimizer creates `switch.table.*` globals in the Global address space with constant initializers. The producer emitted them as StorageBuffer `OpVariable`s with their initializers attached, violating three Vulkan validation rules: StorageBuffer variables must be struct-typed, initializers are not allowed in that storage class, and SPIR-V 1.4+ requires them to be listed as entry point interfaces.

**What breaks if it regresses**: any kernel compiled at `-O2` or above whose source contains a dense enough switch statement (the optimizer turns it into a lookup table). The module fails `spirv-val` with three errors; hashcat kernels hit it on every mode.

### Superseded: google/clspv#1661

An earlier attempt at fixing the array-type-id duplication that fix #1662 makes moot. With the switch tables rehomed to Private, the initializer and its variable land in the same layout variant and the mismatch does not arise. The dedup also regresses a separate validation case (ArrayStride leaking onto a Workgroup variable). Close it once #1662 merges.

## Testing

Both PRs carry end-to-end OpenCL C regression tests in clspv's `test/` directory. If you modify the patches, verify both directions: the test input must fail on unpatched main and pass with the patch applied.

## Style

Short comments that state the constraint the code cannot express. Multi-paragraph block comments explaining what a patch does belong in the PR description or the commit message, not in the source. This is the clspv maintainers' stated preference and this project follows it.
