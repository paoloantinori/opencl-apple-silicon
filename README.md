# OpenCL compute in containers on Apple Silicon

OpenCL tools like hashcat cannot use the Apple GPU from a Linux container today. This project proves they can, with two compiler patches and a runtime override, and measures the result: **95% of native Metal speed**.

## The gap

On a Mac, GPU compute inside a container has one working path: Vulkan workloads via `podman machine --provider libkrun`, which forwards Vulkan calls from the guest through the mesa Venus driver, over virtio-gpu, to MoltenVK, to Metal. Applications with a Vulkan backend (llama.cpp and friends) run this way today.

OpenCL has no such path. The guest has no OpenCL driver, and clvk, the conformant OpenCL 3.0 implementation on Vulkan, cannot compile real-world OpenCL kernels because clspv, its compiler backend, has bugs that only surface on complex code. hashcat, probably the most widely used OpenCL application, exercises exactly those bugs.

This project found and fixed three of them, measured the result, and publishes everything needed to reproduce it.

## The result

| Leg | Backend | hashcat -b -m 22000 median | Fraction of native |
|---|---|---|---|
| Native macOS | Metal, Apple M3 Pro | 187.5 kH/s | 100% |
| Container GPU | clvk on venus, in-container hashcat | 178.2 kH/s | 95.0% |
| Container CPU | pocl-CPU inside the libkrun VM | 8.35 kH/s | 4.5% |

The container GPU leg also cracks real hashes: the hashcat test suite example (WPA-PMKID, password "hashcat!") recovers with `Status: Cracked, Recovered: 1/1`.

The chain, end to end:

```
hashcat (OpenCL) -> clvk (OpenCL 3.0 on Vulkan) -> mesa venus (Vulkan serialization)
  -> virtio-gpu (virtio transport) -> krunkit/libkrun 1.19.6 (VM) -> virglrenderer (venus protocol)
  -> MoltenVK (Vulkan to Metal translation) -> Metal -> Apple GPU
```

## What was broken and how it was fixed

Three bugs in clspv, all found by feeding it a hashcat kernel, all with reproducer and patch:

1. **GEP offset truncation** ([google/clspv#1660](https://github.com/google/clspv/pull/1660)). `SimplifyPointerBitcastPass` merges two constant GEPs by adding their offsets in bits and dividing by the smaller element width. When a struct field is 84 bytes and the GEP element is 16 bytes, the sum is 800 bits over 128, which truncates 6.25 to 6 and moves the access into the wrong array. The fix skips the simplification when the division would truncate. Every hashcat mode hits this; the compiler aborts.

2. **Switch lookup tables emitted as storage buffers** ([google/clspv#1662](https://github.com/google/clspv/pull/1662)). The optimizer's switch-to-lookup-table conversion creates `switch.table.*` globals in the Global address space with constant initializers. The OpenCL frontend forbids initialized program-scope variables outside the constant address space, so these are always compiler artifacts. The producer emitted them as StorageBuffer variables with their initializers attached, which violates three Vulkan rules at once (type must be a struct, initializer not allowed in that storage class, SPIR-V 1.4+ requires interface listing). The fix rehomes them to module-scope Private variables.

3. **Invalid logical-to-physical pointer bitcast** ([google/clspv#1663](https://github.com/google/clspv/pull/1663)). Under `-physical-storage-buffers`, the producer reconciles pointer type mismatches by emitting an `OpBitcast` whose operand is a logical pointer, which SPIR-V forbids. The fix tracks the storage class of each registered pointer type and keeps the value's own pointer when it is logical. This only surfaces once fix 2 is applied, because the rehomed tables are what carry the mismatch.

Two smaller fixes went to clvk:

- **Shell quoting of compiler options** ([kpet/clvk#907](https://github.com/kpet/clvk/pull/907)). The clspv command line runs through `popen(3)`, so OpenCL build options with parentheses or dollar signs (hashcat passes `-D XM2S(x)=#x`) break the shell. The fix shell-quotes every token.

- **Device name override** ([kpet/clvk#908](https://github.com/kpet/clvk/pull/908)). hashcat uses monolithic program builds for devices named "Apple M*", but a venus guest device reports `Virtio-GPU Venus (Apple M3 Pro)` which does not match. An opt-in `CLVK_DEVICE_NAME` config lets the reported name start with "Apple M" while the device-properties dispatch keeps the real hardware name.

## How to reproduce

### Prerequisites

- Mac with Apple Silicon, macOS 14+
- [podman](https://podman.io) 5.2 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [GitHub CLI](https://cli.github.com) (`gh`)

### Step 1: Build the GPU stack

```bash
tools/setup-gpu-stack.sh
```

Downloads the libkrun tap bottles (krunkit 1.3.2, libkrun 1.19.6, virglrenderer with venus), relocates them into `tools/gpu-stack/`, and re-signs them. No system installation: everything stays in that directory.

### Step 2: Build clvk with the patches

```bash
tools/build-clvk.sh
```

Clones kpet/clvk, applies the two clspv patches from `tools/patches/`, and builds. Takes about 45 minutes (LLVM is the long pole). The output is `libOpenCL.so` plus the patched `clspv` binary.

Once upstream PRs #1660 and #1662 merge, the patches become unnecessary and a plain clvk build suffices.

### Step 3: Run the benchmark

```bash
tools/run-benchmark.sh
```

Creates a podman machine with the libkrun provider, starts it with the GPU stack in PATH, and runs `hashcat -b -m 22000 -D 2` in a container from `quay.io/slopezpa/fedora-vgpu` (which carries the patched mesa the venus driver needs).

### Notes and caveats

- **One VM per host**: podman on macOS allows only one running machine at a time. The script creates a separate machine and uses a sandbox config dir (`XDG_CONFIG_HOME`) so it can coexist with a running default machine.
- **Stock mesa does not work**: the guest needs the patched mesa from the COPR (`slp/mesa-krunkit`) or the prebuilt image above. Stock mesa fails the venus handshake with `vkCreateInstance ERROR_OUT_OF_HOST_MEMORY`.
- **The measurement shim**: hashcat passes NULL for unused buffer arguments, which clvk rejects without physical addressing. The physical addressing path works once patch 3 is applied, but until it merges, a small local patch to clvk's `clSetKernelArg` (bind a 16-byte dummy buffer for NULL) is needed for the benchmark. This is documented in `docs/spike.md` (session 8) and is not part of the upstream patches.
- **virtiofs mounts are broken in the guest**: all four podman machine host-share mounts return `Connection refused`. Work around it by keeping container workloads guest-local and shadowing `/etc/containers` with a tmpfs from `/usr/share/containers`. Reported upstream as [libkrun/libkrun#910](https://github.com/libkrun/libkrun/issues/910).

## Repository layout

```
tools/
  setup-gpu-stack.sh     download and relocate the venus-capable stack
  build-clvk.sh          build clvk with the clspv patches applied
  run-benchmark.sh       bring up the VM and run the hashcat benchmark
  patches/
    0001-gep-merge-offset-guard.patch
    0002-switch-table-rehome.patch
docs/
  spike.md               full spike report (method, findings, sessions)
  evidence.md            verbatim command log for every claim above
LICENSE                  Apache 2.0
CONTRIBUTING.md          how to help, what the upstream PRs fix
```

## License

Apache 2.0. The project depends on clvk (Apache 2.0) and interacts with clspv (Apache 2.0 with LLVM exceptions); using the same license keeps the ecosystem uniform and allows corporate contributions without a separate CLA.
