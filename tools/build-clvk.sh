#!/bin/bash
# build-clvk.sh: build clvk from source with the two clspv patches applied
#
# Clones kpet/clvk at the tested revision, applies the clspv patches from
# tools/patches/ (the two upstream PRs), and builds the OpenCL library.
# The build takes about 45 minutes on 6 vCPUs (LLVM is the long pole).
#
# Prerequisites: cmake, ninja, python3, a C++ compiler, Vulkan headers.
#
# Usage: tools/build-clvk.sh [--workdir DIR] [--jobs N]
#   --workdir DIR  where to clone and build (default: a temp dir)
#   --jobs N       parallel build jobs (default: 2, safe on 8 GiB VMs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)
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

CLVK_REF="36a882756a08891fbf767a909063a0a3afe8355b"

echo "==> Cloning clvk at $CLVK_REF ..."
rm -rf "$WORKDIR"
git clone https://github.com/kpet/clvk.git "$WORKDIR"
cd "$WORKDIR"
git checkout "$CLVK_REF"
git submodule update --init --recursive
cd external/clspv
./utils/fetch_sources.py --deps llvm SPIRV-Headers SPIRV-Tools

echo "==> Applying clspv patches..."
for p in "$PATCHES"/*.patch; do
    echo "    $(basename "$p")"
    patch -p1 --fuzz=3 < "$p"
done

echo "==> Building (this takes about 45 minutes) ..."
cd "$WORKDIR"
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release .
ninja -C build -j "$JOBS"

echo "==> Done: $WORKDIR/build/libOpenCL.so"
echo "Use with: LD_PRELOAD=$WORKDIR/build/libOpenCL.so PATH=$WORKDIR/build:\$PATH <app>"
