#!/usr/bin/env bash
# Build a kernel module in tools/<name> against the current kernel build
# (scripts/11), into build/<name>/<name>.ko. It loads only into that kernel.
#
# Usage: tools/build-module.sh <name>     (pmc-read, gpu-power-probe)
source "$(dirname "$0")/../scripts/lib.sh"
need make aarch64-linux-gnu-gcc

name=${1:-}
[[ -n $name && -f $ROOT/tools/$name/Kbuild ]] || die "usage: $0 <a module directory in tools/>"
kbuild="$ROOT/build/linux"
[[ -f $kbuild/Module.symvers ]] || die "build the kernel first: scripts/11-build-kernel.sh"
mkdir -p "$ROOT/build/$name"
make -s -C "$ROOT/vendor/linux" O="$kbuild" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  M="$ROOT/tools/$name" MO="$ROOT/build/$name" modules
log "built build/$name/$name.ko for $(cat "$kbuild/include/config/kernel.release")"
