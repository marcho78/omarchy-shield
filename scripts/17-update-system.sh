#!/usr/bin/env bash
# Put a new build on a SHIELD that runs the installed system, with nothing
# to press on the TV, over SSH and the USB cable:
#   1. The kernel's modules (scripts/11) replace the SHIELD's when the build's
#      kernel is not the one running, or with --modules: a kernel and its
#      modules must come from the same build.
#   2. Linux reboots into the bootloader menu (fastboot).
#   3. scripts/14 writes build/boot-uboot-darcy-system.img the moment fastboot
#      shows up: the menu Linux reboots into does not always wait (NOTES.md).
#   4. The bootloader reboots into it, and once SSH answers again, this
#      checks that the build's kernel runs.
#
# Needs SSH as root with device-info/ssh/id_ed25519 (scripts/13), and this
# computer on the SHIELD's USB port far from HDMI.
#
# Usage: CONFIRM_FLASH=yes scripts/17-update-system.sh [--modules] <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh fastboot tar cmp make depmod aarch64-linux-gnu-gcc

args=("$@")
modules=false
if [[ ${1:-} == --modules ]]; then
  modules=true
  shift
fi
host=${1:-}
[[ -n $host ]] || die "usage: CONFIRM_FLASH=yes $0 [--modules] <the SHIELD's address>"

kbuild="$ROOT/build/linux"
stage="$ROOT/build/modules"
boot="$ROOT/build/boot-uboot-darcy-system.img"
key="$ROOT/device-info/ssh/id_ed25519"

[[ -f $kbuild/modules.order ]] || die "build the kernel first: scripts/11-build-kernel.sh"
[[ -f $boot ]] || die "build the system payload first: scripts/12-make-payload.sh --system"
cmp -s "$kbuild/arch/arm64/boot/Image.gz" "$ROOT/build/system/Image.gz" ||
  die "${boot#"$ROOT"/} holds another kernel than build/linux: rerun scripts/12-make-payload.sh --system"
[[ -f $key ]] || die "no device-info/ssh/id_ed25519: scripts/13 makes it, with the root filesystem"
[[ ${CONFIRM_FLASH:-} == yes ]] || die "this reboots the SHIELD at $host and replaces its boot partition with ${boot#"$ROOT"/}.
  To go ahead, run: CONFIRM_FLASH=yes $0 ${args[*]}"

on_shield() {
  ssh -i "$key" -o UserKnownHostsFile="$ROOT/device-info/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "root@$host" "$@"
}

release=$(cat "$kbuild/include/config/kernel.release")
built="$release $(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$kbuild/include/generated/utsversion.h")"
running=$(on_shield uname -rv) || die "no SSH to root@$host"
log "the SHIELD at $host runs $running"
[[ $running == "$built" ]] || modules=true

if $modules; then
  log "staging the modules of $built in build/modules"
  rm -rf "$stage"
  make -s -C "$ROOT/vendor/linux" O="$kbuild" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="$stage/usr" INSTALL_MOD_STRIP=1 modules_install
  rm -f "$stage/usr/lib/modules/$release/build"
  log "replacing the SHIELD's /usr/lib/modules/$release"
  # Unpacked next to the old tree and swapped in only once complete, so a
  # broken copy leaves the old modules in place
  rel=$(printf %q "$release")
  tar -C "$stage/usr/lib/modules" --owner=0 --group=0 --numeric-owner -cf - "$release" |
    on_shield "set -e; cd /usr/lib/modules; rm -rf .darcy-new .darcy-old; mkdir .darcy-new
      tar -xf - -C .darcy-new; test -s .darcy-new/$rel/modules.dep
      if [ -d $rel ]; then mv $rel .darcy-old; fi
      mv .darcy-new/$rel $rel; rm -rf .darcy-new .darcy-old; sync"
fi

before=$(nvidia_usb)
log "rebooting the SHIELD into its bootloader menu"
on_shield 'systemctl --reboot-argument=bootloader reboot' 2> /dev/null || true
for ((t = 0; t < 240; t++)); do
  now=$(nvidia_usb)
  [[ $now != "$before" && $now == *:b442 ]] && break
  sleep 0.5
done
[[ $now != "$before" && $now == *:b442 ]] ||
  die "no fastboot on USB within 2 minutes (now $now): is this computer on the SHIELD's USB port far from HDMI? If the TV shows the bootloader menu, run scripts/14 from there"

log "fastboot is up ($now)"
"$ROOT/scripts/14-install-system.sh" || die "scripts/14 stopped (above); the SHIELD may start its old system again"
log "rebooting into it: nothing to choose on the TV"
# cboot answers FAILED (remote: 'unknown reason'), then resets all the same
timeout 20 fastboot reboot > /dev/null 2>&1 || true

deadline=$((SECONDS + 180))
until running=$(on_shield uname -rv 2> /dev/null); do
  ((SECONDS < deadline)) || die "no SSH from the SHIELD within 3 minutes of the reboot: look at the TV"
  sleep 2
done
[[ $running == "$built" ]] || die "the SHIELD runs $running, not this build's kernel"
log "done: the SHIELD runs $running"
