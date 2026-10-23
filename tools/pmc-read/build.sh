#!/usr/bin/env bash
# Build tools/pmc-read against the current kernel build (scripts/11), into
# build/pmc-read/pmc-read.ko. It loads only into that kernel.
source "$(dirname "$0")/../../scripts/lib.sh"
need make aarch64-linux-gnu-gcc

kbuild="$ROOT/build/linux"
[[ -f $kbuild/Module.symvers ]] || die "build the kernel first: scripts/11-build-kernel.sh"
mkdir -p "$ROOT/build/pmc-read"
make -s -C "$ROOT/vendor/linux" O="$kbuild" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  M="$ROOT/tools/pmc-read" MO="$ROOT/build/pmc-read" modules
log "built build/pmc-read/pmc-read.ko for $(cat "$kbuild/include/config/kernel.release")"
