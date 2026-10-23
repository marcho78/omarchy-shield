# Review brief: first boots of the installed system on the SHIELD TV 2017 (darcy)

Analysis only: do not change any file in the repository and do not touch the
device. Repository: ~/projects/nvidia (read NOTES.md, sections "The installed
system" and "The first boot of the installed system", for the background).

## Setup

- NVIDIA SHIELD TV 2017 (darcy, P2894, Tegra X1 / T210). Chain: cboot -> our
  U-Boot (vendor/lineage-u-boot + patches/u-boot/0001-*.patch) -> FIT with
  mainline Linux 7.2.11, device tree kernel/dts/darcy-system.dts (which
  includes kernel/dts/darcy.dts), and an initramfs holding only firmware.
- Kernel config: arm64 defconfig, every platform but Tegra off, plus
  kernel/darcy.config (scripts/11-build-kernel.sh). MODVERSIONS and
  MODULE_SIG are off. tegra-drm, host1x, nouveau and snd-hda-tegra are
  modules (=m).
- Root filesystem: Arch Linux ARM (systemd 262, iwd 3.12, bluez 5.87) built by
  scripts/13-make-rootfs.sh, on an external NVMe SSD (JMicron 152d:581d,
  usb-storage, USB 2 speed behind a Genesys hub), root=PARTLABEL=darcy-root,
  rootwait=30. The SHIELD's boot partition holds U-Boot + the system FIT
  (scripts/14-install-system.sh); the recovery slot holds a test payload
  (tools/darcy-init.c) that prints a report and reboots.
- U-Boot policy for the system payload (/chosen/darcy,system): boot again
  after a normal reboot; show the last log (ramoops) and reboot into the
  bootloader menu (fastboot) only after a panic (a ramoops dump record) or a
  watchdog reset (cboot's androidboot.bootreason=watchdog). U-Boot arms the
  watchdog (150 s); systemd takes it over through tegra_wdt.
- The HDMI console works through simpledrm on the framebuffer cboot leaves
  running, reserved by U-Boot. To keep that picture, darcy.dts deletes the
  pd_sor powergate node and all power-domains references to it (the PMC
  driver powers down every partition it finds on, which killed HDMI), and
  boots with clk_ignore_unused pd_ignore_unused regulator_ignore_unused.

## Facts from the system's journal (read from the SSD on the laptop)

Three boots so far. Boots 1 and 3 ran the same images:
1. `Startup finished in 10.690s (kernel) + 13.309s (userspace)`: the system
   boots fully from the SSD.
2. `tegra-wdt 60005000.timer: initialized`; `systemd: Using hardware
   watchdog /dev/watchdog0: 'Tegra Watchdog'`: the watchdog hand-over works
   (darcy.dts adds "nvidia,tegra30-timer" to the timer node).
3. Display: `[drm] Initialized simpledrm ... fb0` at boot, then about 3 s
   into userspace (udev) `[drm] Initialized tegra 1.0.0 for drm on minor 1`
   and `drm drm: [drm] Cannot find any crtc or sizes`; from then on the TV
   shows no picture. drivers/gpu/drm/tegra/drm.c:1260 calls
   aperture_remove_all_conflicting_devices(), which removes simpledrm.
4. Wi-Fi: iwd exits at start (status 1, five times, then start-limit-hit):
   "The following options are missing in the kernel: CONFIG_CRYPTO_USER_API_HASH
   CONFIG_CRYPTO_USER_API_SKCIPHER CONFIG_KEY_DH_OPERATIONS CONFIG_CRYPTO_ECB
   CONFIG_CRYPTO_MD5 CONFIG_CRYPTO_CBC CONFIG_CRYPTO_SHA256 CONFIG_CRYPTO_AES
   CONFIG_CRYPTO_DES CONFIG_CRYPTO_CMAC CONFIG_CRYPTO_HMAC CONFIG_CRYPTO_SHA512
   CONFIG_CRYPTO_SHA1". In build/linux/.config: USER_API_HASH,
   USER_API_SKCIPHER and KEY_DH_OPERATIONS are not set; MD5 and DES are =m;
   ECB, CBC, SHA1/256/512, AES, CMAC and HMAC are =y; CRYPTO_USER_API=m.
   systemd-modules-load also fails to find pkcs8_key_parser (iwd's
   modules-load.d); PKCS8_PRIVATE_KEY_PARSER is not set.
5. Other lines: `cpufreq-tegra124 ... probe ... failed with error -2`;
   `failed to register cpuidle driver` (cpuidle.off=1 is on the command
   line); `set-wireless-regdom failed with exit code 1` (no regulatory domain
   configured); `usb 1-3.1: reset high-speed USB device` (the SSD) at the
   end of boot 1, around when its power was pulled.
6. Console login works in principle: agetty rejected two blindly typed
   login names with "checkname failed" (util-linux 2.42 rejects names longer
   than 42 characters or starting with '-').

## The situation now

The installed system runs but shows no picture and has no network, so there
is no way into it except reading the SSD on the laptop. Writing fixes into
the SHIELD's boot partition needs the bootloader menu (fastboot). The plan to
get there: power on without the SSD -> the kernel waits 30 s for its root,
panics (panic=10) -> U-Boot finds the ramoops dump record, shows the log and
reboots into the bootloader menu. That path is untested.

## Proposed fixes

1. Display: `module_blacklist=tegra_drm` on the system's command line
   (kernel/dts/darcy-system.dts; already built, not yet flashed).
2. Wi-Fi: add to kernel/darcy.config CONFIG_CRYPTO_USER_API_HASH=y,
   CONFIG_CRYPTO_USER_API_SKCIPHER=y, CONFIG_KEY_DH_OPERATIONS=y,
   CONFIG_CRYPTO_MD5=y, CONFIG_CRYPTO_DES=y, CONFIG_PKCS8_PRIVATE_KEY_PARSER=y;
   rebuild the kernel; reinstall its modules on the SSD (rebuild the root
   filesystem with scripts/13 and rewrite the SSD with scripts/15).
3. Put a Wi-Fi network into the image (device-info/wifi, scripts/13), so
   the next boot joins Wi-Fi and SSH works without the TV.

## Questions

a) Is module_blacklist=tegra_drm the right and sufficient fix to keep
   simpledrm? Could host1x, nouveau, snd-hda-tegra or anything else in a
   normal systemd boot also evict the framebuffer or blank HDMI? Cite code.
b) Is the SSD-less panic route to the bootloader sound (check U-Boot's
   dump_recorded() and the ramoops max-reason = <1> in darcy-system.dts)?
   Better ways into fastboot on darcy without a working display or network?
c) Is the iwd option list complete for WPA2/WPA3-personal on arm64 with
   brcmfmac (e.g. anything for SAE, AES-CE)? Is reinstalling the modules
   needed with MODVERSIONS off, or would the old ones load safely?
d) A debug channel that doesn't depend on the display or Wi-Fi: e.g. a USB
   gadget (tegra-xudc: serial console or Ethernet) on the OTG port the
   laptop's fastboot cable already uses. How much work on this board, and
   what in darcy.dts would it need?
e) Anything wrong or risky in the plan, or a simpler order of steps.

Be concrete; point to files and lines. Say what is verified and what is a
guess.
