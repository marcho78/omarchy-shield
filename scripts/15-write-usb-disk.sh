#!/usr/bin/env bash
# Write the root filesystem (scripts/13) to a USB disk for the SHIELD to
# boot from, so Android's partitions on the eMMC stay as they are. The disk
# gets a GPT with one partition filling it, named darcy-root (config.sh
# SYSTEM_ROOT); the filesystem is copied in and grown to fill it.
# EVERYTHING ON THE DISK IS ERASED.
#
# Plug the disk into this computer (not into the SHIELD) and run, as root:
#   sudo scripts/15-write-usb-disk.sh /dev/sdX
# It refuses anything but a whole, unmounted USB disk big enough for the
# filesystem, shows what it found, and asks you to type the disk's name
# before it erases it.
#
# Then plug the disk into the SHIELD's hub (the port near HDMI), and put
# U-Boot and the system into the boot partition:
#   CONFIRM_FLASH=yes scripts/14-install-system.sh
source "$(dirname "$0")/lib.sh"
need lsblk wipefs sfdisk udevadm dd e2fsck resize2fs

img="$ROOT/build/rootfs.img"
(($# == 1)) || die "usage: sudo $0 /dev/sdX"
dev=$1
((EUID == 0)) || die "run it as root: sudo $0 $dev"
[[ -f $img ]] || die "build the root filesystem first: scripts/13-make-rootfs.sh"
[[ $SYSTEM_ROOT == PARTLABEL=darcy-root ]] ||
  die "config.sh has SYSTEM_ROOT=$SYSTEM_ROOT; a USB disk needs PARTLABEL=darcy-root"

[[ -b $dev ]] || die "$dev is not a block device"
[[ $(lsblk -dno TYPE "$dev") == disk ]] || die "$dev is not a whole disk"
[[ $(lsblk -dno TRAN "$dev") == usb ]] || die "$dev is not a USB disk"
(($(lsblk -bdno SIZE "$dev") >= $(stat -c %s "$img"))) ||
  die "$dev ($(lsblk -dno SIZE "$dev" | tr -d ' ')) is smaller than the root filesystem"
if lsblk -no MOUNTPOINTS "$dev" | grep -q .; then
  die "$dev has mounted partitions: unmount them first"
fi

model=$(lsblk -dno VENDOR,MODEL "$dev" | xargs) size=$(lsblk -dno SIZE "$dev" | tr -d ' ')
lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev" >&2
read -r -p "Everything on $dev ($model, $size) will be erased. Type ${dev#/dev/} to go ahead: " answer
[[ $answer == "${dev#/dev/}" ]] || die "not confirmed; nothing was changed"

log "partitioning $dev: GPT, one partition named darcy-root"
wipefs -q -a "$dev"
# The type is the Discoverable Partitions Specification's root for arm64
sfdisk -q "$dev" << 'EOF'
label: gpt
name=darcy-root, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE
EOF
udevadm settle
part=$(lsblk -lnpo NAME,PARTLABEL "$dev" | awk '$2 == "darcy-root" { print $1 }')
[[ -b $part ]] || die "the new partition on $dev did not appear"

log "writing build/rootfs.img to $part"
dd if="$img" of="$part" bs=4M conv=fsync status=progress
log "checking the filesystem, then growing it to fill the partition"
e2fsck -f -y "$part" || (($? == 1)) || die "the filesystem on $part has errors"
resize2fs "$part"
sync

log "done. Plug the disk into the SHIELD's hub (the port near HDMI), then:"
log "  CONFIRM_FLASH=yes scripts/14-install-system.sh"
