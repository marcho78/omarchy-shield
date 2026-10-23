#!/usr/bin/env bash
# Build the root filesystem for the SHIELD's eMMC: Arch Linux ARM's generic
# aarch64 image (config.sh ALARM_*), fully upgraded, with ROOTFS_PACKAGES and
# what this board needs:
#   - the modules of our kernel (scripts/11); Arch Linux ARM's own kernel
#     cannot boot here and goes
#   - NVIDIA's Wi-Fi and Bluetooth firmware under darcy's board-specific
#     names, ahead of linux-firmware's generic Broadcom files
#   - Wi-Fi through iwd, with DHCP by systemd-networkd as for Ethernet
#   - bluetoothd, sudo for the wheel group, and the build host's timezone, so
#     that the first boot asks nothing on the TV
#   - SSH as root with a key of its own; no passwords over the network
#   - systemd keeping the watchdog U-Boot arms (tegra_wdt)
#   - the files under rootfs/, such as the thermal guard
#     (scripts/18 updates them on a running SHIELD)
#   - a filesystem that grows to fill its partition on the first boot
#
# No root needed: the work runs in a user namespace mapped onto your
# /etc/subuid range, and pacman runs inside the ARM image through QEMU's
# binfmt handler.
#
# Private, in device-info/ (git-ignored):
#   wifi            optional, two lines, SSID=... and PASSPHRASE=...: the
#                   network to join; without it, join from the TV (iwctl)
#   ssh/id_ed25519  made on the first run; logs in as root:
#                   ssh -i device-info/ssh/id_ed25519 root@<the SHIELD>
#
# Output: build/rootfs.img (ext4, label darcy-root) and build/rootfs.simg,
# its sparse form for fastboot.
#
# Usage: scripts/13-make-rootfs.sh
source "$(dirname "$0")/lib.sh"

rootfs="$ROOT/build/rootfs"
img="$ROOT/build/rootfs.img"
alarm="$ROOT/vendor/alarm"
tarball="$alarm/${ALARM_URL##*/}"
kbuild="$ROOT/build/linux"
key="$ROOT/device-info/ssh/id_ed25519"
wifi="$ROOT/device-info/wifi"

if [[ ${1:-} != --in-namespace ]]; then
  need curl gpg sha256sum bsdtar unshare newuidmap mke2fs img2simg ssh-keygen make aarch64-linux-gnu-gcc
  [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] ||
    die "no binfmt handler for aarch64 programs: install qemu-user-static-binfmt"
  grep -q "^$(id -un):" /etc/subuid ||
    die "no subordinate user IDs for $(id -un) in /etc/subuid (usermod --add-subuids)"
  [[ -f $kbuild/modules.order ]] || die "build the kernel first: scripts/11-build-kernel.sh"
  for entry in "${VENDOR_FIRMWARE[@]}"; do
    [[ -s $ROOT/recovery/$RECOVERY_VERSION/vendor-firmware/${entry%%|*} ]] ||
      die "missing NVIDIA's firmware: run scripts/04-unpack-recovery.sh"
  done

  mkdir -p "$alarm"
  export GNUPGHOME="$alarm/gnupg"
  mkdir -p -m 700 "$GNUPGHOME"
  if ! echo "$ALARM_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
    log "downloading ${ALARM_URL##*/}"
    curl -fL -o "$tarball" "$ALARM_URL"
    curl -fsSL -o "$tarball.sig" "$ALARM_URL.sig"
  fi
  [[ -f $tarball.sig ]] || curl -fsSL -o "$tarball.sig" "$ALARM_URL.sig"
  gpg --batch --list-keys "$ALARM_KEY" > /dev/null 2>&1 ||
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$ALARM_KEY"
  gpg --batch --status-fd 1 --verify "$tarball.sig" "$tarball" 2> /dev/null |
    grep -q "VALIDSIG $ALARM_KEY " || die "${tarball##*/} is not signed by Arch Linux ARM ($ALARM_KEY)"
  echo "$ALARM_SHA256  $tarball" | sha256sum -c --status ||
    die "Arch Linux ARM replaced ${tarball##*/} (its signature is good): pin
  ALARM_SHA256=$(sha256sum "$tarball" | cut -d' ' -f1) in config.sh"

  if [[ ! -f $key ]]; then
    log "making the SSH key that logs in as root: device-info/ssh/id_ed25519"
    mkdir -p -m 700 "${key%/*}"
    ssh-keygen -q -t ed25519 -N '' -C root@darcy -f "$key"
  fi
  [[ -f $wifi ]] || warn "no device-info/wifi: the SHIELD will not join Wi-Fi by itself (join from the TV with iwctl)"

  unshare --map-auto --map-root-user --mount --pid --fork --kill-child \
    "$ROOT/scripts/${0##*/}" --in-namespace

  log "sparse image for fastboot"
  img2simg "$img" "${img%.img}.simg"
  log "built build/rootfs.img ($(du -h --apparent-size "$img" | cut -f1)) and build/rootfs.simg ($(du -h "${img%.img}.simg" | cut -f1))"
  exit 0
fi

# From here on: root of a user namespace, which ends with this script and
# takes its mounts along

log "unpacking ${tarball##*/}"
rm -rf "$rootfs"
mkdir -p "$rootfs"
bsdtar -xpf "$tarball" -C "$rootfs"

# What arch-chroot sets up. /etc/resolv.conf links into /run, so the host's
# goes there.
mount --bind "$rootfs" "$rootfs"
mount -t proc proc "$rootfs/proc"
mount --rbind /sys "$rootfs/sys"
mount --rbind /dev "$rootfs/dev"
mount -t tmpfs tmpfs "$rootfs/run"
mkdir -p "$rootfs/run/systemd/resolve"
cp -L /etc/resolv.conf "$rootfs/run/systemd/resolve/resolv.conf"

in_chroot() {
  chroot "$rootfs" /usr/bin/env -i PATH=/usr/bin HOME=/root TERM=dumb LANG=C.UTF-8 "$@"
}

log "pacman's keyring"
in_chroot pacman-key --init
in_chroot pacman-key --populate archlinuxarm

# pacman's download sandbox does not work under QEMU's user-mode emulation
sed -i 's/^#\(DisableSandbox\(Filesystem\|Syscalls\)\)$/\1/' "$rootfs/etc/pacman.conf"
log "dropping Arch Linux ARM's kernel: ours comes in the FIT"
in_chroot pacman -Rns --noconfirm linux-aarch64
log "full upgrade, and ${ROOTFS_PACKAGES[*]}"
in_chroot pacman -Syu --noconfirm --needed "${ROOTFS_PACKAGES[@]}"
sed -i 's/^\(DisableSandbox\(Filesystem\|Syscalls\)\)$/#\1/' "$rootfs/etc/pacman.conf"
in_chroot systemctl enable iwd.service bluetooth.service
in_chroot gpgconf --homedir /etc/pacman.d/gnupg --kill all
rm -rf "$rootfs"/var/cache/pacman/pkg/*

log "the kernel's modules"
release=$(cat "$kbuild/include/config/kernel.release")
make -s -C "$ROOT/vendor/linux" O="$kbuild" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$rootfs/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$rootfs/usr/lib/modules/$release/build"

log "NVIDIA's firmware, under darcy's board-specific names"
for entry in "${VENDOR_FIRMWARE[@]}"; do
  name=${entry%%|*} path=${entry##*|}
  install -D -m 644 "$ROOT/recovery/$RECOVERY_VERSION/vendor-firmware/$name" \
    "$rootfs/usr/lib/firmware/${path%.*}.$BOARD_COMPATIBLE.${path##*.}"
done

log "darcy's settings"
echo darcy > "$rootfs/etc/hostname"
echo "LABEL=darcy-root / ext4 rw,relatime,x-systemd.growfs 0 1" >> "$rootfs/etc/fstab"

# Nothing left for systemd-firstboot to ask on the TV
zone=$(readlink /etc/localtime 2> /dev/null || true)
zone=${zone#*/zoneinfo/}
ln -sf "/usr/share/zoneinfo/${zone:-UTC}" "$rootfs/etc/localtime"
echo KEYMAP=us > "$rootfs/etc/vconsole.conf"

# Wi-Fi gets an address the way Ethernet does (eth.network, en.network)
cat > "$rootfs/etc/systemd/network/wl.network" << 'EOF'
[Match]
Name=wl*

[Network]
DHCP=yes
DNSSEC=no
EOF

if [[ -f $wifi ]]; then
  ssid=$(sed -n 's/^SSID=//p' "$wifi")
  passphrase=$(sed -n 's/^PASSPHRASE=//p' "$wifi")
  [[ -n $ssid && -n $passphrase ]] || die "device-info/wifi needs an SSID=... and a PASSPHRASE=... line"
  # iwd names a network's file after its SSID, or =<hex> if the SSID has
  # characters other than letters, digits, space, - and _
  if [[ $ssid =~ ^[A-Za-z0-9_\ -]+$ ]]; then
    file=$ssid
  else
    file="=$(printf %s "$ssid" | od -An -tx1 | tr -d ' \n')"
  fi
  install -d -m 700 "$rootfs/var/lib/iwd"
  (umask 077 && printf '[Security]\nPassphrase=%s\n' "$passphrase" > "$rootfs/var/lib/iwd/$file.psk")
  log "Wi-Fi: joins \"$ssid\""
fi

install -d -m 700 "$rootfs/root/.ssh"
install -m 600 "$key.pub" "$rootfs/root/.ssh/authorized_keys"
cat > "$rootfs/etc/ssh/sshd_config.d/10-darcy.conf" << 'EOF'
# Keys only over the network; the default passwords still work on the TV
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

echo '%wheel ALL=(ALL:ALL) ALL' > "$rootfs/etc/sudoers.d/10-wheel"
chmod 440 "$rootfs/etc/sudoers.d/10-wheel"

# Once the system is up, only critical kernel messages (KERN_CRIT and worse,
# so oopses and panics in full) go to the consoles: the TV, and the ramoops
# console U-Boot shows after a crash. The boot itself still shows (the
# installed system boots without ignore_loglevel). To see everything again
# until the next boot: echo Y > /sys/module/printk/parameters/ignore_loglevel
echo 'kernel.printk = 3 4 1 7' > "$rootfs/etc/sysctl.d/20-quiet-console.conf"

# Until the GPU is proven, nothing loads nouveau at boot; it is tried by hand
# over SSH. "install" covers loads by name as well as udev's
cat > "$rootfs/etc/modprobe.d/20-darcy-nouveau.conf" << 'EOF'
# nouveau powers the GPU up, and is not loaded at boot while that is being
# proven. "blacklist" stops udev loading it for the GPU; "install" stops any
# load by name. By hand: modprobe --ignore-install nouveau
blacklist nouveau
install nouveau /bin/true
EOF

mkdir -p "$rootfs/etc/systemd/system.conf.d"
cat > "$rootfs/etc/systemd/system.conf.d/10-watchdog.conf" << 'EOF'
# Keep the watchdog U-Boot armed (tegra_wdt): a hung system resets
[Manager]
RuntimeWatchdogSec=60s
EOF

log "darcy's own files (rootfs/)"
cp -r --preserve=mode "$ROOT/rootfs/." "$rootfs/"
in_chroot systemctl enable darcy-thermal-guard.service

log "ext4 image"
# Detaching the bind mount everything else sits on takes all of it along
umount --lazy "$rootfs"
! mountpoint -q "$rootfs/proc" || die "$rootfs is still mounted"
size=$(($(du -sm "$rootfs" | cut -f1) * 5 / 4 + 512))
rm -f "$img"
mke2fs -q -t ext4 -L darcy-root -d "$rootfs" "$img" "${size}M"
rm -rf "$rootfs"
