# Review brief: step 3 (Wi-Fi) for the installed system on darcy

Analysis only: do not change any file in the repository and do not touch the
device. Repository: ~/projects/nvidia. Background: research/firstboot-review-brief.md
and the four reviews next to it (research/*-firstboot-review.md), and
NOTES.md "The first boot of the installed system".

## Where things stand

- The installed system boots from the USB SSD (root=PARTLABEL=darcy-root);
  the boot partition holds U-Boot + the system FIT.
- Step 2, not yet done: flash the boot image that is already built
  (build/boot-uboot-darcy-system-step2.img, a byte copy of
  build/boot-uboot-darcy-system.img): the OLD kernel plus
  module_blacklist=tegra_drm, so the TV keeps its picture and console login
  becomes visible. The route to the bootloader menu for that: boot with the
  SSD unplugged, panic after rootwait=30, U-Boot shows the log, then fastboot.
- Step 3 is this brief: make Wi-Fi work. iwd 3.12 exits at start in every
  boot so far because the kernel lacks its crypto interface (the journal's
  list and build/linux/.config are in the first-boot brief). brcmfmac itself
  works: wlan0 came up with NVIDIA's firmware from the initramfs, MAC
  00:90:4c:16:70:01 (the NVRAM's placeholder).

## Step 3's changes (git diff against HEAD, plus one new script)

The kernel is already rebuilt with them: all seven options below ended up
=y in build/linux/.config (CRYPTO_USER_API was promoted from =m by select),
and the release is unchanged, 7.2.11-ga2de78ee6ed8 (MODVERSIONS off). The
step-3 FIT is NOT built yet, so that build/boot-uboot-darcy-system.img stays
step 2's image until step 2 is flashed.

```diff
diff --git i/config.sh w/config.sh
index 8ac0d05..120f30a 100644
--- i/config.sh
+++ w/config.sh
@@ -98,6 +98,10 @@ VENDOR_FIRMWARE=(
 #                         writes in place of Android's user data
 SYSTEM_ROOT=PARTLABEL=darcy-root
 
+# The Wi-Fi regulatory domain (ISO 3166 country code), set by the kernel
+# itself (cfg80211.ieee80211_regdom); the image has no iw for Arch's helper
+WIFI_COUNTRY=US
+
 # darcy's device tree names the board "nvidia,p2894-0050-a08" (the first
 # root compatible), and drivers look for board-specific firmware under that
 # name before the generic one: brcm/brcmfmac4354-sdio.nvidia,p2894-0050-a08.bin
diff --git i/kernel/darcy.config w/kernel/darcy.config
index 0ffcc94..f0dc056 100644
--- i/kernel/darcy.config
+++ w/kernel/darcy.config
@@ -47,3 +47,14 @@ CONFIG_UHID=y
 # loaded from it when eth0 comes up, after the root filesystem is mounted)
 CONFIG_FW_LOADER_COMPRESS=y
 CONFIG_FW_LOADER_COMPRESS_ZSTD=y
+
+# iwd does its crypto through the kernel (AF_ALG sockets and keyctl) and
+# exits at start without these, listing what it misses; MD5 and DES are
+# built in so that nothing waits for a module. The PKCS#8 parser is what
+# iwd's modules-load.d asks for (EAP-TLS keys).
+CONFIG_CRYPTO_USER_API_HASH=y
+CONFIG_CRYPTO_USER_API_SKCIPHER=y
+CONFIG_KEY_DH_OPERATIONS=y
+CONFIG_CRYPTO_MD5=y
+CONFIG_CRYPTO_DES=y
+CONFIG_PKCS8_PRIVATE_KEY_PARSER=y
diff --git i/kernel/dts/darcy-system.dts w/kernel/dts/darcy-system.dts
index 3327b28..f3605ac 100644
--- i/kernel/dts/darcy-system.dts
+++ w/kernel/dts/darcy-system.dts
@@ -11,17 +11,18 @@
 / {
 	chosen {
 		/*
-		 * darcy.dts's, plus the root filesystem: scripts/12 puts
-		 * config.sh SYSTEM_ROOT in place of @SYSTEM_ROOT@. Without it
-		 * after 30 s, the kernel panics, and U-Boot shows the log
-		 * after the reset.
+		 * darcy.dts's, plus the root filesystem and the Wi-Fi country:
+		 * scripts/12 puts config.sh SYSTEM_ROOT and WIFI_COUNTRY in
+		 * place of @SYSTEM_ROOT@ and @WIFI_COUNTRY@. Without the root
+		 * filesystem after 30 s, the kernel panics, and U-Boot shows
+		 * the log after the reset.
 		 *
 		 * tegra-drm stays out until its HDMI bring-up is done: when
 		 * udev loads it, it removes the simple framebuffer the console
 		 * is on, then finds no output it can drive ("Cannot find any
 		 * crtc or sizes"), and the TV goes dark.
 		 */
-		bootargs = "earlycon=uart8250,mmio32,0x70006000 console=ttyS0,115200n8 console=tty0 fbcon=font:TER16x32 consoleblank=0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused cpuidle.off=1 ignore_loglevel panic=10 printk.devkmsg=on module_blacklist=tegra_drm root=@SYSTEM_ROOT@ rootwait=30 rw";
+		bootargs = "earlycon=uart8250,mmio32,0x70006000 console=ttyS0,115200n8 console=tty0 fbcon=font:TER16x32 consoleblank=0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused cpuidle.off=1 ignore_loglevel panic=10 printk.devkmsg=on module_blacklist=tegra_drm cfg80211.ieee80211_regdom=@WIFI_COUNTRY@ root=@SYSTEM_ROOT@ rootwait=30 rw";
 
 		/*
 		 * U-Boot boots it again after a reboot, and shows its log only
diff --git i/scripts/12-make-payload.sh w/scripts/12-make-payload.sh
index 246ed6b..e2c6567 100755
--- i/scripts/12-make-payload.sh
+++ w/scripts/12-make-payload.sh
@@ -33,8 +33,8 @@ cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
   -I "$src/arch/arm64/boot/dts" -I "$src/include" -I "$ROOT/kernel/dts" \
   -o "$out/darcy.dts.pre" "$ROOT/kernel/dts/$dts.dts"
 if [[ $dts == darcy-system ]]; then
-  log "root filesystem: $SYSTEM_ROOT (config.sh SYSTEM_ROOT)"
-  sed -i "s|@SYSTEM_ROOT@|$SYSTEM_ROOT|" "$out/darcy.dts.pre"
+  log "root filesystem: $SYSTEM_ROOT, Wi-Fi country: $WIFI_COUNTRY (config.sh)"
+  sed -i "s|@SYSTEM_ROOT@|$SYSTEM_ROOT|; s|@WIFI_COUNTRY@|$WIFI_COUNTRY|" "$out/darcy.dts.pre"
 fi
 dtc -q -I dts -O dtb -o "$out/darcy.dtb" "$out/darcy.dts.pre"
 
```

New file scripts/16-update-usb-disk.sh:

```bash
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
need make rsync lsblk findmnt udisksctl sudo

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

mnt=$(findmnt -nro TARGET "$part" | head -1)
if [[ -z $mnt ]]; then
  udisksctl mount -b "$part" > /dev/null
  mnt=$(findmnt -nro TARGET "$part" | head -1)
fi
[[ -d $mnt/usr/lib/modules ]] || die "$part (mounted at $mnt) holds no /usr/lib/modules"

log "replacing $mnt/usr/lib/modules/$release (sudo)"
sudo rsync -a --delete --chown=0:0 "$stage/usr/lib/modules/$release/" "$mnt/usr/lib/modules/$release/"
sync
udisksctl unmount -b "$part" > /dev/null
log "done: the disk holds the modules of this build. Flash the matching boot image before it boots again."
```

The Wi-Fi NVRAM (recovery/9.1.1/vendor-firmware/nvram_darcy_a00.txt, installed
as brcm/brcmfmac4354-sdio.txt in the initramfs and under the board name in
the rootfs) has ccode=XV, regrev=0; the CLM blob is NVIDIA's
bcmdhd_clm_darcy.blob.

## Planned sequence for step 3 (after step 2 has shown a picture and a login)

1. On the TV, as root: `systemctl --reboot-argument=bootloader reboot`; the
   bootloader menu comes up.
2. Unplug the SSD, plug it into the laptop, run scripts/16 (stages
   modules_install of the new build in build/modules, then sudo rsync
   --delete --chown=0:0 into /usr/lib/modules/7.2.11-ga2de78ee6ed8 on the SSD,
   then unmounts).
3. scripts/12-make-payload.sh --system (new kernel; the command line gains
   cfg80211.ieee80211_regdom=US), then CONFIRM_FLASH=yes
   scripts/14-install-system.sh (boot partition only) while the SHIELD sits
   in the menu.
4. SSD back on the SHIELD's hub, Continue. On the TV: `iwctl station wlan0
   connect "<SSID>"`; then SSH from the laptop with device-info/ssh/id_ed25519
   (the image has key-only sshd for root, systemd-networkd DHCP for wl*,
   systemd-resolved).

## Questions

a) Does this option set make iwd 3.12 start and join a WPA2-PSK network on
   this arm64 kernel? Check Kconfig dependencies (anything silently dropped
   or newly pulled in that matters), and whether CRYPTO_USER_API going from
   =m to =y or the crypto changes affect anything else.
b) cfg80211.ieee80211_regdom=US with brcmfmac and NVIDIA's NVRAM/CLM
   (ccode=XV): does brcmfmac pass cfg80211's country to the firmware (its
   reg notifier), and what happens if the CLM blob has no US entry? Could it
   make things worse than leaving the world domain? Recommend keep or drop.
c) scripts/16: is it safe and complete (PARTLABEL lookup, USB check, mount
   handling, rsync --delete --chown=0:0 scope, depmod done in staging,
   stale md5.ko/des_generic.ko left in build/linux from the =m days)? Does
   anything else on the SSD have to change with the kernel?
d) The ordering: the old FIT must never boot the new modules, nor the new
   FIT the old modules. Is the sequence airtight, and is there a simpler
   one?
e) Anything else that will stop Wi-Fi or SSH on the first try.

Be concrete; point to files and lines. Say what is verified and what is a
guess.
