#!/bin/bash
# setup-gpu-stack.sh: build the venus-capable krunkit stack into tools/gpu-stack/
#
# Downloads the libkrun homebrew tap bottles for arm64, relocates them into
# a local prefix (no system installation), rewrites install names, and
# re-signs ad hoc with the hypervisor entitlement.
#
# Prerequisites: macOS on Apple Silicon, Xcode Command Line Tools (for
# codesign and install_name_tool), gh (for the GitHub release download).
#
# Usage: tools/setup-gpu-stack.sh [--prefix DIR]
#   --prefix DIR  output directory (default: tools/gpu-stack next to this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${2:-$SCRIPT_DIR/gpu-stack}"

echo "==> Downloading libkrun tap bottles..."
mkdir -p "$PREFIX"
cd "$PREFIX"
for spec in "krunkit-1.3.2" "libkrun-1.19.6" "libkrunfw-5.6.2" "virglrenderer-krun-0.10.4e"; do
    tag="${spec%-*}"
    gh release download "$tag" --repo libkrun/homebrew-krun \
        --pattern "*arm64_tahoe*" --clobber 2>/dev/null \
        || echo "    (bottle for $tag may already be present)"
done
gh fetch --bottle-tag=arm64_tahoe libepoxy molten-vk 2>/dev/null || true

for f in *arm64_tahoe.bottle.tar.gz \
         ~/Library/Caches/Homebrew/downloads/*--libepoxy--*.tar.gz \
         ~/Library/Caches/Homebrew/downloads/*--molten-vk--*.tar.gz; do
    [ -f "$f" ] && tar xzf "$f" 2>/dev/null
done

echo "==> Assembling local prefix..."
mkdir -p bin lib share/krunkit
cp -f krunkit/*/bin/krunkit bin/krunkit
cp -f krunkit/*/share/krunkit/KRUN_EFI.silent.fd share/krunkit/
for dir in libkrun libkrunfw virglrenderer-krun libepoxy molten-vk; do
    find "$dir" -name "*.dylib" -exec cp -f {} lib/ \; 2>/dev/null
done

echo "==> Rewriting install names..."
rewrite() {
    local file="$1"
    otool -L "$file" | awk '{print $1}' | grep '^@@HOMEBREW_PREFIX@@' | sort -u | \
    while read -r ph; do
        install_name_tool -change "$ph" "$PREFIX/lib/$(basename "$ph")" "$file"
    done
    local id
    id="$(otool -D "$file" | tail -1)"
    if [[ "$id" == @@HOMEBREW_PREFIX@@* ]]; then
        install_name_tool -id "$PREFIX/lib/$(basename "$id")" "$file"
    fi
}
for f in lib/*.dylib; do rewrite "$f"; done
rewrite bin/krunkit

echo "==> Re-signing ad hoc..."
codesign -d --entitlements :- bin/krunkit > krunkit.entitlements.plist 2>/dev/null || true
for f in lib/*.dylib; do codesign -f -s - "$f" >/dev/null 2>&1; done
codesign -f -s - --entitlements krunkit.entitlements.plist bin/krunkit

echo "==> Verifying..."
./bin/krunkit --version
echo "GPU stack ready in $PREFIX"
echo "Next: export PATH=\"$PREFIX/bin:\$PATH\" before podman machine start"
