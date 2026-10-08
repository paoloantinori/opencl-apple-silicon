# SPIKE: OpenCL compute in a podman libkrun container on Apple Silicon, validated with hashcat 22000

## FINAL VERDICT: GO, at 95% of native Metal

hashcat 22000 runs end to end inside the container on the Apple GPU, and it cracks real hashes: the official example hash (WPA-PMKID, password "hashcat!") recovers with `Status...........: Cracked, Recovered: 1/1 (100.00%)`. Benchmark median 178.2 kH/s over four warm runs (150.8 cold first run, 177.7/178.6/178.2/177.8 warm), against the native Metal baseline of 187.5 kH/s: **95.0% of native Metal**. The chain that achieves it: podman machine (libkrun provider) with the venus-capable krunkit stack (`gpu-stack/`), patched guest mesa (`quay.io/slopezpa/fedora-vgpu`), clvk built from source embedding clspv with two fixes from this spike ([google/clspv#1660](https://github.com/google/clspv/pull/1660), GEP offset truncation, and [google/clspv#1662](https://github.com/google/clspv/pull/1662), rehome of optimizer-generated constant tables), `CLVK_DEVICE_NAME` override so hashcat takes its monolithic-build path, plus a local measurement-only shim in clvk that binds a dummy buffer for NULL buffer arguments (the physical-addressing route that avoids the shim hits a fourth, separate clspv bug, documented below and not fixed).

| Leg | Backend | Median | Range | Fraction of native |
|---|---|---|---|---|
| Native macOS | Metal, Apple M3 Pro (hashcat 7.1.2, -D 2) | 187.5 kH/s | 185.1 to 190.8 | 100% |
| Container GPU | clvk on venus, in-container hashcat 7.1.2 (-D 2) | 178.2 kH/s | 177.7 to 178.6 (warm) | 95.0% |
| Container CPU | pocl-CPU inside the libkrun VM (-D 1) | 8.35 kH/s | 7.58 to 8.41 | 4.5% |

Remaining known issues, all reported upstream: the CL2.0 user `global const` program-scope constant emits an invalid StorageBuffer variable (noted on #1662); the physical-addressing path hits `OpBitcast` with a logical pointer operand on this kernel (documented in evidence, session 8); the NULL-buffer-arg handling in clvk needs an upstream design decision (measured via local shim; upstream prefers physical addressing).

Date: 2026-10-07. Two sessions (session 2 reopened on maintainer request to fix the stack at the open-source layers). Author: agent session on the maintainer's Mac (host `mac`).
Full verbatim command log: [evidence.md](evidence.md). Working scripts: [vm/](vm/), relocated GPU stack: [gpu-stack/](gpu-stack/), clvk tree with patch and repro harnesses: [clvk/](clvk/).

## SESSION 2 VERDICT (supersedes the session-1 NO-GO at every layer below hashcat)

The session-1 NO-GO decomposed into three independent causes, two of them fixed in this session:

1. **The official podman macOS pkg (both the installed 5.7.1 and the current 6.1.3) ships krunkit 1.1.1, which never calls `krun_set_gpu_options2`, so the GPU device is created without the VENUS capset.** Fixed by running the current tap stack (krunkit 1.3.2 + libkrun 1.19.6 + virglrenderer-krun built with `-Dvenus=true` and linked to MoltenVK) relocated into `gpu-stack/` from the libkrun project's homebrew bottles: unpack, `install_name_tool` path fixups, ad-hoc re-sign with the hypervisor entitlement. No system installation; podman picks it up via a PATH override and `podman machine start` then works with its full argument line, `--timesync` included (unsupported in 1.1.1, supported in 1.3.2).
2. **Stock guest mesa cannot speak venus with libkrun.** The working recipes use Sergio López's patched mesa (COPR `slp/mesa-krunkit`); the prebuilt image `quay.io/slopezpa/fedora-vgpu` carries it. With that image: `vulkaninfo --summary` in the container lists `deviceName = Virtio-GPU Venus (Apple M3 Pro), driverName = venus, apiVersion = 1.2.0`. Verified end to end: container, venus, virtio-gpu, libkrun 1.19.6, virglrenderer-krun, MoltenVK, Metal.
3. **clvk works on top of it**: built from source in a container (45 minutes total including one OOM restart at `-j6` on the 8 GiB VM; finished at `-j2`), `clinfo` lists `Device Name: Virtio-GPU Venus (Apple M3 Pro)`, `Device Version: OpenCL 3.0 CLVK on Vulkan v1.2.0`, `Device Type: GPU`. A trivial kernel compiles, links and runs.

**What still fails, precisely, is hashcat 6.2.6 `-b -m 22000 -D 2`: its kernel does not compile under clspv, current main.** Exact error (identical via `clLinkProgram`, via a monolithic `clBuildProgram`, and via the clspv CLI with hashcat's production defines; the kernel compiles with RC=0 only without the defines, which strips the kernel bodies):

```
Err: SrcTy = %struct.md5_hmac_ctx = type { %struct.md5_ctx, %struct.md5_ctx } - DstTy = [4 x i32] - Ty = %struct.md5_hmac_ctx = type { %struct.md5_ctx, %struct.md5_ctx } - CstVal = 96
```

Minimal reproducer: [clvk/hctest.c](clvk/hctest.c) (compile+link with hashcat's exact option string, dumps the build log). All other hashcat modes tried fail the same way, so this is not mode-22000 specific. Workarounds tried and refuted in this session: monolithic-link patch in clvk (the failure is in clspv codegen, not the IR linker), dropping `-long-vector` (same error), LD_PRELOAD interposition (hashcat loads OpenCL via dlopen, not interceptable).

Two additional upstream bugs found on the way, both with evidence in evidence.md: `cvk_exec` builds the clspv command line for `popen` and clvk shell-quotes its own options, but any consumer-supplied option containing parentheses (hashcat's `-D XM2S(x)=#x`) is a shell syntax error waiting to happen; and pkg krunkit 1.1.1 predates the default GPU enablement, which is why the official pkg path can never expose a Vulkan device as shipped.

**Bottom line for the public project:** OpenCL-in-container on Apple Silicon via podman libkrun + clvk is real and working today up to and including `clinfo` and custom kernels; standard hashcat is blocked by one concrete clspv kernel-compilation bug (error and reproducer above), which is the single remaining upstream fix needed for the GO. The benchmark leg (hashcat 22000 on the GPU) could not run, so no GPU throughput number exists yet; the CPU legs from session 1 stand (native Metal 187.5 kH/s median, pocl-in-container 8.35 kH/s median).



## SESSION 7: full re-verification and a retraction (the maintainer caught it)

A maintainer re-check request exposed that the podman issue was wrong, and the error was mine. Re-extracting the 6.1.3 installer payload cleanly shows it bundles **krunkit 1.3.2, libkrun 1.19.0, a venus-enabled virglrenderer and MoltenVK, with timesync support**: the current installer has the entire new stack. And the krunkit v1.1.1 sources already contain the `krun_set_gpu_options2(VENUS | NO_VIRGL)` "Temporarily enable GPU by default" call (libkrun 1.16.0 has the attach path too), so the issue's premise was false at both layers. The symptoms I saw came from this machine's stale 5.7.1 pkg install (December 2025). Worse: I had written that I verified both pkg builds by running `krunkit --version`, but the extracted 6.1.3 binary aborted on run (code signing) and I generalized the 5.7.1 result to both. That was a verification claim that never happened.

Corrections published: full retraction on [podman#29918](https://github.com/podman-container-tools/podman/issues/29918) (asked to close as invalid), correction on [libkrun discussion #908](https://github.com/libkrun/libkrun/discussions/908), correction of the same line in my [clvk#600](https://github.com/kpet/clvk/issues/600) update. All other upstream artifacts re-verified and stand: clvk#906 (root cause arithmetic, verified both directions), clspv#1660/#1661 (repros and review-fix commits), clvk#907/#908 (upstream review addressed), libkrun#910 (virtiofs ECONNREFUSED reproduced on the original pkg stack in session 1, so not an artifact of the relocation), hashcat#4959 (strncmp verified in source).

Impact on the spike story: part of session 1's NO-GO was the stale local pkg. On a host with the current 6.1.3 installer, the GPU chain may work directly from the pkg stack; `gpu-stack/` remains valuable as a reproducible recipe and for stale installs.

## SESSION 6: review gates on every contribution, and PRs everywhere there was something

Two gaps the maintainer called out, both closed:

- **/code-review high now ran on every code contribution.** On google/clspv#1660 it found a real fixpoint-loop risk (the pass reported Changed=true even when the new guard skipped the chain; the fixpoint in run() could spin) and a duplicated guard; both fixed in commit 75675366, with the missing-test gap declared honestly instead of shipping a decorative test (my reduced .ll inputs simplify through other pass branches and would not have failed pre-fix). On the array-type-dedup change it found that sharing the type id was unsafe for aggregate elements (struct members lose layout decorations, nested arrays lose the inner stride); the rework shares ids only for non-struct elements, which the hashcat kernel itself forced: its constant is a nested `[4 x [4 x i32]]`, proving nested arrays must be shareable while structs must not. Final version verified on a host build: the regression test validates with a single shared OpTypeArray, and the full m22000 module loses the initializer-type error.
- **Every project with something from us now has it filed.** The dedup fix is a second upstream PR: [google/clspv#1661](https://github.com/google/clspv/pull/1661) (with regression test). The dead virtiofs shares, previously only documented locally, are now [libkrun/libkrun#910](https://github.com/libkrun/libkrun/issues/910). hashcat's Apple-name prefix check missing virtual GPUs is [hashcat/hashcat#4959](https://github.com/hashcat/hashcat/issues/4959).

Full upstream tally for the spike: libkrun discussion #908 (verification + thanks), libkrun issue #910 (virtiofs), kpet/clvk issues #906 (kernel compile, with root cause) and #600 (hashcat status map), podman issue #29918 (pkg krunkit VENUS), clvk PRs #907 (shell quoting, closes #599) and #908 (device_name), clspv PRs #1660 (GEP offset truncation) and #1661 (array type id sharing). One bug from the spike remains upstream-unfixed and only reported: the StorageBuffer OpVariable initializer / interface listing (documented on #1660).

## SESSION 5: end-to-end validation with the fixed clspv, and the answer to "was any of this known?"

The e2e run rebuilt the whole chain in the container with clspv main plus our two changes:

- With google/clspv#1660 applied, hashcat's kernels compile inside the real clvk build: the `md5_hmac_ctx` crash is gone from the actual application run, not just the CLI.
- Two further clspv bugs then surface in sequence, both pre-existing and previously masked by the crash, both reproduced standalone with `spirv-val`: duplicate `OpTypeArray` ids for the same array type (the layout variants in `SPIRVProducerPass`'s `TypeMap`), and a `StorageBuffer` `OpVariable` carrying a `ConstantComposite` initializer (VUID-StandaloneSpirv-OpVariable-04651) plus an interface variable missing from the entry point. The first has a working prototype fix (archived as `clspv-fix-array-type-dedup-EXPERIMENTAL.patch`, verified to remove the mismatch error); the second is documented but not yet diagnosed.
- Net: hashcat 22000 still does not complete; the remaining distance is two identified emitter bugs in clspv's module-constants path, no longer an unknown.

Contributions published this session (the "was it all known?" answer, see evidence): the offset-truncation bug and its fix were NOT known upstream (no prior issue or PR matched; our google/clspv#1660 is the first report and fix). The two emitter bugs were also unknown, and are now reported with disassembly on #1660. The full status, working recipe and bug map went to the clvk tracking issue for hashcat (https://github.com/kpet/clvk/issues/600), which had been stuck since January 2026. Previously-known pieces: the 2023 clspv hashcat fixes (different bugs), the patched-mesa requirement (podman-desktop docs), and the null-argument env recipe (clvk#600 itself).

## SESSION 4: the clspv bug is fixed (root cause, patch, upstream PR)

The maintainer asked whether the "arch-dependence" could be fixed by us. It could, and it was, at the compiler level:

- clspv built from source on the Mac host (no VM needed: the failure is pure compilation) and the error reproduced identically.
- Backtrace instrumentation identified the failing pass: `SimplifyPointerBitcastPass::runOnGEPFromGEP`. Dumping the GEP pair gave the exact arithmetic: merging `%opad` (672 bits, the md5_ctx field of md5_hmac_ctx) with `%w0` (128 bits, the [4 x i32] field of md5_ctx) computes `(672 + 128) / min(672,128) = 6` by truncation, because 800 is not divisible by 128: the merged offset becomes 96 bytes instead of 100 (opad at 84 plus w0 at 16), and `GetIdxsForTyFromOffset` aborts on the leftover. The 84-byte md5_ctx is why every hashcat version fails, and why stacks that never take this merge path (the x86_64 report in clvk#600) appeared unaffected.
- The fix is a divisibility guard in both merge sites of the pass (skip the simplification instead of truncating): [google/clspv#1660](https://github.com/google/clspv/pull/1660), with a 30-line reproducer that aborts on main and compiles with the fix, and the full preprocessed m22000 kernel (aborts on main, compiles to 1.9 MB of SPIR-V with the fix). Patch archived as `clspv-fix-gep-merge-offset.patch`.
- The same session ran /code-review (high) on the two clvk PRs, whose findings plus the clvk maintainer's review (rjodinchr, same day) were addressed with additive commits on both PRs (#907: quoting moved to utils.cpp with quote-aware splitting, tests, and path quoting; #908: OPTION and a name() switch instead of mutating the Vulkan properties).
- Not yet verified: hashcat running end to end with the fixed clspv inside the container (needs the VM and a clvk rebuild, about an hour); the fix is compiler-level verified in both directions.

## SESSION 3: upstream feedback, issues and PRs, workaround research

Acting on the maintainer's three requests:

1. **Feedback to the authors of the working stack.** The blog (sinrega.org) is static with no comment system, so the thank-you with the end-to-end verification went to the libkrun trackers the blog itself points to: https://github.com/libkrun/libkrun/discussions/908. It credits the patched mesa COPR and the fedora-vgpu image, reports what worked on macOS 26 and M3 Pro, and lists the two pitfalls for the next person.
2. **Issues and PRs (all posts passed the unslop audit):**
   - kpet/clvk#906: the clspv kernel compile failure, full detail and reproducer, plus a follow-up comment with the hashcat 7.1.2 evidence.
   - podman issue https://github.com/podman-container-tools/podman/issues/29918: the macOS pkg bundles krunkit 1.1.1 without the VENUS flag, so GPU containers cannot work from the pkg.
   - kpet/clvk PR #907: POSIX shell-quoting of every compiler option token (closes the older clvk#599). Verified standalone against adversarial tokens.
   - kpet/clvk PR #908: new `device_name` config to override the reported device name; this is what lets applications like hashcat take their Apple Silicon code path on virtual devices.
3. **Workaround research (exhaustive), report in [claudedocs/](claudedocs/research_hashcat-clvk-workarounds_2026-10-07.md).** Headlines, all verified today on the real stack: hashcat 7.1.2's shared kernel compiles and links under clvk, but its m22000 kernel fails with the identical clspv constant-expression error, so the version upgrade does not work around this on aarch64. hashcat's own Apple-name path confirms the error from inside the application. The clvk tracking issue #600 records a January 2026 x86_64 run where the same hashcat version compiled its kernels, which makes the bug look aarch64-specific (struct layout at the failing constant offset). The environment recipe any future successful run needs: `CLVK_SPIRV_ARCH=spir64 CLVK_PHYSICAL_ADDRESSING=1`. No fork, prebuilt package, or alternative OpenCL-on-Vulkan layer exists that changes this picture.

Verdict unchanged by session 3: infrastructure GO, hashcat blocked by the single clspv bug, which now has two issues, two PRs and an arch-dependence lead attached to it upstream.

## Session 1 verdict (blocker was real but fixed in session 2; kept for the record)

**NO-GO, and the break is one step earlier than OpenCL.** No Vulkan device is reachable from containers on this host stack, so the clvk (OpenCL-over-Vulkan) leg never started. Per the spike plan, step 3 rules this: `vulkaninfo --summary` in a container reports no device, with an exact, reproducible error chain (below). hashcat 22000 never reached the GPU inside the container; clvk/clspv kernel compilation was not attempted, by design of the stop rule.

The premise "podman libkrun forwards Vulkan to Metal" did not hold for this installation, and the reasons found are concrete and versionable.

## Environment

| Component | Version |
|---|---|
| Host | Apple M3 Pro, 12 CPU, 36 GB RAM, macOS 26.7.1 (25G241) |
| podman client (brew) | 6.1.3, buildorigin brew, built 2026-09-29 |
| podman pkg install | 5.7.1 at /opt/podman (Dec 2025), bundles krunkit 1.1.1, gvproxy, vfkit, libkrun-efi, libMoltenVK, libvirglrenderer |
| Production VM | podman-machine-default, applehv, RUNNING, untouched (never stopped, configured, or restarted) |
| Spike VM | crack: libkrun provider, 6 vCPU, 8 GiB RAM, 40 GiB disk, machine-os image quay.io/podman/machine-os:6.1 (Fedora CoreOS 44.20260829.3.1, kernel 7.1.10) |

## What the spike actually had to work around

1. **podman on macOS allows only one running machine.** `podman machine start crack` fails while the production machine is up: `Error: unable to start: podman-machine-default already starting or running on the applehv provider: only one VM can be active at a time`. Known standing limitation, open feature request containers/podman#26281. brew has no podman update (stable 6.1.3 is current), so the authorized upgrade path was closed.
2. **Workaround that worked:** the machine listing is rooted at the config home, which honors `XDG_CONFIG_HOME`. A sandbox config dir containing only crack let the official `podman machine start` choreography run (it holds gvproxy and the ignition vsock server) while the production machine stayed up. The krunkit VM process itself was then launched manually with podman's own command line. Scripts: `vm/krunkit-run.sh`.
3. **brew podman 6.1.3 is incompatible with pkg krunkit 1.1.1.** Podman passes `--timesync vsockPort=1234`; krunkit 1.1.1 has no such option and exits with code 2. Removing that one flag lets the VM boot. Client and helper come from different installs on this Mac; whoever owns this machine should align them.
4. **With that flag removed the VM boots and provisions fully:** ignition over vsock worked, SSH worked, `podman` inside the guest worked (after one fix below). Two guest-side defects were found and routed around; both are recorded as findings.

## Findings (each with exact errors in evidence.md)

1. **No Vulkan device in containers (the NO-GO).** Container `/dev/dri/renderD128` exists and the host pkg ships the full GPU stack (`libkrun-efi.dylib`, `libMoltenVK.dylib`, `libvirglrenderer.1.dylib`), but mesa venus fails at instance creation: `vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY`, and the guest kernel shows `virtio_gpu ... *ERROR* response 0x1200 (command 0x208)`, that is VIRTIO_GPU_RSP_ERR_UNSPEC on `VIRTIO_GPU_CMD_CTX_CREATE`. The host renderer refuses every GPU context creation.
2. **Not a guest mesa version skew.** Fedora 41 image (mesa 25.0.7) reproduces the identical failure, so the rejection is on the host side of the virtio-gpu device. Likely suspects: the pkg's krunkit 1.1.1 / libkrun-efi pair (Dec 2025, aligned with podman 5.7.1) against a macOS 26.7 host, or a virtio-gpu variant of this pkg that never supported cross-domain contexts used by venus. A newer podman pkg with a matched krunkit is the obvious retest; installing one was outside this session's authorization.
3. **virtiofs mounts are dead in the VM.** All four virtiofs mounts (`/Users`, `/private`, `/var/folders`, host `~/.config/containers` to guest `/etc/containers`) return `Connection refused` on every read. This breaks the guest podman service (`Failed to obtain podman configuration: open /etc/containers/storage.conf: connection refused`) and all host-volume container mounts. Routed around by shadowing `/etc/containers` with a tmpfs populated from `/usr/share/containers`, and by keeping all container work guest-local (no bind mounts).
4. **krunkit exits 0 when the guest powers off or reboots.** Observed twice as a silent, instant, empty-log exit during first-boot experimentation, and once at 08:36 after a long-lived healthy boot. This makes `podman machine start` fail with `krunkit exited unexpectedly with exit code 0` on any guest-initiated reboot, which is normal CoreOS behavior on first provisioning. Worth knowing for anyone scripting this VM.

## Benchmarks (hashcat -b -m 22000, WPA-PBKDF2, 4095 iterations)

GPU leg in the container: not reached, see verdict. The two reachable legs, 4 runs each, alternating sides, stock hashcat, no tuning beyond defaults:

| Leg | Backend | Median | Range | Limiter |
|---|---|---|---|---|
| Native macOS | Metal, Apple M3 Pro (hashcat 7.1.2, `-D 2`) | 187.5 kH/s | 185.1 to 190.8 kH/s | GPU-bound |
| Container CPU | pocl-CPU inside the libkrun VM (`-D 1`, 6 vCPU) | 8.35 kH/s | 7.58 to 8.41 kH/s | CPU-bound, 6 vCPU of a shared 12-core host (load avg 4.2) |

Native Metal runs about 22x faster than the best reachable in-container leg. If a future retest gets the GPU leg working, the fraction to beat is roughly 4 to 5 percent of native Metal at the CPU ceiling, and the GPU leg would need to be compared against 187.5 kH/s.

## Reusing this setup (until the blockers are fixed)

The working recipe is fully scripted: sandbox config dir via `XDG_CONFIG_HOME=/tmp/<dir>` containing only the crack machine config plus a copy of `podman-connections.json`; `podman --log-level=debug machine start crack` in the background; `vm/krunkit-run.sh` (the podman 6.1.3 arg line minus `--timesync`) once the gvproxy and ignition sockets exist; inside the guest, shadow `/etc/containers` with a tmpfs from `/usr/share/containers`. Then run containers with the guest's own podman over SSH.

## Cleanup record

crack machine removed (`podman machine rm -f crack`), 40 GiB sparse disk and 895 MiB machine-os cache deleted, sandbox config dir and temp logs deleted, crack gvproxy and Terminal wrapper processes killed, runtime sockets removed. Post-cleanup verification: `podman machine list` shows only podman-machine-default (applehv, Currently running), default connection unchanged, no crack processes remain. The working directory with all evidence stays.

## Next steps if this line of work continues

1. Re-run step 3 on a current podman macOS pkg (6.x) so client, krunkit, and libkrun-efi come from one matched release; this alone may flip findings 1 and 3.
2. If venus comes alive, proceed to clvk: prefer a prebuilt aarch64 image; otherwise build kpet/clvk in the container (budget 45+ minutes, LLVM-heavy).
3. hashcat under clspv is the real test after that; capture compiler errors verbatim as first-class findings.
