#!/usr/bin/env bash
# Build U-Boot for the SHIELD TV 2017: the pinned LineageOS U-Boot plus our
# board patches in patches/u-boot/. The source tree is reset to the pinned
# commit first, so every build starts from the same code.
#
# Output: build/u-boot/u-boot-dtb.bin, the image cboot starts as the
# "kernel" of an Android boot image (see scripts/06).
#
# Usage: scripts/05-build-u-boot.sh
source "$(dirname "$0")/lib.sh"
need git make aarch64-linux-gnu-gcc

"$ROOT/scripts/03-fetch-sources.sh" lineage-u-boot
src="$ROOT/vendor/lineage-u-boot"
out="$ROOT/build/u-boot"
make_=(make -C "$src" O="$out" CROSS_COMPILE=aarch64-linux-gnu-)

log "resetting vendor/lineage-u-boot and applying patches/u-boot/"
git -C "$src" -c advice.detachedHead=false checkout -q -f "$(source_commit lineage-u-boot)"
git -C "$src" clean -q -fd
for p in "$ROOT"/patches/u-boot/*.patch; do
  git -C "$src" apply --whitespace=nowarn "$p"
done

log "building"
"${make_[@]}" -s p2894_defconfig
"${make_[@]}" -s -j"$(nproc)" u-boot-dtb.bin 2> "$out/build-warnings.log" ||
  { cat "$out/build-warnings.log" >&2; die "U-Boot build failed"; }
"${make_[@]}" -s u-boot-initial-env

log "built build/u-boot/u-boot-dtb.bin ($(stat -c %s "$out/u-boot-dtb.bin") bytes)"
