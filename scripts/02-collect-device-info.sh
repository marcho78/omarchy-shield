#!/usr/bin/env bash
# Phase 0: read-only snapshot of the SHIELD over network adb, into device-info/.
#
# On the SHIELD first: Settings > Device Preferences > About > press Build 7
# times, then Developer options > Network debugging. Approve the prompt on the
# TV when this script connects. Nothing on the SHIELD is changed.
#
# device-info/ holds serial numbers; it is git-ignored, keep it private.
#
# Usage: scripts/02-collect-device-info.sh   (SHIELD_IP=<address> skips discovery)
source "$(dirname "$0")/lib.sh"
need adb dtc tar

target="$(shield_ip):$SHIELD_ADB_PORT"
adb_attach "$target"
out="$ROOT/device-info"
mkdir -p "$out"
sh_() { adb -s "$target" shell "$@" | tr -d '\r'; }

log "collecting from $target into device-info/"
sh_ getprop > "$out/getprop.txt"
sh_ uname -a > "$out/uname.txt"
sh_ 'cat /proc/cpuinfo; head -5 /proc/meminfo' > "$out/cpu-mem.txt"
sh_ 'ls -l /dev/block/by-name/' > "$out/partitions.txt"
sh_ 'for n in /sys/class/net/*; do
       echo "$(basename $n) driver=$(basename "$(readlink $n/device/driver)") bus=$(basename "$(readlink $n/device/subsystem)")"
     done 2>/dev/null; echo; cat /proc/modules' > "$out/drivers.txt"

# Device-tree property files are SELinux-protected without root, so this only
# captures the node layout. The full DTB comes from the recovery image (04).
adb -s "$target" exec-out 'tar -cf - -C /sys/firmware/devicetree/base . 2>/dev/null' > "$out/live-dt.tar"
rm -rf "${out:?}/live-dt-fs" && mkdir -p "$out/live-dt-fs"
tar -xf "$out/live-dt.tar" -C "$out/live-dt-fs"
dtc -q -I fs -O dts -o "$out/live-dt-layout.dts" "$out/live-dt-fs"

prop() { sed -n "s/^\[$1\]: \[\(.*\)\]$/\1/p" "$out/getprop.txt"; }
{
  echo "product:        $(prop ro.product.device) ($(prop ro.product.model))"
  echo "SHIELD version: $(prop ro.build.version.ota), Android $(prop ro.build.version.release)"
  echo "bootloader:     $(prop ro.bootloader)"
  echo "verified boot:  $(prop ro.boot.verifiedbootstate)  (green = locked, orange = unlocked)"
  echo "BOM / SKU:      $(prop persist.sys.nvidia.bom) / $(prop sys.device.sku)"
  echo "kernel:         $(cat "$out/uname.txt")"
  echo "partitions:     $(grep -oE '[A-Za-z0-9_-]+ -> /dev/block/mmcblk0p[0-9]+' "$out/partitions.txt" |
                          sed 's#/dev/block/mmcblk0##' | tr '\n' ' ')"
} | tee "$out/summary.txt"
