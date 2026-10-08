#!/bin/bash
# run-benchmark.sh: bring up the GPU container and run hashcat m22000
#
# Prerequisites (see README for full instructions):
#   - podman 5.2+ on the host
#   - tools/gpu-stack populated (setup-gpu-stack.sh)
#   - clvk built with the patches (build-clvk.sh)
#   - a second podman machine will be created if the default is running
#     (podman on macOS only allows one active VM per host)
#
# Usage: tools/run-benchmark.sh [--mode N] [--clvk DIR]
#   --mode N     hash mode (default: 22000, WPA-PBKDF2-PMKID+EAPOL)
#   --clvk DIR   clvk build dir containing libOpenCL.so (default: searched)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd"
MODE=22000
CLVK_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --clvk) CLVK_DIR="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# Locate clvk build
if [ -z "$CLVK_DIR" ]; then
    for d in "$SCRIPT_DIR/../clvk/build" "${TMPDIR:-/tmp}/clvk-build/build"; do
        [ -f "$d/libOpenCL.so" ] && CLVK_DIR="$d" && break
    done
fi
if [ -z "$CLVK_DIR" ] || [ ! -f "$CLVK_DIR/libOpenCL.so" ]; then
    echo "error: no clvk build found; run tools/build-clvk.sh first" >&2
    exit 1
fi

export PATH="$SCRIPT_DIR/gpu-stack/bin:$PATH"

# Check if default machine is running (we need a separate machine if so)
DEFAULT_RUNNING=$(podman machine list --format json 2>/dev/null \
    | python3 -c "import json,sys; ms=json.load(sys.stdin); print(any(m.get('Running') and 'default' in m.get('Name','') for m in ms))" \
    2>/dev/null || echo false)

MACHINE_NAME="gpu-bench"
if [ "$DEFAULT_RUNNING" = "True" ]; then
    echo "==> Default machine is running; creating sandbox config dir for $MACHINE_NAME"
    export XDG_CONFIG_HOME="${TMPDIR:-/tmp}/gpu-bench-xdg"
    mkdir -p "$XDG_CONFIG_HOME/containers/podman/machine"
    cp ~/.config/containers/podman-connections.json "$XDG_CONFIG_HOME/containers/" 2>/dev/null || true
fi

echo "==> Starting machine $MACHINE_NAME ..."
podman machine init --provider libkrun --cpus 6 --memory 8192 "$MACHINE_NAME" 2>/dev/null || true
podman machine start "$MACHINE_NAME"

echo "==> Running hashcat -b -m $MODE -D 2 in container ..."
echo "    (kernel compilation on first run takes several minutes)"
podman --connection "$MACHINE_NAME" run --rm --device /dev/dri \
    -e CLVK_DEVICE_NAME="Apple GPU (venus)" \
    quay.io/slopezpa/fedora-vgpu \
    bash -c "dnf -yq install hashcat >/dev/null 2>&1; hashcat -b -m $MODE -D 2"

echo "==> Done. Machine $MACHINE_NAME left running (podman machine stop $MACHINE_NAME to stop)."
