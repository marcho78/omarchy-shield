#!/usr/bin/env bash
# Build the FIT payload for the SHIELD TV 2017 and wrap it with U-Boot:
#   - the kernel from scripts/11
#   - our device tree, kernel/dts/darcy.dts on top of mainline's darcy board
#   - an initramfs whose /init is tools/darcy-init.c, with the firmware
#     pinned in config.sh (FIRMWARE, VENDOR_FIRMWARE) under /lib/firmware
#
# With --system, the installed system's payload instead: the device tree is
# kernel/dts/darcy-system.dts, which mounts the root filesystem from the
# eMMC (scripts/13), and the initramfs holds only the firmware, which the
# built-in drivers load before the root filesystem is up.
#
# Output: build/payload/darcy.itb and build/boot-uboot-darcy.img, the image
# to write with scripts/09-boot-via-recovery.sh; with --system,
# build/system/darcy-system.itb and build/boot-uboot-darcy-system.img.
#
# Usage: scripts/12-make-payload.sh [--system]
source "$(dirname "$0")/lib.sh"
need cpp dtc gcc mkimage aarch64-linux-gnu-gcc gzip curl sha256sum

src="$ROOT/vendor/linux"
kbuild="$ROOT/build/linux"
if [[ ${1:-} == --system ]]; then
  out="$ROOT/build/system" dts=darcy-system fit=darcy-system.itb
else
  out="$ROOT/build/payload" dts=darcy fit=darcy.itb
fi
[[ -f $kbuild/arch/arm64/boot/Image.gz ]] || die "build the kernel first: scripts/11-build-kernel.sh"
mkdir -p "$out"

log "device tree: kernel/dts/$dts.dts"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
  -I "$src/arch/arm64/boot/dts" -I "$src/include" -I "$ROOT/kernel/dts" \
  -o "$out/darcy.dts.pre" "$ROOT/kernel/dts/$dts.dts"
if [[ $dts == darcy-system ]]; then
  log "root filesystem: $SYSTEM_ROOT (config.sh SYSTEM_ROOT)"
  sed -i "s|@SYSTEM_ROOT@|$SYSTEM_ROOT|" "$out/darcy.dts.pre"
fi
dtc -q -I dts -O dtb -o "$out/darcy.dtb" "$out/darcy.dts.pre"

firmware_repo() {
  local entry
  for entry in "${FIRMWARE_REPOS[@]}"; do
    [[ ${entry%%|*} == "$1" ]] && { echo "$entry"; return; }
  done
  die "config.sh FIRMWARE names an unknown repository: $1"
}

log "firmware from upstream repositories (config.sh FIRMWARE)"
fw_dirs=() fw_files=()
for entry in "${FIRMWARE[@]}"; do
  IFS='|' read -r repo path sum <<< "$entry"
  IFS='|' read -r _ url commit <<< "$(firmware_repo "$repo")"
  file="$ROOT/vendor/firmware/$repo/$path"
  if ! echo "$sum  $file" | sha256sum -c --status 2>/dev/null; then
    mkdir -p "$(dirname "$file")"
    curl -fsSL -o "$file" "$url/plain/$path?id=$commit"
    echo "$sum  $file" | sha256sum -c --status || die "checksum mismatch for $repo/$path"
  fi
  fw_files+=("file /lib/firmware/$path $file 0644 0 0")
done

log "firmware from NVIDIA's vendor partition (scripts/04)"
for entry in "${VENDOR_FIRMWARE[@]}"; do
  name=${entry%%|*} path=${entry##*|}
  file="$ROOT/recovery/$RECOVERY_VERSION/vendor-firmware/$name"
  [[ -s $file ]] || die "missing $file: run scripts/04-unpack-recovery.sh"
  fw_files+=("file /lib/firmware/$path $file 0644 0 0")
done

# gen_init_cpio needs every parent directory listed
for f in "${fw_files[@]}"; do
  d=$(dirname "$(cut -d' ' -f2 <<< "$f")")
  while [[ $d != / ]]; do
    fw_dirs+=("$d")
    d=$(dirname "$d")
  done
done

if [[ $dts == darcy ]]; then
  log "initramfs with tools/darcy-init.c as /init"
  aarch64-linux-gnu-gcc -static -Os -Wall -o "$out/init" "$ROOT/tools/darcy-init.c"
else
  log "initramfs with the firmware only: the kernel mounts root= and starts systemd"
fi
gcc -O2 -o "$out/gen_init_cpio" "$src/usr/gen_init_cpio.c"
{
  cat <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
dir /sys 0755 0 0
EOF
  [[ $dts == darcy ]] && echo "file /init $out/init 0755 0 0"
  printf '%s\n' "${fw_dirs[@]}" | sort -u | sed 's|.*|dir & 0755 0 0|'
  printf '%s\n' "${fw_files[@]}"
} > "$out/initramfs.list"
"$out/gen_init_cpio" -t 0 "$out/initramfs.list" | gzip -9 -n > "$out/initramfs.cpio.gz"

log "FIT image"
cp "$kbuild/arch/arm64/boot/Image.gz" "$out/Image.gz"
cp "$ROOT/kernel/darcy.its" "$out/darcy.its"
(cd "$out" && mkimage -q -f darcy.its "$fit")
ls -l "$out"/{Image.gz,darcy.dtb,initramfs.cpio.gz,"$fit"} >&2

"$ROOT/scripts/06-make-bootimg.sh" "$out/$fit"
