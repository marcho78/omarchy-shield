#!/usr/bin/env bash
# Build the FIT payload for the SHIELD TV 2017 and wrap it with U-Boot:
#   - the kernel from scripts/11
#   - our device tree, kernel/dts/darcy.dts on top of mainline's darcy board
#   - an initramfs whose /init is tools/darcy-init.c
#
# Output: build/payload/darcy.itb and build/boot-uboot-darcy.img, the image
# to write with scripts/09-boot-via-recovery.sh.
#
# Usage: scripts/12-make-payload.sh
source "$(dirname "$0")/lib.sh"
need cpp dtc gcc mkimage aarch64-linux-gnu-gcc gzip

src="$ROOT/vendor/linux"
kbuild="$ROOT/build/linux"
out="$ROOT/build/payload"
[[ -f $kbuild/arch/arm64/boot/Image.gz ]] || die "build the kernel first: scripts/11-build-kernel.sh"
mkdir -p "$out"

log "device tree"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
  -I "$src/arch/arm64/boot/dts" -I "$src/include" \
  -o "$out/darcy.dts.pre" "$ROOT/kernel/dts/darcy.dts"
dtc -q -I dts -O dtb -o "$out/darcy.dtb" "$out/darcy.dts.pre"

log "initramfs with tools/darcy-init.c as /init"
aarch64-linux-gnu-gcc -static -Os -Wall -o "$out/init" "$ROOT/tools/darcy-init.c"
gcc -O2 -o "$out/gen_init_cpio" "$src/usr/gen_init_cpio.c"
cat > "$out/initramfs.list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
dir /sys 0755 0 0
file /init $out/init 0755 0 0
EOF
"$out/gen_init_cpio" -t 0 "$out/initramfs.list" | gzip -9 -n > "$out/initramfs.cpio.gz"

log "FIT image"
cp "$kbuild/arch/arm64/boot/Image.gz" "$out/Image.gz"
cp "$ROOT/kernel/darcy.its" "$out/darcy.its"
(cd "$out" && mkimage -q -f darcy.its darcy.itb)
ls -l "$out"/{Image.gz,darcy.dtb,initramfs.cpio.gz,darcy.itb} >&2

"$ROOT/scripts/06-make-bootimg.sh" "$out/darcy.itb"
