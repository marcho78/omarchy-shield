#!/usr/bin/env bash
# Verify NVIDIA's recovery image and unpack it into recovery/<version>/ for
# reference: the bootloader blob split into its partitions, the board DTBs
# decompiled, the boot/recovery image headers, and the firmware in
# config.sh VENDOR_FIRMWARE taken out of vendor.img. This never runs
# NVIDIA's flash scripts and never talks to the SHIELD.
#
# Usage: scripts/04-unpack-recovery.sh [path/to/recovery.tgz]
#        (default: ~/Downloads/$RECOVERY_FILE from config.sh)
source "$(dirname "$0")/lib.sh"
need sha256sum tar dtc fdtget unpack_bootimg python3 simg2img debugfs

tgz=${1:-$HOME/Downloads/$RECOVERY_FILE}
[[ -f $tgz ]] || die "missing $tgz
  Download \"$RECOVERY_TITLE\" $RECOVERY_VERSION from https://developer.nvidia.com/tools-downloads"

log "verifying sha256 of $(basename "$tgz")"
echo "$RECOVERY_SHA256  $tgz" | sha256sum -c --quiet - || die "checksum mismatch: wrong or corrupt download"

out="$ROOT/recovery/${RECOVERY_VERSION:?}"
log "unpacking into recovery/$RECOVERY_VERSION/"
rm -rf "$out" && mkdir -p "$out"
tar -xzf "$tgz" -C "$out"

log "splitting the bootloader blob"
python3 -I "$ROOT/tools/nvblob.py" "$out/blob" -x "$out/blob-parts" > "$out/blob-parts.txt"

log "decompiling the board DTBs"
for f in "$out"/blob-parts/*-DTB.bin; do
  dtc -q -I dtb -O dts -o "${f%.bin}.dts" "$f"
  printf '%s  %s\n' "$(basename "$f")" "$(basename "$(fdtget "$f" / nvidia,dtsfilename)")"
done | tee "$out/dtbs.txt"

for img in boot recovery; do
  unpack_bootimg --boot_img "$out/$img.img" --out "$out/$img-unpacked" > "$out/$img-header.txt"
done

log "extracting the firmware listed in config.sh VENDOR_FIRMWARE from vendor.img"
raw="$out/vendor.raw"
simg2img "$out/vendor.img" "$raw"
mkdir -p "$out/vendor-firmware"
for entry in "${VENDOR_FIRMWARE[@]}"; do
  file=${entry%%|*}
  debugfs -R "dump /firmware/$file $out/vendor-firmware/$file" "$raw" 2> /dev/null
  [[ -s $out/vendor-firmware/$file ]] || die "vendor.img has no /firmware/$file"
done
rm -f "${raw:?}"
log "done; boot image headers are in recovery/$RECOVERY_VERSION/*-header.txt"
