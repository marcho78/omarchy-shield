#!/usr/bin/env bash
# Put the kernel modules of the current build (scripts/11) onto the USB disk
# that holds the installed system (scripts/15), in place: everything else on
# the disk stays, the journal included. A kernel and its modules must come
# from the same build, so pair this with flashing the matching boot image
# (scripts/12 --system, then scripts/14), and boot neither half alone.
#
# Plug the disk into this computer and run, as yourself; only the copy onto
# the disk asks for sudo:
#   scripts/16-update-usb-disk.sh
source "$(dirname "$0")/lib.sh"
need make depmod rsync lsblk findmnt udisksctl sudo

kbuild="$ROOT/build/linux"
stage="$ROOT/build/modules"
[[ -f $kbuild/modules.order ]] || die "build the kernel first: scripts/11-build-kernel.sh"
release=$(cat "$kbuild/include/config/kernel.release")

part=$(readlink -f /dev/disk/by-partlabel/darcy-root 2>/dev/null || true)
[[ -b $part ]] || die "no partition named darcy-root: plug the disk into this computer"
disk=/dev/$(lsblk -no PKNAME "$part")
[[ $(lsblk -dno TRAN "$disk") == usb ]] || die "$part is not on a USB disk"

log "staging the modules of $release in build/modules"
rm -rf "$stage"
make -s -C "$ROOT/vendor/linux" O="$kbuild" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$stage/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$stage/usr/lib/modules/$release/build"

# findmnt fails when the partition is not mounted; that is not an error here
mnt=$(findmnt -nro TARGET "$part" 2> /dev/null | head -1 || true)
if [[ -z $mnt ]]; then
  udisksctl mount -b "$part" > /dev/null
  mnt=$(findmnt -nro TARGET "$part" 2> /dev/null | head -1 || true)
fi
# An empty $mnt would point the copy at this computer's own /usr/lib/modules
[[ -n $mnt && $mnt != / ]] || die "could not find where $part is mounted"
[[ -d $mnt/usr/lib/modules ]] || die "$part (mounted at $mnt) holds no /usr/lib/modules"

log "disk: $disk ($(lsblk -dno VENDOR,MODEL,SIZE "$disk" | xargs)), $part mounted at $mnt"
log "replacing $mnt/usr/lib/modules/$release (sudo)"
sudo rsync -a --delete --chown=0:0 "$stage/usr/lib/modules/$release/" "$mnt/usr/lib/modules/$release/"
sync
udisksctl unmount -b "$part" > /dev/null || die "the copy is done, but $part did not unmount: unmount it before unplugging"
log "done: the disk holds the modules of this build. Flash the matching boot image before it boots again."
