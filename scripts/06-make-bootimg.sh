#!/usr/bin/env bash
# Wrap U-Boot, and optionally a FIT payload as the ramdisk, in an Android boot
# image that cboot accepts (header fields from config.sh's BOOTIMG_ARGS).
#
# Without a payload U-Boot only reports on the TV what cboot handed over:
# board revision, bootargs, framebuffer and ramdisk. That is the first test
# on an unlocked SHIELD.
#
# Usage: scripts/06-make-bootimg.sh [payload.itb]
#   -> build/boot-uboot.img, or build/boot-uboot-<payload>.img
source "$(dirname "$0")/lib.sh"
need mkbootimg unpack_bootimg

uboot="$ROOT/build/u-boot/u-boot-dtb.bin"
[[ -f $uboot ]] || die "build U-Boot first: scripts/05-build-u-boot.sh"

args=("${BOOTIMG_ARGS[@]}" --cmdline "" --kernel "$uboot")
out="$ROOT/build/boot-uboot.img"
if (($#)); then
  [[ -f $1 ]] || die "no such payload: $1"
  args+=(--ramdisk "$1")
  out="$ROOT/build/boot-uboot-$(basename "${1%.*}").img"
fi

mkbootimg "${args[@]}" --output "$out"
unpack_bootimg --boot_img "$out" --out "$(mktemp -d)" |
  grep -E '^(kernel_size|ramdisk size|page size|boot image header version)' >&2
log "wrote ${out#"$ROOT"/} ($(stat -c %s "$out") bytes)"
