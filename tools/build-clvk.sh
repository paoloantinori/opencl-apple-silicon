#!/bin/bash
# build-clvk.sh: build clvk from source with the local patch set applied
#
# Clones kpet/clvk at the tested revision (which already contains the merged
# kpet/clvk#908), applies the clspv patches in tools/patches/clspv/ (the two
# open upstream PRs) and the clvk patches in tools/patches/clvk/ (the open
# #907 plus the measurement-only NULL-arg shim), and builds the OpenCL
# library. The build takes about 45 minutes on 6 vCPUs (LLVM is the pole).
#
# Prerequisites: cmake, ninja, python3, a C++ compiler, Vulkan headers.
#
# Usage: tools/build-clvk.sh [--workdir DIR] [--jobs N]
#   --workdir DIR  where to clone and build (default: a temp dir)
#   --jobs N       parallel build jobs (default: 2, safe on 8 GiB VMs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES="$SCRIPT_DIR/patches"
WORKDIR="${TMPDIR:-/tmp}/clvk-build"
JOBS=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir) WORKDIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

CLVK_REF="8bd3672174764dce25ba220773e10baa752f0373"

echo "==> Cloning clvk at $CLVK_REF ..."
rm -rf "$WORKDIR"
git clone https://github.com/kpet/clvk.git "$WORKDIR"
cd "$WORKDIR"
git checkout "$CLVK_REF"
git submodule update --init --recursive
cd external/clspv
./utils/fetch_sources.py --deps llvm SPIRV-Headers SPIRV-Tools

echo "==> Applying clspv patches..."
for p in "$PATCHES"/clspv/*.patch; do
    echo "    $(basename "$p")"
    patch -d "$WORKDIR/external/clspv" -p1 --fuzz=3 < "$p"
done

echo "==> Applying clvk patches..."
# 0001 is kpet/clvk#907 (still open upstream at the time of writing);
# 0002 is the local measurement-only shim, never meant for upstream.
for p in "$PATCHES"/clvk/*.patch; do
    echo "    $(basename "$p")"
    patch -d "$WORKDIR" -p1 --fuzz=3 < "$p"
done

echo "==> Building (this takes about 45 minutes) ..."
cd "$WORKDIR"
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release .
ninja -C build -j "$JOBS"

echo "==> Done: $WORKDIR/build/libOpenCL.so"
echo "Use with: LD_PRELOAD=$WORKDIR/build/libOpenCL.so PATH=$WORKDIR/build:\$PATH <app>"
