# Omarchy on NVIDIA SHIELD TV 2017 ("darcy")

Goal: run Omarchy natively on the Shield, by booting Arch Linux ARM on a
mainline kernel and installing the community `omarchy-arm` port on top.

## The device

| | |
|---|---|
| Model | SHIELD Android TV 2017, product `darcy` (retail P2897, board P2894) |
| SoC | Tegra X1 (T210, not Mariko): 4x Cortex-A57, Maxwell GM20B GPU |
| RAM / storage | 3 GB LPDDR4 / 16 GB eMMC, no microSD |
| OS | SHIELD Experience 9.x, Android 11, build `RQ1A.210105.003` |
| Network | Wi-Fi on the LAN at 192.168.1.121 (mDNS `SHIELD`, `Android.local`). Not to be confused with the Google TV Streamer "Main TV" (`kirkwood`) at 192.168.1.68 (`Android-2.local`), which also advertises adb |
| USB ports | Port closest to HDMI: host (keyboard, mouse, drives). Port farthest from HDMI: adb/fastboot over a USB-A male-to-male cable |

## Phase 0 results (2026-10-21, read over network adb)

Everything here is reproduced by `scripts/02`–`04`; see `README.md`.

- Raw dumps are in `device-info/` (`summary.txt` first).
- NVIDIA's downstream DT sources are in `vendor/lineage-t210-foster/kernel-dts/`,
  at the commit pinned in `config.sh`.
- The compiled stock DTBs are in `recovery/9.1.1/blob-parts/*-DTB.dts`. Ours is
  most likely `13-DTB` (`p2894-0050-a08`).

Recovery image 9.1.1 (sha256 is in `config.sh`):
- **Contents:** `blob`, `boot.img`, `recovery.img`, `system.img`, `vendor.img`.
- **NVIDIA's `flash-all.sh`:** flashes `staging` blob, then boot, recovery,
  system and vendor. It does not touch userdata.
- **`blob` format:** `NVIDIA__BLOB__V2`, a 36-byte header plus 19 entries of 52
  bytes (name, offset, size, version).
  - Entries: EBT and RBL (same data, cboot), BPF, NVC and NVC-B, TBC and TBC-B,
    WB0, TOS, BCT, RP4.
  - It holds 4 DTBs, mirrored into both DTB and RP1, one per board revision:
    `0000-a00`, `0050-a04`, `0050-a08`, `0052-a08`.
- **`boot.img`:** header v1, page size 2048, no ramdisk (Android 11 system-as-root).
  - Its cmdline is only `buildvariant=user veritykeyid=...`, so cboot supplies the rest.
  - It has no DTB in the image; cboot uses the DTB partition.
- **`recovery.img`:** same layout, plus a 9 MB ramdisk.

- **Bootloader:** cboot `32.00.2019.50-t210-69ebfcbe`. `ro.boot.verifiedbootstate=green`, so it is **locked**.
- **Android kernel:** `4.9.141-tegra`. MemTotal is 2.88 GiB.
- **Board:** BOM `675128970050500A`, SKU `U12897TP`. That is P2897-0050 on board
  p2894-0050, most likely rev a08 (mainline's name too). Confirm with
  `fastboot oem dtbname`.
- **Partitions:**
  - Boot slots: `LNX`=p18 (boot), `SOS`=p16 (recovery)
  - Never flash: `DTB`=p17, `TOS`=p11, `EKS`=p12, `EBT`=p4, `BPF`=p1, `TBC`/`TBC-B`=p2/p3, `RP1`=p9
  - Android: `APP`=p19 (system), `vendor`=p21, `CAC`=p20, `MSC`=p22, `UDA`=p33 (userdata)
  - Firmware blob: `RP4`=p26
- **The live DT can't be read without root** (SELinux). Only the node layout was
  captured, in `device-info/live-dt-layout.dts`. The full properties are in
  the recovery image DTBs instead.

Hardware, from Android drivers and the downstream DT:

| Part | darcy wiring |
|---|---|
| Ethernet | Realtek r8168 on PCIe (x1 lane `pcie-0`) → mainline `r8169` |
| Wi-Fi | Broadcom (bcmdhd) on **SDMMC2** (`sdhci@700b0200`). SDMMC1 (SD) is disabled. BT is on a UART. GPIOs are in `tegra210-loki-e-comms.dtsi` |
| USB, far port | `usb2-0` OTG, plus SS lane `pcie-6` and `xudc`. VBUS is GPIO Z0 active-low, ID is MAX77620 GPIO0. This is the PC/fastboot port |
| USB, near port | `usb2-2` host, plus SS lane `pcie-5` |
| Display | DC0 → SOR1 (HDMI). HPD/DDC are in `tegra210-ers-hdmi-e2190-1100-a00.dtsi` (t210 common repo) |
| Fan | `pwm-fan` (`tegra210-darcy-pwm-fan.dtsi`) plus `therm_fan_est`. Needs `PWM_TEGRA` |
| Lightbar | `pwm-leds`, `tegra_pwm` ch0 at 10 ms, enable GPIO V0 active-low |
| Power key | GPIO X7 active-low |
| Other | INA3221 power monitor on i2c@7000c400 (0x40). Secure OS is TLK (`androidboot.secureos=tlk`). CPU rail is MAX77621 (`dfll-max77621`) |
| Bootloader menu | Shield controller on USB, in the port **near** HDMI (X/Y move, A selects). The PC goes on the **far** port |

The Google TV Streamer at .68 also has adb enabled. Don't confuse the two devices.

USB and fastboot (2026-10-22, `scripts/07`; raw output in `device-info/fastboot.txt`):

- **Cabling.** The Shield needs a USB-A male-to-male cable from a USB-A port on
  the computer (a USB-C hub works) to its port farthest from HDMI. A plain
  USB-A-to-C phone cable shows no USB device at all on the T2 MacBook.
- **USB IDs.** In Android with USB debugging, the Shield shows up as
  `0955:b43d` "NVIDIA Tegra Device", high speed. systemd's uaccess grants
  adb/fastboot access, so no udev rules are needed.
- **Bootloader `getvar`.** `version-bootloader: 1.0`, `product: t210ref`,
  `secure: Yes`, `unlocked: No`, `partition-size:dtb: 0x400000`.
- **Board revision confirmed:** `fastboot oem dtbname` reports
  `tegra210-darcy-p2894-0050-a08-00.dtb`. That is the same board as mainline's
  `tegra210-p2894-0050-a08.dts` and blob entry `13-DTB`.
- **Bootloader input.** A USB keyboard in the port near HDMI drives the menu
  (arrow keys + Enter, confirmed 2026-10-22).
- **`fastboot reboot` quirk.** It answers `FAILED (remote: 'unknown reason')`,
  but the Shield came back to Android anyway.

## The host

Omarchy 4.5.0rc1 (x86_64) on Intel T2 MacBook hardware, which has USB-C ports only.

Installed for this project: `aarch64-linux-gnu-gcc`, `aarch64-linux-gnu-binutils`,
`dtc`, `uboot-tools`, `arch-install-scripts`, `swig`, `python-pyelftools`,
`python-setuptools`, `bc`. Already present: `android-tools` (adb, fastboot,
mkbootimg), `qemu-user-static` with binfmt.

## What we know

- **Omarchy is x86_64 only upstream.** The community port `omarchy-arm`
  (github.com/alexisraitano-myffu/omarchy-arm, branch `arm64`, version
  4.0.0.alpha) installs onto a running Arch Linux ARM system. It has been
  validated on an aarch64 VM and on a Pi 5 over SSH. It needs working KMS and a
  GL render node. Read `docs/arm64-port.md` in that repo before running it.
- **Mainline Linux has a darcy device tree, but it is barebones.**
  `tegra210-p2894-0050-a08.dts` enables only UART-A, eMMC, the MAX77620 PMIC,
  PMC, cpuidle and the power key. It has no HDMI, GPU, USB, PCIe or audio. NVIDIA
  added it in 2019.
- **The 2015 Shield (foster, P2571) runs mainline Linux** through archeYR's
  postmarketOS port (`archeYR/linux` and `archeYR/u-boot`, branch
  `nvidia-foster`, based on v6.8-rc1). HDMI, 3D (nouveau GM20B), Wi-Fi, Bluetooth,
  Ethernet, audio and USB-A work. The fan and eMMC do not (eMMC uses TegraPT).
  The fork is six commits, mostly a board DT. This is the template for darcy.
- **cboot cannot boot a mainline kernel directly.** cboot hands the kernel the
  Android DT from the `dtb` partition, and flashing that partition has bricked
  Shields. The working answer is U-Boot as a second-stage loader.
- **Correction (2026-10-22): LineageOS does *not* use this chain on darcy.**
  Its `releasetools.py` flashes its own bootloader blob to `staging` and its
  own DTB to the `DTB` partition. Its U-Boot wrapping in `mkbootimg.mk` only
  applies when `TARGET_TEGRA_UBOOT_CONFIG` is set, and the SHIELD TV builds
  don't set it. The proven U-Boot chain on a SHIELD is archeYR's
  postmarketOS foster port. The wrapping logic itself
  (`--kernel u-boot-dtb.bin --ramdisk <payload>`) is still the model.
  Dependencies:
  - `android_hardware_nvidia_u-boot` (`lineage-23.2`)
  - `android_hardware_nvidia_arm-trusted-firmware` (T210 branch)
  - kernel 6.18 (`android_kernel_nvidia_kernel`, `lineage-24.0_6.18`)
  - T210 DTs (`android_hardware_nvidia_t21x_lineage`)

  The Lineage darcy DTS wraps the same barebones mainline p2894 dtsi, so we
  still have to find out how darcy hardware gets described. Lineage's kernel
  does have full foster DTs: `tegra210-p2571-0930.dts` and `-0932.dts`.
- **The Arch Linux ARM kernel (`linux-aarch64` 7.2.11) has most of the Tegra
  drivers.** It has DRM_TEGRA, NOUVEAU, XHCI_TEGRA, XUDC, PCI_TEGRA, R8169,
  BRCMFMAC, HDA_TEGRA, SOCTHERM and FB_SIMPLE. It lacks PWM_TEGRA (fan, and
  maybe vdd-gpu) and TEGRA210_EMC, so expect a custom kernel config.
- **ALARM Mesa 26.2.5 builds `gallium-drivers=all`**, which includes the tegra
  and nouveau drivers.
- **`fastboot boot` is reported broken on newer Shield firmware**
  (andreiw/shieldTV_loader). If so, the fallback is to flash only the
  `recovery` partition.
- **cboot rewrites the DT it hands over.** It changes the memory map,
  carveouts, VPR and `/chosen` bootargs. Our DTB has to carry over cboot's
  `/memory`, `/reserved-memory` and `/chosen`, or at least define a
  `reserved-memory` node. Without one, cboot can corrupt the kernel's DT
  (Aaron Kling, LKML 2025-10).
- **Don't count on U-Boot reaching storage on this chip.** postmarketOS reports
  that mainline U-Boot on T210 boots from SD only, and darcy has no SD slot. So
  U-Boot boots the kernel, initramfs and DTB from the in-RAM inner boot image
  (the LineageOS model), and Linux mounts the rootfs from USB.
- **Hyprland needs OpenGL ES, not Vulkan.** Prove the GPU with `kmscube` and
  `glmark2-es2-drm` first. NVK on GM20B is a bonus.

## Plan

0. **No risk.** Enable Developer options and Network debugging. Over adb,
   collect the live DT (`/proc/device-tree`), cmdline, partitions, bootloader
   version and lock state. Get the official NVIDIA darcy recovery image as the
   safety net.
1. **Wipes Android user data. Ask the user first.** Connect a USB A-A cable,
   run `adb reboot bootloader`, then `fastboot oem unlock`.
2. **Prove the chain.** U-Boot is built (`scripts/05`). The boot image is
   U-Boot plus a FIT payload (kernel, DTB, initramfs) as its ramdisk
   (`scripts/06`). Try `fastboot boot`; if that fails, flash `recovery` only.
   See "Boot chain design" below.
3. **Bring up the darcy DT.** Add XUSB, PCIe Ethernet, HDMI (SOR1), GPU,
   Wi-Fi, audio and fan. Port from the foster DTs, the live downstream DT and
   NVIDIA's 9.2.2 GPL source drop. There is no known serial access, so debug
   with:
   - simplefb on HDMI
   - USB gadget serial or network through the kernel's XUDC driver
   - ramoops, read back from Android after a warm reboot
   - netconsole
   - a watchdog reboot, so failed boots fall back
4. Put the ALARM rootfs on a USB SSD, then boot, network and SSH in.
5. Run `omarchy-arm` `install.sh --dry-run`, then the real install. Then tune
   for Tegra: `AQ_DRM_DEVICES`, nouveau pstate, a light Hyprland profile.
6. Make it persistent. Dual-boot by putting Linux in the recovery slot and
   keeping Android in boot.

## Boot chain design (U-Boot target `p2894`)

The base is LineageOS U-Boot v2025.07 at the commit pinned in `config.sh`,
plus `patches/u-boot/0001-board-nvidia-add-SHIELD-TV-2017-P2894-darcy.patch`.
`scripts/05` builds it and `scripts/06` wraps it.

- **Start-up.** cboot loads U-Boot as a kernel at `0x80080000`
  (`CONFIG_TEXT_BASE`) and passes its own DT in `x0`.
- **What U-Boot reads from cboot's DT.** `arch/arm/mach-tegra/cboot.c`
  already handles part of it:
  - the memory map (`/memory`, carveouts excluded)
  - `/chosen/bootargs`, which becomes `$cbootargs`
  - the DT address itself, which becomes `$fdt_addr`

  Our `board/nvidia/p2894/p2894.c` adds the rest:
  - **The framebuffer**, from `/reserved-memory/fb0_carveout`. It is enabled in
    U-Boot's own `simple-framebuffer` (`board_fix_fdt`) only if it fits 1080p
    inside DRAM. Otherwise the console stays on the UART. There is no fallback
    address, because video probe clears the surface.
  - **The ramdisk**, from `/chosen/linux,initrd-start` and `-end`, as one or two
    cells. Its CRC32 is always printed. It becomes `$cboot_fit_start` only if
    it lies in RAM and holds a whole FIT.
  - **The board revision** from `/nvidia,dtsfilename`, plus every cboot memory
    bank, with a warning if there are more than `NR_DRAM_BANKS`.

  It prints all of this on the TV.
- **Boot.** `bootcmd=run darcy_boot` clears `fdt_high`, then runs
  `bootm ${cboot_fit_start}`. Tegra's `fdt_high=~0` would make `bootm` grow the
  FIT's device tree in place, over the next image. The kernel cmdline comes
  from the DT inside the FIT. `ft_board_setup` writes the kernel its own
  `simple-framebuffer` node, with the real `a8b8g8r8` format, and reserves it.
- **Hardware access.** Our board code writes nothing: no PMIC writes, no GPIOs,
  no storage.
  - The environment is `ENV_IS_NOWHERE`. Networking, EFI and every
    write-capable storage command are compiled out. `scripts/05` asserts all
    of this after each build, because Kconfig silently flips options: turning
    off `BOOTSTD` once silently dropped `bootcmd`.
  - `CONFIG_TEGRA_GPU`, which writes and locks the VPR after the secure OS has
    set it, is off. GPU/VPR becomes its own experiment once Linux runs.
  - Tegra's generic init still runs, as on every cboot-chainloaded T210
    U-Boot (Jetson TX1/Nano under L4T, archeYR's foster). That is
    `clock_init()`, the UART pinmux, the arch timer, and XUSB pad init plus
    power-down before Linux. This is an accepted risk: cboot's HDMI output
    survived it on foster.
  - The P2571 board's `pin_mux_mmc` (LDO2) and `start_cpu_fan` (GPIO E4, which
    is a DMIC clock on darcy) are deliberately not carried over.
- **Boot image header.** Copied from stock `recovery.img`, the stock image
  with a ramdisk. The offsets are NVIDIA's base `10000000` *decimal* plus the
  usual offsets, which are not DRAM addresses. So cboot places the kernel and
  ramdisk itself, and the probe test measures where.
- **Debugging without a UART.**
  - Photograph U-Boot's report on the TV.
  - Later, Linux on simplefb shows its console on HDMI.
  - Ramoops at `0xb0000000` (2 MB, same as stock) survives a warm reboot, and
    `adb bugreport` includes "last kmsg".

n-codex reviewed the patch (`research/ncodex-uboot-review.md`). Findings 1, 3,
4, 5, 7, 8 and 9 are fixed. Finding 2 (U-Boot relocating or allocating over
cboot's ramdisk) depends on where cboot puts the ramdisk, so the probe test
measures it before any real payload. Finding 6 is accepted as described above.

### First device test (after unlocking)

**Unlock, 2026-10-22.** `scripts/08` erased userdata and cache, then printed
"Bootloader is unlocked now". The Shield stayed in fastboot, reporting
`unlocked: Yes`.

**cboot limits.** `max-download-size` is 32 MiB, and the boot and recovery
partitions are 0x1980000 bytes (25.5 MiB) each. A 33 MB image got
`FAILED (remote: 'data too large')`. `config.sh` now caps boot images at
25.5 MiB, `scripts/06` enforces it, and the probe ramdisk is 24 MiB.

**`fastboot boot` does not work on darcy.** cboot accepted the 24.4 MB probe
image and answered "Booting OKAY". It then never booted it:
- the TV stayed on the NVIDIA logo
- USB still showed `0955:b442 NVIDIA Corp. Fastboot`, with no re-enumeration
- fastboot stopped answering, so even `getvar` hung

A power cycle is needed to recover. This matches andreiw's 2018 note that
"`fastboot boot` is kinda broken on newer firmware".

Test images therefore go through the recovery slot (`scripts/09`):

    CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh build/boot-uboot-probe.img

Then choose "Recovery mode" in the bootloader menu. Expect U-Boot's report on
the TV. Check that the ramdisk CRC32 equals `build/probe-ramdisk.crc32`, which
is `6b05be7e` for the 24 MiB probe. A different value means something overwrote
it before late init, so finding 2 needs work before any payload.

Put stock recovery back with:

    CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh --restore

## Never flash

`dtb`, `staging`/blob, BCT, bootloader/EBT, TOS, EKS, the GPT/partition table, or
the eMMC boot partitions. Flash only `boot` or `recovery`, and only while the
darcy recovery image is at hand. Use only the 2017 darcy image, never a foster,
mdarcy or sif one.

Never relock the bootloader while a custom image is installed. Before flashing
anything, confirm we can still reach both fastboot and Forced Recovery (RCM)
from the bootloader menu.

## Working with n-codex

n-codex is a Codex agent in herdr tab `wM:t1` (pane `wM:p1`), used for
brainstorming:

    herdr agent prompt wM:p1 "..." --wait --timeout 900000

Its TUI only keeps the visible screen. For long answers, ask it to write
Markdown to a file and reply with the path.

Its first brainstorm (boot-chain ranking, DT porting order, blind debugging,
recovery rules) is in `research/ncodex-boot-chain-brainstorm.md`.

## Sources

- https://github.com/alexisraitano-myffu/omarchy-arm (docs/arm64-port.md)
- https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi
- https://wiki.postmarketos.org/wiki/Nvidia_SHIELD_TV_2015_/_2015_Pro_/_2017_Pro_(nvidia-foster)
- https://github.com/archeYR/linux/tree/nvidia-foster
- https://github.com/archeYR/u-boot/tree/nvidia-foster
- https://github.com/LineageOS/android_device_nvidia_foster/blob/lineage-23.2/mkbootimg.mk
- https://github.com/LineageOS/android_hardware_nvidia_t21x_lineage
- https://github.com/andreiw/shieldTV_loader
- https://yifan.lu/2022/06/17/unbricking-shield-tv-2015-with-a-bootrom-exploit/
- https://web.uri.edu/wp-content/uploads/sites/1991/ShieldDIY.pdf (USB port roles, `fastboot oem dtbname`)
