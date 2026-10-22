#!/usr/bin/env bash
# Wrap U-Boot, and optionally a ramdisk, in an Android boot image that cboot
# accepts (header fields from config.sh's BOOTIMG_ARGS).
#
#   scripts/06-make-bootimg.sh              -> build/boot-uboot.img
#     U-Boot only. It shows on the TV what cboot handed over: board
#     revision, bootargs, memory banks and framebuffer.
#   scripts/06-make-bootimg.sh --probe      -> build/boot-uboot-probe.img
#     Adds a dummy ramdisk of reproducible random bytes. U-Boot reports
#     where cboot put it and its CRC32; a CRC32 equal to
#     build/probe-ramdisk.crc32 proves U-Boot left it intact. This is the
#     first test on an unlocked SHIELD, before any real payload.
#   scripts/06-make-bootimg.sh payload.itb  -> build/boot-uboot-payload.img
#     A FIT image (kernel, device tree, initramfs) for U-Boot to boot.
source "$(dirname "$0")/lib.sh"
need mkbootimg unpack_bootimg python3 gzip

uboot="$ROOT/build/u-boot/u-boot-dtb.bin"
[[ -f $uboot ]] || die "build U-Boot first: scripts/05-build-u-boot.sh"

# NVIDIA's own kernels are gzip'd, and darcy's cboot fell back to fastboot
# within seconds when handed raw U-Boot, so gzip it like a kernel.
# -n keeps the output reproducible (no name or timestamp).
gzip -9 -n -c "$uboot" > "$uboot.gz"

args=("${BOOTIMG_ARGS[@]}" --cmdline "" --kernel "$uboot.gz")
out="$ROOT/build/boot-uboot.img"

if [[ ${1:-} == --probe ]]; then
  ((PROBE_RAMDISK_SIZE > 0)) || die "PROBE_RAMDISK_SIZE must be positive"
  ramdisk="$ROOT/build/probe-ramdisk.bin"
  python3 -I - "$ramdisk" "$PROBE_RAMDISK_SIZE" <<'EOF' > "$ROOT/build/probe-ramdisk.crc32"
import random, sys, zlib
data = random.Random(0x5EED).randbytes(int(sys.argv[2]))
open(sys.argv[1], "wb").write(data)
print(f"{zlib.crc32(data):08x}")
EOF
  args+=(--ramdisk "$ramdisk")
  out="$ROOT/build/boot-uboot-probe.img"
  log "probe ramdisk: $PROBE_RAMDISK_SIZE bytes, crc32 $(cat "$ROOT/build/probe-ramdisk.crc32")"
elif (($#)); then
  [[ -f $1 ]] || die "no such payload: $1"
  args+=(--ramdisk "$1")
  out="$ROOT/build/boot-uboot-$(basename "${1%.*}").img"
fi

mkbootimg "${args[@]}" --output "$out"
size=$(stat -c %s "$out")
if ((size > BOOTIMG_MAX_SIZE)); then
  rm -f "$out"
  die "boot image is $size bytes; the SHIELD's boot/recovery partitions hold $BOOTIMG_MAX_SIZE"
fi
unpack_bootimg --boot_img "$out" --out "$(mktemp -d)" |
  grep -E '^(kernel_size|ramdisk size|ramdisk load address|page size|boot image header version)' >&2
log "wrote ${out#"$ROOT"/} ($(stat -c %s "$out") bytes)"
