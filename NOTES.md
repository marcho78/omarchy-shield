# Omarchy on NVIDIA SHIELD TV 2017 ("darcy")

Goal: run Omarchy natively on the Shield, by booting Arch Linux ARM on a
mainline kernel and installing the community `omarchy-arm` port on top.

This is the day-by-day log, kept as it was written. `README.md` and `docs/`
summarize it, and `docs/lessons.md` lists what later work corrected.
Notes marked *[Later: …]* point from an early statement to its correction.

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
   *[Later: `fastboot boot` freezes cboot, so tests use the recovery slot;
   see "First device test".]*
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
  - **The framebuffer**, read from the display controller A window that shows
    cboot's logo: address, size, stride and format. Register offsets come from
    Linux's `drivers/gpu/drm/tegra/dc.h`, and the controller is only touched
    while clocked and out of reset. cboot's `/reserved-memory/fb0_carveout` is
    the fallback, but cboot leaves it empty on darcy. It is enabled in U-Boot's
    own `simple-framebuffer` (`board_fix_fdt`) only if it fits inside DRAM.
    There is no fallback address, because video probe clears the surface.
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

Then choose "Boot recovery kernel" in the bootloader menu. Expect U-Boot's report on
the TV. Check that the ramdisk CRC32 equals `build/probe-ramdisk.crc32`, which
is `6b05be7e` for the 24 MiB probe. A different value means something overwrote
it before late init, so finding 2 needs work before any payload.

Put stock recovery back with:

    CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh --restore

**Android restores its recovery on every boot.** The `vendor_flash_recovery`
service (`init.svc.vendor_flash_recovery` in getprop) runs at each normal
Android boot and rewrites the stock recovery over anything else in the
partition. That is what happened on the first try:
- the probe was flashed, then the Shield was power-cycled into Android
- `adb reboot recovery` then showed stock recovery's "No command"

So after `scripts/09`, choose "Boot recovery kernel" directly from the bootloader
menu.

**Recovery-slot attempts (2026-10-22).** Each attempt flashed the image, then
used "Boot recovery kernel" in the menu.
- **Raw `u-boot-dtb.bin` with the 24 MiB probe.** USB disconnected, then came
  back as fastboot ~7 s later. The TV showed only the NVIDIA logo, and fastboot
  was frozen afterwards.
- **gzip'd U-Boot with the same probe.** No USB disconnect at all, the NVIDIA
  logo, and fastboot frozen. A different path from raw: most likely cboot
  accepted the gzip'd kernel, jumped into U-Boot (which leaves USB alone), and
  U-Boot either has no framebuffer or hangs before video. NVIDIA's own kernels
  are gzip'd, so `scripts/06` now always gzips U-Boot.
- **After any failed or frozen attempt**, cboot stays enumerated as fastboot
  but answers nothing. Power-cycle into Android, then re-run 07 and 09.
- **The PMC is secure-only** (`nvidia,secure-pmc` in the stock DT). Non-secure
  code must reach it through the secure monitor (`TEGRA_SMC_PMC`). U-Boot's
  `tegra_pmc_*()` detect and handle this; Linux will need the same.
- **Signalling without a screen.** With no console and nothing to boot, U-Boot
  reboots: into the bootloader menu if cboot reported no framebuffer, into
  Android if it reported one U-Boot could not use. Both are visible on USB
  from the laptop.

n-codex's and n-grok's analyses of the boot failure are in
`research/ncodex-cboot-boot-failure.md` and `research/ngrok-cboot-boot-failure.md`.

### Milestone: our U-Boot runs on the SHIELD (2026-10-22)

Run 4: gzip'd U-Boot (framebuffer from the display controller) plus the
24 MiB probe, then "Boot recovery kernel". U-Boot's console came up on HDMI.
Transcribed from the TV:

```
SHIELD TV 2017 (P2894): U-Boot relocated to 0xfed97000
  display:     0x92cc3000, 1920x1080, stride 7680, a8b8g8r8, in use
               (display controller A, window A)
cboot handoff, device tree at 0000000083100000:
  board:       .../hardware/nvidia/platform/t210/foster/kernel-dts/tegra210-darcy-p2894-0050-a08-00.dts
  bootargs:    tegraid=21.1.2.0.0 ddr_die=3072M@2048M section=512M memtype=0 vpr_resize
               usb_port_owner_info=1 lane_owner_info=0 emc_max_dvfs=1 touch_id=0@63 video=tegrafb
               no_console_suspend=1 console=ttyS0,115200n8 debug_uartport=lsport,2
               earlyprintk=uart8250-32bit,0x70006000 maxcpus=4 usbcore.old_scheme_first=1
               lp0_vec=0x1000@0xff780000 nvdumper_reserved=0xff280000 core_edp_mv=1125 core_edp_ma=4000
               tegra_fbmem=0x800000@0x92cc3000 is_hdmi_initialised=1 loop.max_part=7
               androidboot.kerneltype=recovery post_recovery ... androidboot.bootreason=warm
               androidboot.bootloader=32.00.2019.50-t210-69ebfcbe rootdelay=1
               androidboot.verifiedbootstate=orange androidboot.secureos=tlk
               earlycon=uart8250,mmio32,0x70006000 strict_cma=on androidboot.modem=none ...
  memory:      3 bank(s) from cboot
               0x80000000 + 0x1f200000
               0xa0000000 + 0x5ee00000
               0x100000000 + 0x40000000
  fb0_carveout: none
  ramdisk:     0x84100000, 25165824 bytes, crc32 6b05be7e
               not a FIT image, so not booting it
```

What this establishes:
- **The chain works.** cboot runs gzip'd U-Boot from the recovery slot, and
  U-Boot relocates to the top of the second bank.
- **cboot places the ramdisk at `0x84100000`, and it arrives intact.** The CRC
  matches `build/probe-ramdisk.crc32`, so review finding 2 does not occur at
  this layout.
- **The framebuffer is DC A window A** at `0x92cc3000`, 1080p ABGR. That matches
  cboot's `tegra_fbmem=0x800000@0x92cc3000`.
- **Usable RAM is about 2.97 GB in three banks.** The gaps are carveouts:
  `0x9f200000`–`0xa0000000`, and `0xfee00000`–`0x100000000` (TOS, `lp0_vec`,
  nvdumper).
- **Bug found and fixed.** `Unknown command 'if'`: the hush shell had been
  silently dropped together with `BOOTSTD`. It is now set explicitly, and
  `scripts/05` asserts it.
- `Can't find Ethernet MAC address in cboot DTB` comes from generic `cboot.c`
  and is harmless.

**Next: a FIT payload** (mainline kernel + darcy DTB + small initramfs) that
fits with U-Boot under 25.5 MiB. The kernel loads at `0x80200000`, clear of
the FIT at `0x84100000`.

### First Linux payload: the handoff, checked before the first boot

`scripts/11` and `scripts/12` build the FIT and the boot image:
- **Kernel:** 7.2.11, built in only. The Image is 26 MB with `image_size`
  0x1980000, so it ends at `0x81b80000`.
- **Device tree:** our darcy.dts.
- **Initramfs:** darcy-init.
- **Boot image:** 11.8 MB.

Reading the kernel source turned up three problems that would have left the
TV dark. The third came from the n-codex review.
- **The framebuffer must be reserved `no-map`.** It lies inside the RAM cboot
  reports (bank 0). A `/memreserve/` keeps it in the kernel's linear map, and
  arm64 `ioremap` refuses linear-mapped RAM (`arch/arm64/mm/ioremap.c:27`),
  so simpledrm would fail to probe. U-Boot now adds
  `/reserved-memory/framebuffer@92cc3000` with `no-map` instead
  (`fdtdec_add_reserved_memory()`).
- **The HDMI 5V supply would be switched off 30 s after boot.** `vdd-hdmi` (a
  fixed regulator on GPIO CC7) is `regulator-boot-on` but not always-on. With
  no consumer, which tegra-drm would be, the regulator late cleanup disables
  it, and many TVs drop the picture without HDMI's +5V. The fix:
  - `regulator_ignore_unused` stops that cleanup for every unclaimed supply.
  - For the first boots, our DT also disables `vdd-hdmi`, so Linux never
    touches CC7. If a Tegra GPIO's probe defers, freeing the GPIO hands the
    pin back to its special function (`gpio-tegra.c:146`).
  - `consoleblank=0` was added at the same time.
- **Always-on rails would be pulsed off at probe.** regulator-fixed requests
  a rail's enable GPIO low unless the rail is `regulator-boot-on`
  (`drivers/regulator/fixed.c`). The core switches it back on only
  afterwards. Three rails are always-on without `boot-on`:
  - `vdd-3v3`
  - `vdd-sys-boost`, which feeds HDMI 5V
  - `vdd-disp-3v0`

  Our DT adds `boot-on` to all three.

The PMIC's HDMI LDOs (`vdd-gen-pll-edp`, `vdd-hdmi-dp`) are always-on.
DRM_TEGRA and HOST1X are modules, so nothing in this kernel touches the
display controller.

Limits of this first kernel, to fix during DT bring-up:
- **Fan and temperature.** SOCTHERM and `pwm-fan` are modules, so there is no
  temperature reading and no fan control. Linux would switch `vdd-fan`
  (GPIO E4, no `boot-on`) off when its driver probes, so our DT disables that
  node and the fan stays as cboot left it. Stock Android's "quiet"
  fan profile is 0% at the lowest state, so idle tests are fine. Long runs
  need both drivers built in, plus a `pwm-fan` node (stock: PWM channel 3).
  *[Later: the fan never ran under Linux, and the SHIELD overheated; see
  "The SHIELD overheated and powered off".]*
- **CPU clock.** Mainline's darcy DT has no CPU DFLL, so the CPUs stay at
  cboot's clock.
- **Idle.** Mainline enables the C7 state (PSCI `0x40000007`, the same one
  stock Android uses). The first boots run with `cpuidle.off=1` anyway.
- **USB, XUSB and PCIe.** None of them is enabled in mainline's darcy DT, so
  they are next for the DT: USB keyboard and drive, Ethernet on PCIe.

n-codex and n-grok reviewed the handoff (`research/*linux-handoff*`). The
ramoops node is now `no-map`, like stock. Suggestions checked against the
source and not taken:
- **Disable the pinmux (n-grok).** Its table is a `"boot"` state, which
  Linux never applies (the pinctrl core applies only `"default"`,
  `drivers/pinctrl/core.c:2227`). Disabling the pinmux would also leave the
  GPIO controller deferring forever on its `gpio-ranges`
  (`gpiolib-of.c:947`).
- **Disable the PMIC (n-grok).** The rails behind its GPIOs, and their
  consumers, would defer. Mainline's MAX77620 setup is what NVIDIA wrote
  for this board.
- **Turn the SMMU off (both, marked uncertain).** Its probe writes only the
  global PTC/TLB/CONFIG registers and enables no client's translation. The
  display controller scans out the physical address `0x92cc3000`, so it is
  in bypass. This is the first suspect if the picture dies as drivers start.
- **Drop earlycon and `console=ttyS0` (n-grok).** U-Boot already drives
  UART A without trouble.
- **Move the framebuffer node under `/chosen` (n-codex).** U-Boot's own
  `fdt_simplefb_add_node()` also puts it at the root, and Linux creates a
  device for it either way.
- **The PLLD write at clock init (n-codex).** BIT(25) selects the DSI clock
  source. HDMI on SOR1 does not use it.
- **`panic=10` (n-codex).** A panic left on the TV is a better channel than
  a ramoops whose stock layout we cannot read.

### First Linux boot: the screen went black (2026-10-22)

U-Boot's FIT loading messages appeared, then the TV went black and stayed
black. The SHIELD did not come back on USB. The "Fastboot" device still
listed was the stale enumeration from the flash. So Linux was running, or
hung, with no picture.

After the power cycle nothing was left to read:
- Android saw a cold boot.
- Its dropbox had no `SYSTEM_LAST_KMSG`.
- `/sys/fs/pstore` needs root.

So the kernel's log now comes back through the recovery slot:
- **Before the kernel starts**, in U-Boot's `board_quiesce_devices()`:
  - PMC_SCRATCH0 gets Android's "recovery" reboot reason.
  - Watchdog 0 is armed for `darcy_watchdog` seconds (150). It is paired
    with timer 5, as Linux's `tegra_wdt.c` does.
- **Any reset then lands in our U-Boot again:** darcy-init's reboot into
  recovery after a minute, a panic (`panic=10`), or the watchdog.
- **U-Boot shows the end of the kernel's log.** It finds the console zone
  where the FIT's device tree puts it and checks two things:
  - the zone's "DBGC" header
  - the `darcy.chain=u-boot` tag U-Boot adds to the command line, so
    Android's log is never shown

  It then prints the last 56 lines, empties the zone, and stops.
- **darcy-init reports into the kernel log** (`printk.devkmsg=on`):
  - whether a driver took over the framebuffer
  - at the end, the kernel messages that matter: errors, display,
    regulators, PMC, reserved memory

The next test proved the reboot-into-recovery path: Linux's
`reboot recovery`, the warm PSCI reset, cboot following the reboot reason,
and RAM keeping the log. The watchdog path has not been exercised yet.

### The first log: Linux runs, and the PMIC probe drops HDMI (2026-10-22)

*[Later: the PMIC wasn't the cause. The PMC switching off `pd_sor` was; see
"Milestone: mainline Linux keeps the HDMI console".]*

U-Boot showed the end of the log on the first try. It shows:
- **Linux 7.2.11 boots fully:** 4 CPUs, 2.9 GB (MemTotal 2949824 kB), and
  the eMMC (DG4016: mmcblk0, boot0/boot1, rpmb). darcy-init runs and reboots
  into recovery at 60 s.
- **The framebuffer handoff works:**
  - `framebuffer@92cc3000` is reserved `nomap`.
  - simpledrm takes the buffer at 1.41 s.
  - The console switches to it at 1.45 s (120x33).
- **PMC:** "access to PMC is restricted to TZ", and no SMC failures.
- **`regulator_ignore_unused` holds:** "Not disabling unused regulators" at
  33.8 s.

Yet the TV went black. Mainline's MAX77620 setup differs from the stock
darcy DT in exactly two places. Both are on the HDMI power path, and both
are applied when the PMIC probes, at about 1.8 s, just after the console
reached the TV:
- **PMIC GPIO1** enables `vdd-sys-boost`, the 5V boost behind HDMI 5V.
  - Mainline hands it to power sequencer 0 (`FPS_SRC_0`); stock keeps it
    out of the sequencer (`FPS_SRC_NONE`).
  - The pinctrl driver writes the source without any glitch protection.
  - In `fps-out` mode the sequencer, not the GPIO bit, then owns the pin.
- **sd2, `vdd-pre-reg`,** feeds the 1.05 V LDOs of the HDMI PHY (`ldo8`)
  and the display PLLs (`ldo7`).
  - Mainline sets 3.0–3.0 V, and the regulator core moves the rail into
    that range at probe. It logs "Bringing ..." when it does.
  - Stock allows 1.35–3.0 V.
  - Jetson TX1, Jetson Nano, Pixel C and NVIDIA's downstream e2174 PMIC
    file all use 1.35 V.

Every other rail, sequencer source and PMIC pin matches stock. Our DT now
keeps the stock values for both.

NVIDIA's downstream darcy power tree names the HDMI supplies
(`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:283-285`):

| Supply | Rail |
|---|---|
| `avdd_hdmi`, the HDMI PHY | ldo8, which sd2 feeds |
| `avdd_hdmi_pll` | sd3 |
| HDMI 5V | `vdd_hdmi` |

So the sd2 step lands directly on the HDMI PHY's supply.

n-codex, n-grok and Z.ai (opencode) reviewed this (`research/*hdmi-black*`):
- **n-codex and n-grok** rank GPIO1 first.
- **Z.ai** ranks sd2 first: sequencer 0 is clearly active, since the DDR rail
  runs on it, so GPIO1 should stay high when it is handed over.
- **All three** call the fix safe, and advise disabling `pmic@3c` for one
  boot only if HDMI is still black.

darcy-init now prints every regulator's voltage and state, and repeats
"Bringing" lines at the end of the log.

**Run 3, with the stock PMIC values: the TV still lost the signal.** The
user saw U-Boot's text, a flicker (the console taking over), then "No
signal" until the reboot. The log ruled the PMIC out as the only cause:
- `vdd-pre-reg` reads 1,350,000 µV with no "Bringing" line, so cboot runs
  sd2 at 1.35 V and Linux left it alone.
- All the HDMI supplies are on: `vdd-hdmi-dp` 1.05 V, `vdd-gen-pll-edp`
  1.05 V, `vdd-1v8` 1.8 V, `vdd-sys-boost` 5 V.

"No signal" means the HDMI link itself stopped, so something in the
display's clocks, resets, PLLs or power partitions changed. U-Boot and
darcy-init now print the same lines on each side of the handoff, so the
difference shows on one screen:
- the display blocks' clock-enable and reset bits
- PLL_D, PLL_D2 and PLL_DP
- the DISP1 and SOR1 clock sources
- display controller A's state

darcy-init adds three views from inside Linux:
- the PMC's powergates (read through the secure monitor)
- genpd's power domains
- the clock framework's view of the display clocks

**The cause, found in the source by the review round
(`research/*hdmi-link*`):** in this kernel, `tegra_powergate_add()`
(`drivers/soc/tegra/pmc.c:1361-1391`) powers down every DT powergate that
is on when the PMC driver probes (at 0.16 s). The point is that a driver
later powers it up from a known state. It does this by asserting the
resets, disabling the clocks, and switching the partition off through the
secure monitor. It then registers the domain as off.

`pd_ignore_unused` only skips a later pass, so it does not help. `pd_sor`
holds SOR1, the HDMI encoder cboot left running, so HDMI dies early in
every boot.

n-codex and n-grok found this independently, and antigravity and Z.ai
agree. The fix is in our DT: the `sor` node is deleted from the PMC's
powergates, along with all nine `power-domains = <&pd_sor>` references.
Marking the node `status = "disabled"` would not work:
`tegra_powergate_init()` walks the children with
`for_each_child_of_node_scoped`, which includes disabled nodes. Until tegra-drm drives HDMI, Linux
leaves that partition as cboot set it. The other partitions (audio, video,
XUSB and so on) are still powered down at probe, which is harmless.

That fix is the only change from run 3. U-Boot and darcy-init also print a
few extra values, on both sides:
- PLL_D2's MISC0
- the HDMI HPD and CEC pin words (parked bit 5)
- in U-Boot, the PMC's raw powergate status

If the picture still dies, these lines show what else changed.

### Milestone: mainline Linux keeps the HDMI console (2026-10-22, run 4)

The only change from run 3 was deleting the `sor` powergate. With it, the
TV kept the picture for the whole run:
- four penguins and the kernel log in TER16x32
- then darcy-init's report:
  - Linux 7.2.11, 4 CPUs
  - MemTotal 2949832 kB
  - eMMC DG4016 (boot0, boot1, rpmb)
  - `display: fb0 simpledrmdrmfb, DRM card0 simple-framebuffer`
  - every regulator as in run 3

After 60 s darcy-init rebooted into the recovery slot, and U-Boot showed the
log.

The boot chain is complete: cboot, then U-Boot from the recovery slot, then
mainline Linux with its console on HDMI. There is also a log channel back
through ramoops for every boot.

Before the next stages:
- **The watchdog.** U-Boot arms it before every kernel
  (`darcy_watchdog=150`). A real system must either set that to 0 or run a
  kernel watchdog driver, or the board resets after 150 s. The watchdog
  path itself is still unproven: darcy-init has always rebooted first.
- **`pd_sor`** comes back when tegra-drm drives HDMI.
- **`cpuidle.off=1`** can go once boots are routine.
- **The other PMC partitions** (audio, video, XUSB and so on) are powered
  down at probe. Their drivers power them up on demand.

**Next:** the device tree for USB (keyboard, storage) and Ethernet (PCIe
RTL8168), then Arch Linux ARM, then the GPU (tegra-drm and nouveau) for
Hyprland.

**The reference photo of that run** (U-Boot's log screen) adds the
following.

cboot's display setup:
- clocks (on/in reset): DISP1 1/0, HOST1X 1/0, SOR1 1/0, DPAUX1 1/0,
  SOR_SAFE 1/0; DISP2, DPAUX and SOR0 are in reset
- PLL_D2 `58281701` (misc0 `40000020`)
- DISP1 source `a0000000` and SOR1 source `a000c000`: parent 5 is
  `pll_d2_out0`
- PMC `PWRGATE_STATUS` `3ffec14d`: SOR (bit 17) and DIS (bit 18) are on.
  The secure-monitor reads return real values.
- HDMI HPD pin `00000164` and CEC pin `00000560`: both parked (bit 5).
  Linux unparks them at probe, and HDMI survives that.
- DC A: command `00000020`, which is C_DISPLAY

Linux's clock framework shows PLL_D2, DISP1 and SOR1 at 148.35 MHz, the
1080p59.94 pixel clock. PLL_DP is set to 270 MHz but off.

**A mainline bug turned up.** Reading `/sys/kernel/debug/powergate` oopses
in Linux 7.2.11 (NULL dereference at `0x31`, in `powergate_show+0x38`).
- `powergate_show()` in `drivers/soc/tegra/pmc.c` takes its
  `struct tegra_pmc *` from the show callback's `void *data`.
- Under `DEFINE_SHOW_ATTRIBUTE` that argument is `SEQ_START_TOKEN`,
  `(void *)1`. The PMC is in `s->private`.
- The fix is `struct tegra_pmc *pmc = s->private;`. It is a candidate to
  send upstream.

darcy-init no longer reads that file. The oops killed init, and the panic
proved the other return path: `panic=10`, then the reset, then U-Boot's
recovery reboot reason, then the log screen.

### Back to fastboot without Android (2026-10-22)

**`fastboot reboot recovery` does not work on cboot.** It answers `FAILED
(remote: 'unknown reason')` and reboots normally into Android, which then
restores its stock recovery. A new recovery image still needs one keypress
in the bootloader menu.

**Proof 1, Linux back to fastboot, works.** darcy-init's
`reboot bootloader` puts the box into the bootloader menu, with fastboot on
USB, and no Android is involved:
- The laptop keeps seeing cboot's fastboot connection the whole time U-Boot
  and Linux run.
- It disconnects at the reset and reconnects about 6 s later, in the menu.
- The same pattern explains run 4's disconnect at 11:10.

**The bootloader menu clears the ramoops RAM.** After going through the
menu, U-Boot found no log, and so booted Linux again. The crash path never
passes through the menu: it is the recovery reboot reason, straight to
U-Boot, and run 4's panic proved the log survives it.

So the dev loop is:
1. darcy-init reboots into **recovery**.
2. U-Boot shows the log, then after `darcy_log_secs` reboots into the menu.
3. The next image is flashed from there, without Android.

**Proof 2, the U-Boot fallback, works.** In the first image flashed
without Android:
- Linux rebooted into recovery at 13:04:48.
- U-Boot showed the log for 60 s.
- At 13:06:13 the board was back in the bootloader menu with fastboot.

**The known-good display reference** comes from the same run's photo,
where U-Boot reports cboot's state and darcy-init Linux's state:
- **Identical:** the display clocks and resets, PLL_D2 `58281701`
  (misc0 `40000020`), DISP1 src `a0000000`, SOR1 src `a000c000`, and DC A
  (command `00000020`, power `00050155`).
- **Different, and harmless:**
  - PLL_DP: `00041401` becomes `001c1c01` (the clock init table sets 270
    MHz; it stays off).
  - HDMI HPD/CEC pins: `164`/`560` become `144`/`540` (pinctrl clears the
    parked bit 5).

Other facts from that run:
- The eMMC is `DG4016 14.7 GiB`, with 33 partitions.
- `kvm: exiting hardware virtualization` shows the kernel runs at EL2.

Both ways back to fastboot are now proven. Before Android is removed,
one path is still unproven: **the watchdog**, for a Linux that hangs
silently. A panic already comes back by itself (`panic=10`).

### USB works, and so does the watchdog (2026-10-22)

The first USB image worked as written. darcy.dts enables the pad
controller and the xHCI host for the port near HDMI, with the stock wiring
and the supplies NVIDIA's power tree names. The xHCI microcode comes from
`linux-firmware` at a pinned commit. The photo shows:
- `tegra-xusb 70090000.usb: xHCI Host Controller` and `Host supports USB
  3.0 SuperSpeed`
- `usb 1-3: 046d:c34b USB Keyboard`, at low speed
- `input devices: "gpio-keys" "Logitech USB Keyboard" "Logitech USB
  Keyboard"`
- the XUSB host and SuperSpeed partitions on: genpd `xusbc on; xusba on`

The display state did not change.

**The watchdog works:**
- darcy-init froze on purpose.
- The watchdog U-Boot armed reset the board about 150 s after Linux
  started.
- Android then reported `ro.boot.bootreason = watchdog`.

**After a watchdog reset, cboot ignores the "recovery" reason** and boots
normally, which is Android today. Once U-Boot lives in the boot slot, a
normal boot starts U-Boot. U-Boot can then read cboot's
`androidboot.bootreason=watchdog` and go to fastboot instead of starting
Linux again, so a kernel that hangs every time cannot trap the box.

All four ways back are proven: Linux's `reboot bootloader`, U-Boot's
fallback after a log, a panic, and the watchdog.

### Wi-Fi and Ethernet work (2026-10-22)

The first image with both worked. The kernel builds `r8169`, `rfkill`,
`cfg80211` and `brcmfmac` in.

**Ethernet:**
- `pcieport 0000:00:02.0`: the RTL8168 is behind the **x1** root port
  (`pci@2,0`, lane `pcie-0`). The x4 port is empty.
- `r8169 0000:01:00.0 eth0: RTL8168g/8111g, 00:04:4b:xx:xx:xx, XID 4c0`.
  The MAC is the board's own (NVIDIA's OUI `00:04:4b`).
- `eth0` is down, with no cable.

**Wi-Fi:**
- `net wlan0: brcmfmac 00:90:4c:16:70:01`: `brcmfmac` booted NVIDIA's
  BCM4354 firmware with darcy's NVRAM and CLM blob.
- That MAC is the placeholder in `nvram_darcy_a00.txt`. The board's real
  Wi-Fi MAC still has to be found and passed on.
- `cfg80211: failed to load regulatory.db`. The fix is to add
  `regulatory.db` and `regulatory.db.p7s` from `wireless-regdb`
  (`linux-firmware` doesn't carry them).

USB, the display and the log loop are unchanged.

**Decision (2026-10-22): the root filesystem goes on the internal eMMC.**
*[Later the same day: a USB disk instead, so Android stays whole; see "The
installed system: design and build" and commit a33f734.]*
- **The goal** is a stripped-down media center, which fits in the 11–13
  GiB a reused `userdata` (plus `system`, `cache`) gives.
- **A USB SSD doesn't fit the hardware.** It would need a hub on the SHIELD:
  of its two USB-A ports, one is the A-to-A link to the laptop and the
  other the keyboard, and the user's hubs are USB-C.
- **The order matters:** Android goes only after Linux can reach fastboot by
  itself, through `reboot bootloader` and U-Boot's fallback.
- **The partition table and the bootloader partitions stay untouched.**

Media-center expectations with mainline:
- No T210 NVDEC support, so video is decoded on the CPU. 1080p H.264 is
  fine; HEVC/VP9 is borderline; 4K is not realistic. CPU DFLL scaling
  helps.
- HDMI audio (`hda-tegra`) and HDMI-CEC (`tegra-cec`, for the TV's remote)
  have mainline drivers.

**Open design question.** A Linux kept in the recovery slot is wiped whenever
Android boots. Options for the permanent install:
- Linux in `boot`, with Android given up or reachable some other way
- disabling `vendor_flash_recovery`, which needs a modified vendor partition
- a different chain

### Bluetooth: the UART needs an alias (2026-10-22)

The first Bluetooth image ran, but nobody photographed its report. The
chip's setup messages also come early enough to fall out of the last
highlights. So darcy-init now gives Bluetooth its own section: the
adapters, UARTD's driver, the serdev device `hci_bcm` binds to, probes
still deferred, and the Bluetooth kernel messages.

The second run shows:
- `bluetooth: no adapters`
- `bluetooth UART 70006300.serial: driver none`, and no serdev device
- `deferred probes: none`
- The Bluetooth core and the HCI UART protocols, Broadcom's among them,
  registered.
- `serial-tegra 70006300.serial: failed to get alias id, errno -19`

**The cause:** `serial-tegra` numbers each port by its `serialN` alias and
refuses a port without one. Darcy's mainline board file aliases only the
debug UART (`serial0`). Smaug and p2180 also have `serial3 = &uartd`, which
is `ttyTHS3`, the port Android uses. darcy.dts now adds it.

Also in this run:
- **`regulatory.db` loads now.** The "failed to load" lines are gone.
- **The RTL8168g PHY patch is still untested.** `r8169` loads it only when
  `eth0` is opened.

**The third run, with the alias: the chip answers.**
- `UART 70006300.serial: driver serial-tegra; serdev serial0-0: driver
  hci_uart_bcm`
- `hci0` exists, and the chip identifies itself at 115200 baud:
  `BCM4354 (003.001.012) build 0000`
- `BCM: firmware Patch file not found`. btbcm names chip subversion
  `0x610c` BCM4354 and looks for `brcm/BCM4354.hcd` (and the board-specific
  `brcm/BCM4354.nvidia,p2894-0050-a08.hcd`). We had installed the patch as
  `brcm/BCM4350C0.hcd`.

**The patch files say which chip they're for:**
- `bcm4350.hcd` names itself `BCM4354 37.4MHz Class 1.5 Nvidia-0438`. It is
  darcy's, and VENDOR_FIRMWARE now installs it as `brcm/BCM4354.hcd`.
- `bcm4356a3.hcd` is `BCM4356A3 37.4MHz Class 1.5 Nvidia mDarcy-0108`, the
  2019 SHIELD's.

**How Android does it.** Its Broadcom `libbt-vendor` finds the patch by
matching the chip's local name against the files in `/vendor/firmware`.
Neither partition has a `bt_vendor.conf` that names a file. It runs the UART
at 3 Mbaud (`set UART baud 3000000`).

**The UART speed.** `hci_bcm` switches to `max-speed` once the patch is in.
darcy.dts had smaug's 4 Mbaud, which UARTD's clock only reaches 1.9% slow
(PLLP's 408 MHz / 6.5). It now asks for 3 Mbaud, which comes out exact
(408 MHz / 8.5).

**Bluetooth works (the fourth run).**
- `BCM4354 'brcm/BCM4354.hcd' Patch` at 2.5 s. The download at 115200 baud
  takes about 7 s.
- Then, at 3 Mbaud: `BCM4354 37.4MHz Class 1.5 Nvidia-0438` (the patch sets
  that name; the ROM calls itself `BCM4350C0`) and `BCM4354 (003.001.012)
  build 1427`. No errors.
- The address showed as `-`. Debugfs's `identity` only exists once the
  kernel has initialised the adapter, and it skips that for an adapter
  without a valid address of its own ("unconfigured"). The report now asks
  the kernel directly (`HCIGETDEVINFO`, as `hciconfig` does) and says
  whether the adapter was initialised.

**USB, Ethernet, Wi-Fi and Bluetooth all have working drivers now.** Using
them (joining a network, pairing, a link on `eth0`) needs a real userspace,
so the root filesystem is next. The report now also lists the eMMC's
partitions as Linux reads them, which decides how Linux finds the root
filesystem.

### The installed system: design and build (2026-10-22)

**The boot.**
- **The system payload** (`scripts/12 --system`) uses `darcy-system.dts`:
  darcy.dts plus `root=PARTLABEL=UDA rootwait rw` and `/chosen/darcy,system`.
  The partition report confirms `UDA` (below).
- **Its initramfs holds only the firmware**, which the built-in drivers load
  before the root filesystem is up. With no `/init` in it, the kernel mounts
  `root=` itself and starts systemd.
- **Its ramoops keeps dump records for panics only** (`max-reason = <1>`).
- **U-Boot reads `darcy,system` from the FIT's device tree.** It boots the
  system again after a normal reboot. It shows the log and goes to fastboot
  only after a panic (a dump record in ramoops) or a watchdog reset (cboot's
  `androidboot.bootreason=watchdog`). The system's resets aren't pointed at
  the recovery slot, and showing a log empties the dump records too.
- **Linux's reboot reasons.** `reboot` clears PMC_SCRATCH0's mode bits
  (tegra-pmc's reboot notifier), and `reboot recovery` or `reboot bootloader`
  sets them. A panic restarts without the notifier, so the bits stay as
  U-Boot left them. That is how the test loop gets back to recovery.

**The watchdog.** Mainline's `tegra_wdt` matches only `nvidia,tegra30-timer`,
and darcy's timer node says `nvidia,tegra210-timer`. darcy.dts adds the
Tegra30 name: same registers, timer 5 driving WDT 0, as U-Boot arms it.
- The driver leaves a running watchdog alone until something opens
  `/dev/watchdog`. The clocksource driver doesn't mark the node populated, so
  the platform device exists.
- systemd opens it (`RuntimeWatchdogSec=60s`).
- U-Boot keeps arming it for the installed system too. The report could not
  show whether `tegra_wdt` bound, but a driver that failed to bind costs
  only a reset after 150 s, which ends in fastboot with the log (cboot's
  `bootreason=watchdog`), not a loop. Without the watchdog, a first boot
  that hangs would hang again on every power cycle, and no way into the
  bootloader by hand is documented here.
- `rootwait=30`: a missing root partition becomes a panic, and so a log, in
  30 s.

**The root filesystem** (`scripts/13`, about 5 minutes):
- **The base** is Arch Linux ARM's aarch64 image (signed 2026-08-05), built
  without root:
  - `unshare --map-auto --map-root-user`, plus QEMU's aarch64 binfmt with the
    `F` flag, so it works in the chroot
  - inside: `pacman-key`, `pacman -Rns linux-aarch64`, then `pacman -Syu` and
    the packages, with pacman's sandbox off under QEMU
  - the tmpfiles hook can't re-own the host's `/dev` nodes, which are visible
    in the chroot. That's harmless.
- **The base has no Wi-Fi client or BlueZ.** The build adds `iwd`, with DHCP
  by `systemd-networkd` as for Ethernet, and `bluez`.
- **`systemd-firstboot` would ask for a timezone on the TV.** The image has
  an empty `machine-id` and no `/etc/localtime`. The build host's timezone
  and `KEYMAP=us` go in.
- **Arch's linux-firmware is zstd-compressed,** hence
  `CONFIG_FW_LOADER_COMPRESS_ZSTD`. It also ships Broadcom's generic
  `brcmfmac4354-sdio.bin`. NVIDIA's files go in under board-specific names,
  which `brcmfmac` and `btbcm` try first:
  `<name>.nvidia,p2894-0050-a08.<ext>`.
- **The kernel now builds its 949 modules too,** plus `uhid` for Bluetooth
  LE keyboards and remotes.
- **The result** is 2.8 GB of ext4 (label `darcy-root`), 1.7 GB as a sparse
  image. It grows to fill its partition on the first boot
  (`x-systemd.growfs`). debugfs shows the setuid bits and group ownerships
  survived.

**The partition report** (the new kernel and U-Boot, through the test loop):
- **Linux reads the eMMC's GPT:** `mmcblk0`, 14.7 GiB, 33 partitions. They
  are BPF, TBC, TBC-B, EBT, RBL, **NCT**, WB0, DFI, RP1, RP2, TOS, EKS, UKS,
  FB, BMP, SOS (recovery), DTB, LNX (boot), APP (system, 2048M), CAC (cache),
  vendor (768M), MSC, USP, MDA, RP3, RP4, FCT, UCB, RP5–RP8, and **p33 UDA
  11630M** (userdata). `root=PARTLABEL=UDA` is right.
- **A USB hub on the port near HDMI works at both speeds:** a Genesys Logic
  hub (`05e3:0610`, and `05e3:0620` on `usb 2-2 … SuperSpeed`). So the USB 3
  lane (`usb3-1`, UPHY `pcie-5`) works too.
- **Bluetooth's address is a placeholder:** `43:50:C0:00:1F:AC` ("4350C0"
  plus a default suffix). btbcm doesn't list it as a default, yet the
  adapter wasn't initialised: debugfs has no `features`. That's to be looked
  at on the installed system, with BlueZ and the full log.
- **The real Bluetooth and Wi-Fi addresses** are probably in `NCT`, NVIDIA's
  config table. The Wi-Fi MAC (`00:90:4c:16:70:01`) is the NVRAM file's
  placeholder.

**Decision (2026-10-22): the OS goes on the user's external NVMe SSD,** in
a USB enclosure on the hub, so Android's partitions stay as they are. The
hub on the port near HDMI makes room for both the keyboard and the disk.
- `config.sh` `SYSTEM_ROOT=PARTLABEL=darcy-root`, which `scripts/12`
  substitutes into `darcy-system.dts`. `PARTLABEL=UDA` remains the eMMC
  option.
- `scripts/15` writes the disk on the laptop, because fastboot only writes
  the eMMC: one GPT partition named `darcy-root` (the arm64 root type), the
  ext4 image `dd`'d in, then `e2fsck` and `resize2fs` to fill it.
  - It takes only a whole, unmounted USB disk, and the user types its name.
  - It needs root. This laptop runs no polkit agent, so `pkexec` can't ask
    for a password, and `sudo` can't prompt without a terminal: the user
    runs it.
- `scripts/14` then writes only the boot partition. `--restore` puts
  NVIDIA's `boot.img` back, and with it Android, data intact.
- The disk has to come up behind the hub at boot: `rootwait=30`, and the
  enclosure's power must hold through the hub.

**The SSD on the SHIELD.** Two report runs showed the hub (Genesys
`05e3:0610`/`0620`) and the keyboard, but nothing for the SSD: no device, no
enumeration error, `usb over-currents: none` even with the hub powered. The
enclosure's cable carried power but no data. With another cable:
- `usb 1-3.1: 152d:581d SSK Storage`, a JMicron NVMe bridge ("SSK
  PCIe581"), on `usb-storage`. `CONFIG_USB_UAS` is off, so it's
  bulk-only.
- `sda`, 500118192 sectors of 512 bytes (256 GB), attached 10.2 s after
  the kernel started, well inside `rootwait=30`
- **It runs at USB 2 speed:** `new high-speed USB device` on the hub's
  USB 2 side (`1-3.1`). The working cable is probably USB 2 only. A USB 3
  cable would put it on `2-2.x` at SuperSpeed.

**The install, on the eMMC instead** (`scripts/14` with `PARTLABEL=UDA`),
writes `userdata` and `boot`. Android must then never start again while
Linux is on `userdata`: its file-based encryption would fail there and it
would offer a wipe, and `vendor_flash_recovery` would put its recovery back.
The recovery slot keeps the test payload, for reports.

### The first boot of the installed system (2026-10-22)

The evidence is the system's own journal, read from the SSD on the laptop
(`journalctl -D …/var/log/journal -b <boot id>`; relative `-b -1` finds
nothing with `-D` here).
- **It boots completely from the SSD:** `Startup finished in 10.690s
  (kernel) + 13.309s (userspace)`. `wlan0` came up; no network was
  configured.
- **The watchdog hand-over works:** `tegra-wdt 60005000.timer: initialized`
  and `systemd: Using hardware watchdog /dev/watchdog0: 'Tegra Watchdog'`
  (1 min).
- **The TV went dark about 3 s into userspace.** udev loaded `tegra-drm`,
  which removes every conflicting framebuffer
  (`aperture_remove_all_conflicting_devices`, `drivers/gpu/drm/tegra/drm.c`),
  including the simple framebuffer the console was on. It then found nothing
  to drive: `Cannot find any crtc or sizes`. The report payloads never load
  modules, so they never showed this. The system's command line now has
  `module_blacklist=tegra_drm` until HDMI through tegra-drm works.
- **Asking the user to type blind was a mistake.** `agetty` rejected two
  login names (`checkname failed`, meaning longer than 42 characters or
  starting with `-`, so not `root`), and nothing ran. Get evidence first.
- **The clock is wrong.** The journal's dates read 2026-10-18: no RTC time,
  and no network time yet.
- **The first boot's log ends with `usb 1-3.1: reset high-speed USB device`**
  (the SSD), around when the power was pulled. Watch for it.

**Step 2 works (2026-10-22):**
- **The way back to the menu works end to end for the installed system.**
  Powered on without the SSD: the kernel waited 30 s (`rootwait=30`) and
  panicked. U-Boot found the panic's dump record, showed the log, and
  rebooted into the bootloader menu by itself.
- **The screen fix works.** With the boot image carrying
  `module_blacklist=tegra_drm`, the picture stays on through boot, all the
  way to the `darcy login:` prompt.
- **Next is step 3 (Wi-Fi):** the new kernel with iwd's crypto and the
  country, plus its matching modules on the SSD (`scripts/16`).

**Milestone: step 3 works, Wi-Fi and SSH (2026-10-22).**
- **The clean route to the menu works:** `systemctl
  --reboot-argument=bootloader reboot` from the console.
- **`scripts/16` refreshed the SSD's modules in place.** Checked read-only
  afterwards: all six newly built-in crypto pieces are in `modules.builtin`,
  the old `md5.ko` is gone, there are 943 module files, owned by root, and
  the file list matches the staged build.
- **Wi-Fi:** `iwctl station wlan0 connect "<SSID>"` joined at once:
  WPA2-Personal on **5 GHz, channel 48**, −69 dBm, RX 270 Mbit/s. DHCP from
  systemd-networkd gave `192.168.1.122`. 5 GHz means the firmware took the
  country: the `brcm,ccode-map` passed `US` on, where the NVRAM's `XV`
  could leave 5 GHz out.
- **SSH works from the laptop as root with `device-info/ssh/id_ed25519`**
  (the host key is in `device-info/ssh/known_hosts`). Work no longer
  depends on photos of the TV.
- **Checked over SSH:**
  - `Module tegra_drm is blacklisted`, once for each load the device manager
    tried
  - `systemctl --failed` is empty
  - systemd holds `/dev/watchdog0` ('Tegra Watchdog')
  - `/` is 235 GB, 1.7 GB used
  - timesyncd set the clock
- **Bluetooth:** `btmgmt info` shows `hci0` powered, br/edr + le, and
  configured, with no missing options. The address is the chip's
  placeholder, `43:50:C0:00:1F:AC`.
- **Ethernet** is `enp1s0` (r8169, `00:04:4b:xx:xx:xx`), up, with no cable.
- **Open:**
  - the board's real Wi-Fi and Bluetooth addresses, probably in `NCT`
  - pairing a Bluetooth keyboard
  - quieting the kernel messages on the console (`ignore_loglevel`)
  - the root password, still Arch Linux ARM's default `root`; SSH is
    key-only (locked since B9, by `scripts/22`)
  - a USB 3 cable for the SSD
  - HDMI through tegra-drm for the desktop

### Quiet console, the board's addresses, updates over the network (2026-10-22)

**The console is quiet once the system is up.**
- The installed system's command line drops `ignore_loglevel`, and
  `/etc/sysctl.d/20-quiet-console.conf` (`scripts/13`) sets
  `kernel.printk = 3 4 1 7` when systemd-sysctl runs. The boot still shows
  on the TV up to that point.
- Checked over SSH: `/proc/cmdline` has no `ignore_loglevel`, and
  `/proc/sys/kernel/printk` reads `3 4 1 7`.
- **What it costs:** the level applies to every console, ramoops' included.
  `printk_get_next_message()` drops a record below it for all of them; only
  sysrq output is forced through (`LOG_FORCE_CON`). U-Boot's log screen
  shows that console record (`report_last_log()`).
  - Oopses and panics still come out in full: arm64's `die()` and `panic()`
    call `console_verbose()`.
  - After a **hang** (a watchdog reset), the screen would show the end of
    the boot, not what came before the hang.
  - For debugging, over SSH:
    `echo Y > /sys/module/printk/parameters/ignore_loglevel` puts everything
    back on the consoles until the next boot.

**This SHIELD's NCT holds no Wi-Fi or Bluetooth address.** It was read over
SSH from `mmcblk0p6` (2 MiB, magic `nVCt`):
- Entries start at `0x4000`, `0x410` bytes each: a 32-bit index, then the
  data at +12.
- Present: the serial number (entry 0); entries 3, 5 and 39, all zeros;
  8, the board info (starting `0x0b4e`, 2894); 42, a JSON config; and 43,
  `gpu-dvfs-rework:…`. The two entries after the serial number are empty,
  and the backup table at `0x104000` holds nothing.
- Android's properties carry no address either (`device-info/getprop.txt`).
- So the placeholders stay: Wi-Fi `00:90:4c:16:70:01` (the NVRAM file's)
  and Bluetooth `43:50:C0:00:1F:AC`. That's fine for one SHIELD. Two on one
  network would clash, and would each need a locally administered address
  (not done).

**`scripts/17` updates a running system without touching the TV.** It worked
on its first run, modules included, in 1 min 30 s.
- It copies the kernel's modules over SSH when the build's kernel isn't the
  one running, or with `--modules`. They're unpacked beside the old tree,
  then swapped in.
- Then it runs `systemctl --reboot-argument=bootloader reboot`, `scripts/14`
  the moment fastboot appears on USB, and `fastboot reboot`.
- It checks that the build's kernel runs: `uname -rv` against the build's
  `UTS_VERSION`.

**The bootloader findings behind it:**
- **The menu Linux reboots into doesn't always wait.**
  - At 20:11 it answered fastboot 8.5 s after the reset, then went on into
    the boot partition within about 15–18 s. There was no reset (no USB
    disconnect), so it went on the way "Continue" does.
  - Proof 1's first menu (13:00:09) didn't stay either: a reset followed at
    13:01:34.
  - The menu U-Boot's log screen reboots into has waited for minutes (19:58,
    flashed 111 s later).
  - The cause isn't known. U-Boot sets the same `PMC_SCRATCH0` bit
    (`BIT(30)`) as Linux, and no keypress is known of. Flashing at once
    works.
- **`fastboot reboot` works despite its answer.** cboot replies
  `FAILED (remote: 'unknown reason')`, the USB device drops 0.2 s later,
  and the normal boot follows.
- **The printk clock doesn't count from the reset.** The first kernel line
  reads about 13 s whether or not the boot sat in the menu, so it says
  nothing about the time spent there.

**Wi-Fi took 2.4 GHz this boot**: channel 9 at −54 dBm, over the same
network's 5 GHz access point (channel 48, −69 dBm). iwd ranks by signal; 5 GHz still works,
and the scan heard 10 networks there. `[Rank] BandModifier5GHz` in
`/etc/iwd/main.conf` (iwd 3.12) would favour 5 GHz. It's left as is.

### HDMI through tegra-drm (2026-10-22)

**The evidence first: cboot's live SOR1 state.** It was read over SSH with
`tools/mmio-read.c` (an mmap of `/dev/mem`; `read()` isn't safe on device
memory). SOR1 was checked clocked and out of reset first: the clock and
reset controller's `CLK_OUT_ENB_X` bit 23 set, `RST_DEVICES_X` bit 23
clear.

| SOR1 register | cboot | mainline, 150 MHz entry (`sor.c:92`) | under tegra-drm |
|---|---|---|---|
| head timing (`0x07`) | `0x04650898`, 2200×1125 | | the same |
| PLL0 (`0x17`): ichpmp, vcocap | 1, 3 | 1, 3 | the same |
| PLL1 (`0x18`): loadadj, termadj | 3, 9 | 3, 9 | the same |
| PLL3 (`0x1a`): bg temp, bg vref, avdd14, avdd10 | 3, 8, 4, 4 | 3, 8, 4, 4 | the same |
| XBAR_CTRL (`0x4a`) | `0x8d111828` | default {2,1,0,3,4} | `0x8d111828` |
| LANE_DRIVE_CURRENT0 (`0x4e`) | `0x2d303030` | {0x33,0x3a,0x3a,0x3a} | `0x3a3a3a33` |
| pre-emphasis (`0x52`), TX_PU (`0x5c`) | 0, `0x66` | 0, `0x66` | the same |
| INPUT_CONTROL (`0xe8`) | `0x2`, limited-range RGB | | 0, full range |

- **No `nvidia,xbar-cfg`:** the crossbar cboot programs is exactly what
  mainline writes from its Tegra210 default (`sor.c:2389`).
- **cboot's drive current is stock darcy's prod** for 54–300 MHz
  (`tegra210-darcy-prods.dtsi`). Mainline doesn't read prods; its table is
  Jetson TX1's.
- **GPIO port CC:** CC1 (hot-plug) is an input reading low with the TV
  connected (active low). CC7 (HDMI 5V) is an output driven high.

**The device tree** (`darcy.dts`) is Jetson TX1's recipe, and the stock
darcy DT wires it the same way:
- DPAUX1 on (its pads carry the DDC bus)
- SOR1 with ldo8 / sd3 / `vdd_hdmi`, DDC on I2C4, hot-plug on CC1 active
  low
- `hdmi_ddc: i2c@7000c700` at 100 kHz
- `vdd_hdmi` no longer disabled, and always on

**Kept off at boot until proven:**
- `module_blacklist=tegra_drm` is gone from the command line: it refuses a
  manual load too.
- The root filesystem's `/etc/modprobe.d/20-darcy-tegra-drm.conf` has
  `blacklist tegra_drm` and `install tegra_drm /bin/true`.
  - The blacklist alone stopped udev's device loads: the kernel's
    refusals per boot went from 11 to 1.
  - What was left is host1x's soft dependency, `softdep host1x post:
    tegra-drm`. `modprobe -b --show-depends host1x` still listed
    `tegra-drm.ko`. With `install` it shows `/bin/true`, and the next boot
    had 0 attempts.
  - By hand: `modprobe --ignore-install tegra_drm`.
- At boot, I2C4 waits ("wait for supplier .../dpaux@54040000/pinmux-off"):
  with modules enabled, a missing pin controller is `-EPROBE_DEFER` with no
  timeout (`drivers/pinctrl/devicetree.c`).

**The reviews** are in `research/*hdmi-drm*`. Z.ai was at its usage limit.
- **All three:** the recipe is right, with no crossbar override, and
  mainline's drive current is fine for a first picture.
- **n-codex:** the SOR enable path has two unbounded waits
  (`sor.c:2322-2340`). The watchdog doesn't cover them while systemd still
  runs, hence a sysrq reboot timer during the test. Also `vdd_hdmi` always
  on, so that a failed SOR probe can't cut the TV's 5V.
- **n-grok:** the DC and SOR probes reset cboot's display at load
  (`dc.c:3316-3344`, `sor.c:3940`). The DRM device waits for every host1x
  engine (`host1x/bus.c:125`, `drm.c:1379-1385`). The first boot's journal
  shows DC, VIC, NVDEC and NVJPG already probing on darcy: "Initialized
  tegra 1.0.0", then "Cannot find any crtc".
- **Corrected:**
  - n-grok said no SMC write to the PMC had been seen. The reboot reason
    (`PMC_SCRATCH0`), XUSB's powergates and PCIe's IO pads (`IO_DPD_REQ`,
    the HDMI pad's register) all go through it, and no kept boot logs "SMC
    failed".
  - antigravity said `vdd_hdmi` would be switched off 30 s after boot for
    want of `regulator_ignore_unused`. That's on the command line ("Not
    disabling unused regulators"), and stock darcy has no startup delay on
    `vdd_hdmi`.
- **Missed by all three:** host1x's soft dependency (above).

**The first load works.** Over SSH, with a 3-minute sysrq reboot armed and
`ignore_loglevel` on, `modprobe --ignore-install tegra_drm` finished in a
quarter of a second:
- "Initialized tegra 1.0.0 for drm on minor 1". The console moved to
  `tegradrmfb` (120x33).
- HDMI-A-1 connected. The EDID (256 bytes) came over I2C4: "LG FHD"
  (GSM 23766), modes up to 1920x1080.
- CRTC 0 active at 1920x1080@60, 148.5 MHz, 2200×1125 (the CEA timing).
- No warnings, and no memory-controller or SMMU faults.

**On the TV:** the user logged in on the console with no visible problem
with the picture. A black-and-white text console can't show the colour
range, though; that waits for a desktop.

**Milestone: tegra-drm drives HDMI from boot (2026-10-22).** The
modprobe.d file is gone from the SSD and from `scripts/13`, so udev loads
tegra-drm at boot:
- simpledrm takes cboot's framebuffer at 13.17 s. tegra-drm takes over at
  15.67–15.84 s, with 0.16 s on the dummy console in between.
- fb0 is `tegradrmfb`, HDMI-A-1 is connected and on, nothing is left
  deferred (I2C4 bound once DPAUX1 loaded), and no unit failed.
- The user: "screen looks normal after boot".

**Open:**
- the colour range: full-range RGB, where cboot sent limited range
- darcy's drive current, if a picture ever shows sparkles
- 4K and HDMI 2.0 scrambling: this TV ("LG FHD") stops at 1080p
- the GPU (nouveau), for a desktop

### pacman on the SHIELD needs Landlock (2026-10-22)

pacman couldn't download anything on the installed system:
- "restricting filesystem access failed because Landlock is not supported
  by the kernel!", then "switching to sandbox user 'alpm' failed!".
- pacman 7 downloads in a sandbox that confines itself with Landlock.
  `scripts/13` never hit this: it turns the sandbox off while pacman runs
  under QEMU.

`kernel/darcy.config` now has `CONFIG_SECURITY_LANDLOCK=y`. The default
`CONFIG_LSM` list already starts with `landlock`, and seccomp was already
on. With kernel #7 (modules swapped in by `scripts/17`):
- `/sys/kernel/security/lsm` reads `capability,landlock`.
- `pacman -Sy` works, and Mesa 26.2.5 downloads.

That Mesa has what the GPU step needs: `tegra_dri.so` (render-only,
tegra-drm's display with nouveau's rendering), `nouveau_dri.so` and GBM.
`vulkan-nouveau` is a separate package.

### The GPU (GM20B): the evidence (2026-10-22)

**Mainline's recipe:** the GPU node is in `tegra210.dtsi:440-457`
(`nvidia,gm20b`, no power domain, disabled). Jetson TX1 and Nano enable it
with `vdd-supply = <&vdd_gpu>`. That's a `pwm-regulator` on PWM channel 1
(8 µs period), 710–1320 mV, switched by PMIC GPIO 6
(`tegra210-p2180.dtsi:426-436`, `tegra210-p3450-0000.dts:1858-1870`).
Mainline's darcy files have no GPU and no GPU rail.

**darcy's rail is the same circuit:** stock `gpu_ovr_reg`
(`tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`, included by
darcy's power tree) has the same PWM channel, period, range, enable GPIO
and delays. Nothing in darcy's chain overrides it, and the alternative I2C
GPU regulator is disabled.
- Polarity can't be measured: darcy's INA3221 watches main-board input,
  SoC and CPU, not the GPU.
- The family's CPU rail, the same kind of circuit, maps duty step 0 to
  708 mV, rising to 1322.4 mV.

**Live state, read-only:**
- **The GPU is off,** as cboot leaves it:
  - clock off
  - PMIC GPIO 6 (`CNFG_GPIO6` `0x03`) an input reading low
  - PWM channel 1 disabled
  - `GPU_RG_CNTRL` `0x1` (clamped)
- **The PWM controller is clocked.** Its channel 0 runs the lightbar LED
  (stock `pwm-leds`), and channel 3 is a fan this model doesn't have.
  *[Wrong: darcy has a fan on channel 3; see "The SHIELD overheated and
  powered off".]*
- **The GPU's PWM pin is not muxed for it.** `lcd_gpio2_pv4` (`0x7000320c`)
  reads function 0, DISPLAYB.
  - Stock darcy muxes it to `pwm1` in its `default` pinmux, which Android's
    kernel applies.
  - Mainline's p2894 has `pwm1` only in the `boot` state, which Linux never
    applies.
  - Without the mux, the duty cycle never reaches the regulator.
- **Silicon:** Tegra210 A02, SKU 135 (Jetson TX1's revision). The GM20B
  firmware is on the SSD (`linux-firmware-nvidia`).

**The PMC register nouveau adds:** on Tegra210, removing the GPU's clamps
writes 0 to `GPU_RG_CNTRL` (`0x2d4`, `pmc.c:725-726`), an offset not used
through the secure monitor before.
- `tools/pmc-read` (a module that makes the PMC driver's SMC read and
  unloads itself) got status 0 there, value `0x1`.
- `PWRGATE_STATUS` (`0x3156cf09`) shows DISB off, which tegra-drm's DC B
  probe switched off through the monitor (cboot had it on).
- TF-A's PMC handler filters offsets for reads and writes alike, so the
  write is very likely accepted too.

### The GPU: the first register read needs the fuse clock (2026-10-22)

**The change in `darcy.dts`** (reviewed by n-codex, n-grok and antigravity,
`research/*gpu-review*`):
- the `pwm` controller, with a default pin state muxing `lcd_gpio2_pv4` to
  `pwm1`
- `vdd_gpu`, Jetson TX1's pwm-regulator node (PWM channel 1, 710–1320 mV,
  PMIC GPIO 6)
- the GPU node with `vdd-supply`
- the root filesystem blocks nouveau at boot (`blacklist` plus
  `install nouveau /bin/true`)

Before the test, the state was as planned: `pwm-tegra` bound, the pin on
PWM1, `vdd-gpu` registered and off, GPIO 6 an output driven low.

**`modprobe --ignore-install nouveau` froze the board** before nouveau
printed a line. The 60 s watchdog reset it, and U-Boot showed the log and
went to the bootloader menu. The kernel log, streamed to the laptop, ended
at the test's marker.

**`tools/gpu-power-probe`** repeats nouveau's power-up a step at a time,
logging and pausing between steps:
- the rail on
- the gpu, ref and pwr clocks
- the reset asserted
- the clamps removed through the secure monitor (`GPU_RG_CNTRL` 1 → 0:
  the monitor takes the write)
- the reset released
- the first register read

The first five steps pass. The read of `BOOT_1` stalled the bus at 710 mV,
and again at 1.0 V (`PWM_CSR_1` `0x807b0000`, regulator 1002800 µV).
Recovery took 2½ min, which is the watchdog path, not a panic.

**Ruled out by measurement:**
- **A rail that doesn't come up:** PMIC GPIO 6 reads `0x09` (high) by
  direct I2C, and darcy's INA3221 (now in `darcy.dts`, on I2C2, whose pins
  cboot leaves muxed) shows VDD_SYS (18.9 V input) going 348 → 389 mA as
  the rail turns on (+0.77 W).
- **A MAX77621 instead of the PWM regulator:** nothing answers at `0x1c`.
- **The memory controller's hot reset:** the GPU's request bit is 0. Its
  status bit goes 1 → 0 as the GPU comes up, the interface waking.
- **Clock and reset:** CAR bank X bit 24 enabled, reset released, at
  step 5.

**NVIDIA's own sequence works.** nvgpu's `gm20b_tegra_unrailgate()`
(L4T r32, `platform_gk20a_tegra.c`) differs from nouveau's in three ways:
- the SoC **fuse clock** is on (its `clk[3]`)
- the reset is released with the gpu gate clock stopped
- the GPU's MC client is flushed and released

With all three in the probe module, `BOOT_0` read `0x12b000a1` (GM20B).
With **only the fuse clock**, it read the same. The fuse clock is gated
otherwise: the fuse driver turns it on only around its own reads (runtime
PM, `fuse-tegra.c:259-276`).

**Upstream knows** (found by n-codex): a v2 series on dri-devel (October
2026) reports the same failure on Jetson TX1 (garbage `BOOT_0`, stalled
first reads). It adds the fuse clock to the Tegra210 GPU node and has
nouveau keep it on while the GPU is powered. One TX1 that failed on every
boot passed 38 of 40. It is posted, not merged: not in 7.2.11.

**Also measured:** the board draws 6.6 W at idle (348 mA × 18.9 V), at
88 °C CPU, 87 °C GPU and 89.5 °C memory. cpufreq doesn't probe, and the
command line has `cpuidle.off=1`. That's to be looked at.

**Milestone: nouveau loads (2026-10-22).**
`patches/linux/0001-drm-nouveau-tegra-keep-the-fuse-clock-on-while-the-G.patch`
follows the upstream series' design:
- an optional `fuse` clock
- enabled before the rail goes on, disabled after it goes off

`darcy.dts` gives the GPU node `TEGRA210_CLK_FUSE` as `fuse`. `scripts/11`
now resets `vendor/linux` to the pinned commit and applies
`patches/linux/`, as `scripts/05` does for U-Boot.

`modprobe --ignore-install nouveau` over SSH, with the rollback armed:
- `NVIDIA GM20B (12b000a1)`, `imem: using IOMMU`, `VRAM: 0 MiB`
- `[drm] Initialized nouveau 1.4.2 for 57000000.gpu on minor 0`
- card0 (nouveau), card1 (tegra) and two render nodes
- nouveau set the rail to its floor: `vdd-gpu` at 838100 µV (`PWM_CSR_1`
  `0x80360000`, 54/256 of 710–1320 mV)
- nothing more in the log, and the board stays up

The applied patch makes the release string `7.2.11-ga2de78ee6ed8-dirty`.
`scripts/17` copies the modules under that name. Out-of-tree modules
(`tools/`) must be rebuilt against it.

Then Mesa (26.2.5) gave OpenGL 4.3 and OpenGL ES 3.2 on `NV12B` (the GM20B),
through both the surfaceless and the GBM platforms. `glmark2-es2-drm`
couldn't find "the main graphic card" among two DRM devices.

### The SHIELD overheated and powered off (2026-10-22)

**About 1.5 h up**, with nouveau loaded, Mesa installed and a compile
starting, the board switched itself off: TV dark, LEDs off, the case "really
hot" (the user). The last readings, 2 min before, were 92.5 °C CPU,
88.5 °C GPU, 93.5 °C memory, still rising. Unplugged and plugged back in, it
booted normally.

**What switched it off is not on record.** That boot's journal ends in the
middle of the SSH session, with no shutdown and no thermal line: the last
minutes never reached the SSD. cboot hadn't armed the PMC's thermal reset
(`PMC_SENSOR_CTRL` `0x1b0` and SCRATCH53–55 read 0 through the secure
monitor), so most likely Linux's critical trip (102.5 °C) powered it off. A
power-off latches the board off until it is unplugged.

**Why it runs hot: our system has no CPU power management yet.**
- `cpuidle.off=1`, a precaution from the first boots (commit 371a6dc), so
  idle CPUs never enter C7. The boot log says "failed to register cpuidle
  driver".
- No DFLL (`clock@70110000`, disabled in mainline's darcy files), so
  `cpufreq-tegra124` fails with -2. `cclk_g` stays on `pll_x` at cboot's
  1017.6 MHz. The DFLL's PWM pin (`dvfs_pwm_pbb1`, `0x11`: CLDVFS,
  tristated) leaves the CPU rail at its tristate level: 1.0 V by stock's
  `pwm-tristate-microvolts`.
- The board draws 6.0–6.35 W idle (INA3221, 18.9 V input) and climbs from
  about 65 °C at boot to 83–89 °C at idle. That is passive cooling with no
  fan: antigravity is checking the stock DT on that.
- Stock darcy's DFLL (`tegra210-p2530-common.dtsi:54-72`) matches Jetson
  Nano's mainline PWM-mode DFLL (`tegra210-p3450-0000.dts:594-613`) value
  for value, plus two downstream-only flags.

**A mainline regression made it worse: no hardware throttling before
shutdown.**
- `tegra_soctherm_set_hwtrips()` programs the throttle with the shutdown
  temperature ("throttrip: will throttle when cpu reaches 102500 mC").
  Since commit 5136f99b9a4a (2024-08-01, "Use thermal_zone_for_each_trip()
  for walking trip points"), it looks up the hot trip but uses the critical
  temperature. Upstream mainline still has it (checked 2026-10-22).
- `patches/linux/0002` throttles at the hot trip's temperature again, as
  before that commit: now "throttle when cpu reaches 98500 mC", gpu 100000.
  It is a candidate to send upstream.
- `tegra-soctherm` is a module, so the fix left the kernel's build stamp as
  it was. `scripts/17` then skipped the modules. It now compares the
  modules by a hash, which the SHIELD keeps in `.darcy-modules-hash`.

**The main cause: darcy has a fan, and nothing ran it.** n-codex pointed at
stock darcy's `pwm-fan` (`tegra210-darcy-pwm-fan.dtsi`): PWM channel 3 on
`pe7`, a 65536 ns period, 5V from `vdd_fan` (GPIO E4), the tachometer on
GPIO G0. AFTVnews' teardown of the 2nd-gen SHIELD TV shows the fan too.
- **Under our Linux the fan never ran.** E4 wasn't in GPIO mode (supply
  off), `pe7` was on RSVD0, PWM channel 3 was disabled, and `darcy.dts`
  even kept `vdd_fan` disabled.
- **Measured with `gpioset`/`gpiomon`** (libgpiod), E4 high and the PWM
  pin driven as a GPIO:
  - PWM pin **low**: 1103 tachometer edges in 3 s and +0.63 W. The user
    heard the fan.
  - PWM pin high: 0 edges.
  - So the fan's PWM input is **inverted**.
- **`darcy.dts` now has the fan:**
  - `pe7` → `pwm3` in the PWM controller's default pin state
  - `vdd_fan` enabled
  - a `pwm-fan` node with `cooling-levels = <255 190 145 125 96 16 1>`.
    Linux's Tegra PWM has no inverted polarity, so the levels count down:
    255 stops the fan, then stock's "cool" profile, then full. The top is 1,
    not 0, because pwm-fan turns the PWM off for 0.
  - the tachometer as an interrupt
  - active trips on `cpu-thermal` at 45/55/65/75/85/95 °C for levels 1–6
- **Result:** pwm-fan binds and the fan settles at level 1 (25%, about
  2375 RPM). Idle, at 2–4 min, the CPU went from 47 to 43 °C and memory
  from 50 to 45 °C, against 67–72 °C without the fan. Power dropped from
  6.0–6.35 W to about 5.0 W.

**Still to do, now without the urgency:** the CPU's power management
(reviews in `research/`):
1. drop `cpuidle.off=1`
2. the DFLL in PWM mode, capped (mainline allows 2.2185 GHz for CPU speedo
   2; stock darcy stops at 2.0145 GHz)
3. passive cooling through cpufreq

### CPU power management (2026-10-23)

**The plan, reviewed by n-codex** (`research/plan2-brief.md`,
`research/ncodex-plan2-review.md`), one change per boot, each measured with
`tools/power-status.sh`:
1. CPU idle on
2. a thermal guard in userspace (cap the CPU at 86 °C, warm reboot at
   92 °C)
3. the DFLL capped at 1.020 GHz
4. passive cooling through cpufreq
5. only then the DFLL's cap at stock's 2.0145 GHz

**This chip's speedo.** Speedo revision 4, so the fuse is the value itself:
CPU speedo value 2041 (`FUSE_CPU_SPEEDO_0` = `0x7f9`), CPU process 0, GPU
speedo value 2056, SoC 1925. SKU `0x87` makes it CPU speedo ID 2, and the
DFLL driver's table for that is `speedo_id = 2, process_id = 0`
(`clk-tegra124-dfll-fcpu.c:515-524`), 870–1227 mV. With the PWM rail's
708 mV + n × 19.2 mV steps (`cvb.c`'s arithmetic):

| CPU | 204–918 MHz | 1020 | 1224 | 1428 | 1632 | 1836 | 1912.5–2218.5 |
|---|---|---|---|---|---|---|---|
| OPP voltage (mV) | 880 (the floor) | 919 | 976 | 1053 | 1130 | 1207 | 1226 (the ceiling) |

Today the CPU runs at 1017.6 MHz on 1.0 V, above what 1020 MHz needs. The
DFLL's closed loop runs the CPU from an oscillator on the CPU rail itself,
so a voltage that falls short slows the clock rather than breaking timing.
Below 918 MHz it skips clock pulses at 880 mV.

**1. CPU idle is on** (`cpuidle.off=1` dropped from `darcy-system.dts`):
- `psci_idle` with the menu governor; each core enters `cpu-sleep`
  (PSCI `0x40000007`, C7) and is asleep 99% of an idle minute.
- 1–4% of the entries come back rejected from the secure monitor; the core
  then goes round the idle loop again. That costs nothing.
- No RCU stalls, lockups or oopses over 30 s of load on all four cores and
  the idle after it. A warm reboot works (SSH back after about 40 s).
- Power and heat are unchanged within the meter's noise: 5.1 W on average,
  42–45 °C, fan cycling at level 0–1. The cores were already clock-gated
  in WFI, and the cluster itself has no idle state in mainline.

**2. The thermal guard** (`rootfs/usr/local/sbin/darcy-thermal-guard`, a
systemd service; `scripts/18` put it on the SHIELD):
- every 2 s, the hottest of the cpu, gpu, mem and pllx zones, found by type
- at 86 °C, every cpufreq policy's `scaling_max_freq` goes to its
  `cpuinfo_min_freq` and stays there until the next boot
- at 92 °C, `systemctl reboot`, and sysrq `b` if that hangs for a minute
- tried with `GUARD_CAP=40000 GUARD_REBOOT=45000 GUARD_DRY_RUN=1`: both
  paths logged (memory at 46 °C), then it exited. With no cpufreq policy
  yet, the cap had nothing to hold. Its real test comes with the DFLL.

An aside: `/` is mode 555 on this system. That is systemd's own
`tmpfiles.d/root.conf` (`z / 555`), applied at every boot, not something
broken.

**3. The DFLL, held at 1.020 GHz** (`darcy.dts` `&dfll` with stock's values
and complete PBB1 pin states; `patches/linux/0003` sets
`tegra210_cpu_max_freq_table[2]`):
- `cpufreq-tegra124` no longer fails. `cpufreq-dt` runs one policy for
  CPUs 0–3, governor schedutil, rates 204–1020 MHz in 102 MHz steps. At
  boot: "Running at unlisted initial frequency: 1017600 kHz, changing to:
  1020000 kHz".
- `cclk_g` runs from `dfllCPU_out`. The DFLL debugfs shows enabled 1,
  locked 1 (closed loop). PBB1 is no longer tristated: the DFLL drives
  the CPU rail.
- One minute of load on all four cores: 6.2–7.0 W, 45–46 °C. Then idle:
  4.5–4.8 W, a little below the pll_x days. The cores are asleep 97–98%
  of an idle minute.
- The thermal guard's cap, for real: `scaling_max_freq` went to 204000,
  and writing `cpuinfo_max_freq` back undid it.

**The DFLL runs a little faster than asked at the bottom.** Its monitor
measures 1058–1135 MHz for a 1020 MHz request. For 714 MHz it reads 822 MHz
after the scaler, which also means the DVCO itself runs at about 1058 MHz.
- `DFLL_FREQ_REQ` = `0x1040ffa8`: multiplier 40 (1020 MHz), no scaling, a
  feed-forward to index 11.
- `DFLL_OUTPUT_CFG` = `0x0a0b0944`: output between index 9 and 11 (880.8
  to 919.2 mV), safe 10.
- `DFLL_INTR_STS` = 3: the output has hit both its minimum and its
  maximum since start-up. The bits are sticky, and mainline has no reading
  of the live PWM output.
- The reading that fits all this: the output sits at its 880.8 mV floor,
  where this fast chip's DVCO already runs at about 1058 MHz, above the
  918 MHz the driver derives from the OPP table (`dvco_rate_min`). Requests
  below about 1058 MHz therefore come out up to 15% fast. The driver says
  so itself: the minimum rate "should be calibrated at runtime"
  (`clk-dfll.c:833-838`). Stock darcy has `nvidia,one-shot-calibrate` for
  that, which mainline lacks.
- n-codex checked the arithmetic: 83 counts × 12.75 MHz = 1058.25 MHz
  before the scaler, and × 199/256 = 822.6 MHz after it. That the output
  sits at index 9 is likely but not proved. Mainline also reads the
  monitor once, without waiting for a fresh sample (`clk-dfll.c:1255-1271`;
  downstream waits for `NEW` and compares two samples). The spread up to
  89 counts (1135 MHz) may be a torn reading rather than a real clock.
- Mostly a power and accounting defect; timing safety is plausible, not
  proved. The CPU's clock is the DVCO, on the CPU rail, whose low-voltage
  tuning "must be characterized to keep the downstream device stable at
  any DVCO input voltage" (`clk-dfll.c:987-991`). That supports the
  design, but it is no timing guarantee for every voltage and frequency
  pair. NVIDIA's downstream driver knows the case: a misestimated minimum
  makes low requests run high at Vmin. Four cores under load at the floor
  ran clean here, which shows this chip's margin, nothing more general.
- Missing from mainline, all from stock's DFLL:
  - one-shot calibration of that floor (a later power fix)
  - `nvidia,idle-override`: no sign it is needed, but quick swings from
    high rates to idle get tested at each cap
  - a cold floor that raises the minimum voltage below 15 °C
    (`tegra210-darcy-power-dvfs-p2894-0050-a08.dtsi:56-76`): only for a
    cold start in a cold room
  - high-voltage tuning: none for this speedo and process, downstream
    either

**4. Passive cooling through cpufreq** (`darcy.dts`: `#cooling-cells` on
`cpu@0` only, as n-codex advised, since the four cores share one policy
and so one cooling device; passive trips at 82 °C on `cpu-thermal` and
85 °C on `mem-thermal`, whose passive polling goes from 0 to 1000 ms):
- `cpufreq-cpu0` registers with 8 states (9 rates). It is bound to
  cpu-thermal's trip 8 (82 °C) and mem-thermal's trip 4 (85 °C). The
  memory zone's own 50 °C trip stays unbound (EMC, no driver).
- **Tried with real heat**, not emulation: cpu-thermal's passive trip was
  lowered to 44 °C through sysfs (soctherm programs only hot and critical
  trips into hardware, `soctherm.c:592-632`), with all four cores loaded.
  The cooling state went to 1–2 (ceiling 918/816 MHz) and held the CPU at
  44 °C. Idle, it went back to 0 below 42 °C, and the trip went back to
  82 °C.
- `emul_temp` (`CONFIG_THERMAL_EMULATION=y`) would also work, but the
  core then sets soctherm's hardware interrupt thresholds around the
  emulated value (`tegra_thermctl_set_trips()`). With the real sensor far
  below them, it is unclear what the comparators do, so the real-heat test
  was used instead.

**5. The cap goes up in stages** (n-codex: 1.9125 GHz, then 2.0145 GHz, each
with sustained load, quick load/idle swings, repeated monitor readings and
a warm reboot):
- **1.9125 GHz** (`patches/linux/0003`): 18 rates from 204 MHz. The DFLL's
  output limits widen to index 9–27 (up to 1226.4 mV), as predicted. Its
  safe index stays 10.
- Three minutes on all four cores: the monitor reads 1848–1963 MHz
  against the 1912.5 MHz request (three readings each 10 s), so the closed
  loop holds the rate. 10.7–11.8 W. Temperatures level off at CPU 57,
  GPU 53, memory 52 °C, with the fan at level 2 (about 3400 RPM). The
  82 °C passive trip is far off.
- 20 quick swings between load and idle, then idle: clean. No new kernel
  warnings. A warm reboot comes back in about 35 s, locked.
- Idle power is 5.4–5.7 W, whatever the ceiling: two minutes each at
  1912.5, 1020 (`scaling_max_freq`) and 1912.5 MHz gave 5.58, 5.44 and
  5.66 W, with the CPU at 204 MHz for 107 of every 120 s. The 4.5–4.8 W
  measured at the 1.02 GHz cap is not reproducible now, so it came from
  the rest of the board (SSD, Wi-Fi, fan), not the CPU.

- **2.0145 GHz, stock's top** (`patches/linux/0003`, final): 19 rates.
  Three minutes on all four cores: the monitor reads 1989–2052 MHz against
  2014.5 MHz, 11.8–13.1 W. Swings, warnings and a warm reboot (35 s) are
  clean.
- **A soak of 10.5 minutes at 2014.5 MHz on all four cores:** the CPU
  levels off at 61–62 °C from the third minute (GPU 57, PLLX 54, memory
  55 °C), at 12.5–13.0 W. The fan stays at level 2, the 65 °C step never
  comes, and the cpufreq cooling state stays 0. Thirty seconds after the
  load, the CPU is at 49 °C. So the SHIELD keeps its top rate with 20 °C
  to spare before passive cooling. The soak outlived a Wi-Fi drop (below):
  its load loops kept running without the SSH session, and a
  `systemd-run` timer on the SHIELD ended them.

**Wi-Fi drops, twice in an hour** (00:16:55, 01:11:43). Each time:
- The access point deauthenticated the SHIELD (reason 1, `from_ap`).
- Within a second, iwd's quick reconnects to all four BSSes of the home network
  failed with status 16 (authentication timeout).
- iwd blacklisted each one (`[Blacklist] InitialTimeout`, 60 s by
  default, longer after repeated failures) and reconnected 88–90 s later.

The first drop came at idle, the second under full load, and older boots
with CPU idle off show the same pattern, so it is not the power work. It
matters, since Wi-Fi is the main link. A shorter blacklist (iwd.config:
`InitialTimeout`, `Multiplier`, `MaximumTimeout`) would cut the outage.
Why the access point deauthenticates is still open, Wi-Fi power saving
for one.

### The GPU and the desktop: the plan after two reviews (2026-10-23)

n-codex (`research/ncodex-plan2-review.md`) and antigravity
(`research/antigravity-plan2-review.md`) reviewed the plan. antigravity's
review came in after part A was done. On part A it matches what was done:
the cap as a kernel patch, passive cooling before the full rate. The order
for part B:

1. **B1, glmark2 on the TV.** nouveau by hand, the rollback timer armed,
   `glmark2-es2-drm` on `/dev/dri/by-path/platform-50000000.host1x-card`
   (tegra-drm), stopped at 80 °C. Also measure how much hotter the GPU runs
   than the CPU, since the fan follows `cpu-thermal` only.
2. **B3, plain Hyprland** from a VT. Set `AQ_DRM_DEVICES` to that path
   before launch; it has no colon, which Aquamarine's list would split on.
   Leave `DRI_PRIME`, `GBM_BACKEND` and `MESA_LOADER_DRIVER_OVERRIDE` unset,
   and keep atomic on.
   - **The pointer drawn in software first**
     (`cursor:no_hardware_cursors = true`), then the hardware cursor as its
     own step. Tegra210's cursor plane takes only `DRM_FORMAT_RGBA8888`,
     linear, square 32/64/128/256 pixels (`dc.c:957-995, 1203-1252`).
     antigravity found the format. n-codex had the sizes and would start
     with the hardware cursor.
   - Fallbacks one at a time, on evidence: `AQ_NO_MODIFIERS=1` after GBM,
     import or `ADDFB2` failures; `AQ_NO_ATOMIC=1` only after an
     atomic-commit error.
3. **B2, nouveau at boot,** once the desktop starts every time.
4. **B4, omarchy-arm with a `tegra` platform.** darcy's compatible is
   `nvidia,p2894-0050-a08 nvidia,darcy nvidia,tegra210` (read on the
   SHIELD). Without a match it's `generic-aarch64`, which installs the VM
   packages `vulkan-virtio vulkan-swrast` (`install/hardware/arm/vulkan.sh:17-21`).
   - `bin/omarchy-hw-platform`: match `nvidia,tegra210`. Add a new
     `bin/omarchy-hw-tegra`, like `omarchy-hw-raspberry-pi`.
   - `install.sh`: the `--profile` help (`:61-62`) and the banner
     (`:193-205`).
   - `install/hardware/arm/vulkan.sh`: a `tegra)` case, installing nothing
     at first.
   - A new `install/hardware/arm/tegra.sh`, run from
     `install/hardware/all.sh`.
   - `default/hypr/platform.lua` and a new `default/hypr/platform/tegra.lua`:
     the Pi's light defaults (no animations, blur or shadows), plus the
     software cursor until the hardware one is proven.
   - `AQ_DRM_DEVICES` in `default/uwsm/env.d/10-omarchy` and in SDDM's
     environment (`etc/sddm.conf.d/10-wayland.conf`).
   - Tests: a darcy fixture in `test/shell.d/arm64-platform-test.sh`, and
     the new leaf in `arm64-gating-test.sh:41`.

   `bin/omarchy-hw-nvidia` looks at PCI only, so it's false here, and the
   proprietary driver's settings (`default/hypr/nvidia.lua`) stay off. The
   Limine step skips itself, since there's no `limine.conf`.

**Wrong in antigravity's review (checked):**
- It computed the DFLL's voltages from a CPU speedo value of 2089. That
  value isn't in the repo or its history. This chip's is 2041. At 1020 MHz
  that gives 919 mV, and the LUT spanned index 9–11 as measured, not 9–10.
- It treats a `gpu-thermal` passive trip at 84 °C as part of the plan.
  There is none.
- It warns that `install/hardware/arm/vulkan.sh` could fail on a missing
  package. It can't: `omarchy_arm_pkg_add_available` skips missing ones
  (`install/arm/platform.sh:78`).
- It calls Mesa's `tegra` driver a kmsro stub. It's a driver of its own
  around nouveau. It's used the same way: GBM on the tegra-drm card.

**True, and left alone:** with `polling-delay-passive = 1000`,
mem-thermal's stock 50 °C `dram_nominal` passive trip makes the zone poll
once a second while memory is above 50 °C (`thermal_core.c:289-295,
416-419`). The trip is mapped to `&emc`, which has no driver here. The
polling is one sensor read a second, under load only: memory idles at
44.5 °C.

### B1: Mesa's tegra driver crashes on the first draw (2026-10-23)

nouveau loads by hand as before (`card0` nouveau, `card1` tegra,
`renderD128` tegra, `renderD129` nouveau, by-path links for each). Then:

1. **`glmark2-es2-drm --fullscreen`** stops before drawing: "glwindow has
   never been initialized". That's a glmark2 2023.01 bug. The DRM backend's
   `window()` always reports the screen's mode as a full-screen window, so
   with `--fullscreen` the canvas thinks its window exists and never creates
   the GBM surface (`canvas-generic.cpp:269-276`). The DRM backend draws at
   the mode's size anyway, so the flag can go.
2. **Without it**, glmark2 segfaults in `libgallium` before its banner
   (systemd-coredump; Arch Linux ARM ships no debug symbols).
3. **`tools/gpu-smoke.c`**, KMS + GBM + EGL + GLES2 the way a compositor
   uses them, with each step printed before it runs. Everything up to
   `glViewport` works: GBM on tegra-drm, `gbm_surface_create` (XRGB8888,
   scanout + rendering), EGL 1.5, the context, the window surface,
   `eglMakeCurrent`, and `glGetString` ("tegra", "OpenGL ES 3.2 Mesa
   26.2.5-arch1.1"). Then the first `glClear` segfaults, in the same
   `libgallium` frames as glmark2.

**The cause, in Mesa's source (tag `mesa-26.2.5`):**
- Mesa commit 2eb45daa ("gallium: de-pointerize pipe_surface", 2025-05-23)
  made the framebuffer's surfaces values (`p_state.h:411-452`). It also
  deleted the tegra driver's unwrapping in `tegra_set_framebuffer_state`.
  Since then, nouveau gets tegra's wrapped resources as the surfaces'
  textures and crashes validating the framebuffer.
- 1af551ed ("tegra: delete pipe_context surface hooks", 2026-03-23) left
  `tegra_clear_render_target` and `tegra_clear_depth_stencil` reading
  plain surfaces as `tegra_surface`s.
- Every OpenGL program on Tegra crashes this way since Mesa 25.2, Hyprland
  included.
- Upstream knows: issue #14640 (Jetson TX1, open since January) and **merge
  request !45355**, "tegra: unwrap framebuffer and clear surfaces" (Igor
  Pecovnik, tested on a Jetson Nano with 26.1.6). It's open, not merged.

**The fix here,** until a release has it:
- `patches/mesa/0001` is !45355's patch. It applies to 26.2.5 as it is.
- `packages/mesa-darcy/PKGBUILD`: Arch Linux ARM's 26.2.5 (same tarball
  checksum) for Tegra210 alone: gallium nouveau, tegra and softpipe; no
  Vulkan (NVK has no Tegra support yet, issue #14105), no LLVM; GLES1 off
  as in Arch's.
- `scripts/19-build-mesa.sh` builds it on the SHIELD as user `build`
  (makepkg won't run as root), with 4 GiB of temporary swap, and puts it
  in place of `mesa`. `pacman -S mesa` brings Arch Linux ARM's back.

The tegra driver has older gaps too: `tegra_set_shader_buffers` and
`tegra_set_shader_images` pass resources without unwrapping, and
`set_global_binding` and `launch_grid` say "XXX unwrap". Those are storage
buffers, images and compute, which plain GLES 2/3.0 compositing probably
doesn't use (a guess, put to n-codex). antigravity couldn't look: its quota
ran out (resets in about 6 days).

**With the fix,** Mesa from the package tree (`LD_LIBRARY_PATH`,
`__EGL_VENDOR_LIBRARY_FILENAMES`, `GBM_BACKENDS_PATH`), before installing:
- `tools/gpu-smoke`: 1200 and 1800 frames, clean; "tegra, OpenGL ES 3.2
  Mesa 26.2.5-darcy1.1", linear buffers (modifier 0). The user saw the
  colour fade and the triangle, colours right.
- glmark2 draws every scene, but with the GPU on its default clock policy
  28-42 command batches per run come back "kernel rejected pushbuf:
  Connection timed out" (`nv50cal_space: -110`): the kernel waits at most
  1 s for room in the GPU's command ring (`nvif/chan.c:55-91`,
  `nouveau_gem.c:864-869`). One run then segfaulted in Mesa's nouveau
  winsys: `eglSwapBuffers` → `dri_flush` → `nouveau_fence_wait` → …
  → `pushbuf_flush`, through a garbage pointer.

**The GPU's clock is load-driven.** `gk20a_devfreq.c` gives nouveau's
Tegra GPUs devfreq: `simple_ondemand`, a decision every 50 ms, up at 45%
load (`:253-292`). It sets nouveau's user pstate (`:196-197`), so writes to
the debugfs `pstate` file don't stick. Sampled once a second under
gpu-smoke, the clock jumps among 76.8 and 998.4 MHz and the steps between;
idle, it stays at 76.8 MHz. Pinned at 998.4 MHz (`userspace` governor,
`/sys/class/devfreq/57000000.gpu/userspace/set_freq`), glmark2 has **no
rejected batch and no crash**, scores 308 (119 on the default policy), and
stays at or below 53 °C (GPU 50 °C), 10.5-12.4 W. So the flapping clock,
not the GPU, caused the timeouts, and the timeouts the crash. *[Later:
stale progress reads caused them; see "The clock wasn't the cause" below.]*

The GPU's voltage per step (vdd-gpu, read back):

| MHz | 76.8-537.6 | 614.4 | 691.2 | 768 | 844.8 | 921.6 | 998.4 |
|---|---|---|---|---|---|---|---|
| mV | 838 | 880 | 923 | 966 | 1008 | 1051 | 1094 |

Idle power (VDD_SYS, 40 s): 5.83 W on the default policy (at 76.8 MHz),
6.34 W pinned at 614.4 MHz, 8.08 W pinned at 998.4 MHz. 537.6 MHz is the
fastest step at the voltage floor.

**Still open:** glmark2's terrain scene runs at 15 fps at 76.8 MHz and at
998.4 MHz alike, so something other than the GPU's clock holds each frame,
and the user sees it flicker; the other scenes look right. tegra-drm waits
for the GPU's fences before showing a frame (`tegra/plane.c:200-209`,
`drm_gem_plane_helper_prepare_fb`).

**The clock wasn't the cause.** Pinned clocks didn't stop the rejected
batches: 537.6 MHz had 10 in a run, 614.4 MHz 26, and a 30 s run of the
build scene alone at 998.4 MHz one every 1.05 s throughout (44 fps instead
of 467). Each submission waited the whole second, so the kernel saw no
progress at all, yet the light gpu-smoke right after ran clean. The user
saw the spinning objects stop, and the terrain scene's first frames show a
flashing geometric pattern before the landscape (not monitor flicker).

**A nouveau bug, fixed by `patches/linux/0004`.** Since commit
862450a85b85 ("drm/nouveau/gf100-: track chan progress with non-WFI
semaphore release", Linux 6.16), the kernel reads a channel's progress
from a semaphore the GPU releases into a GART buffer
(`nvif/chan906f.c:54-63`). That buffer is allocated without
`NOUVEAU_GEM_DOMAIN_COHERENT` (`nouveau_chan.c:202-203`), unlike the push
buffer (`:168`) and the fence buffer (`nv84_fence.c:222`). Tegra's GPU
doesn't snoop the CPU's caches, so the CPU read the semaphore through a
cached mapping, and the 1 s wait spun on a stale line. Upstream master
still has it. With the flag (`nouveau_bo.c:237-243` makes the buffer
uncached on Tegra), kernel #12: the build scene runs 30 s at 998.4 MHz at
468 fps, with no rejected batch, and the user sees the horse turn without
stopping.

**The terrain pattern: half-drawn frames, fixed by `patches/linux/0005`.**
The user's photo shows the landscape cut by a straight-edged wedge of the
background colour, frames alternating between that and the full picture:
frames scanned out before nouveau finished them. tegra-drm's
`tegra_bo_import()` (`tegra/gem.c:458-497`) gives an imported dma-buf's
GEM object its own, empty reservation object, where the generic
`drm_gem_prime_import_dev()` takes the dma-buf's (`drm_prime.c:1008-1009`).
`drm_gem_plane_helper_prepare_fb()` then finds no fence of nouveau's to
wait for, and the page flip goes ahead mid-render. That shows only when a
frame takes longer to draw than the flip: terrain (about 69 ms a frame),
and effect2d at 76.8 MHz. Upstream master is the same. Kernel #13 shares
the dma-buf's reservation object: terrain at 15 fps, no rejected batch,
and the user sees no flicker ("not smooth but it's moving"). Terrain's
15 fps likely comes from memory bandwidth: the EMC runs at a fixed
800 MHz (no EMC scaling yet).

With kernel #13 and mesa-darcy 26.2.5-2 installed (`scripts/19`), glmark2
on the default clock policy: build 463, texture 381, shading 372, bump 411,
effect2d 215, terrain 15 fps, score 308, no rejected batch, 54 °C at most.
The user: "everything is running smooth". `simple_ondemand` stays: it
rises to 998.4 MHz under load and idles at 76.8 MHz. Terrain without its
bloom and tilt-shift passes: 24 fps. Stock darcy's EMC tables go up to
1600 MHz (`tegra210-darcy-p2894-emc-a00.dtsi`: 40.8 to 1600 MHz, two RAM
codes); the EMC is the next big lever for the GPU, later and in stages.

### B3: plain Hyprland on the TV (2026-10-23)

`tools/hyprland-try.sh` repeats it: hyprland 0.56.2 (aquamarine 0.15.1)
and foot, a minimal Lua config for the stock user `alarm` (Hyprland
refuses root; software cursor; no animations, blur or shadows), started
as a service with a logind session (`PAMName=login`) on console 7.
- On console 2 it quit at once: switching the TV there started
  `getty@tty2`, which took the console. logind starts a getty on consoles
  1-6 when they become active; console 7 has none.
- aquamarine: libseat through logind, tegra-drm's card from
  `AQ_DRM_DEVICES` (nouveau's skipped, "not a KMS device"), atomic, GLES
  3.2 on "tegra". It creates its context robust ("requesting lose on
  reset"), so the state tracker installs a device reset callback: the
  path `patches/mesa/0007` keeps from calling nouveau's missing hook.
- The user saw the wallpaper, then nothing more: the root filesystem has
  no fonts, so foot found no monospace font and quit. With `ttf-dejavu`
  the terminal shows. The locale is `C` (foot falls back to C.UTF-8).
- Idle with a terminal: 5.3 W, 44 °C, the CPU 99% idle, the GPU at
  76.8 MHz. The scanout buffer is XRGB8888 **linear** (modifier 0), not
  block-linear: a later look at why aquamarine and Mesa's tegra driver
  settle on linear.

### B2: nouveau at boot (2026-10-23)

`scripts/13` no longer writes `/etc/modprobe.d/20-darcy-nouveau.conf`, and
on the SHIELD the file went (kept as `/root/20-darcy-nouveau.conf.disabled`
in case). After a reboot, udev loads nouveau at 11:04:56, with tegra-drm's
console as before (card1 tegra-drm, card0 nouveau, the same by-path
links). The boot takes 17.8 s (11.2 s kernel). No new warnings. Idle:
5.49 W, 43 °C, the GPU at 76.8 MHz and 838 mV on `simple_ondemand`, the
thermal guard running.

### B4: Omarchy, the plan after n-codex's review (2026-10-23)

The desktop user is `devsecai` (the user's choice; config.sh
`OMARCHY_USER`), in wheel, with a temporary password
(the user deferred passwords; SSH takes keys only, so it counts at the TV
alone; since B9, `scripts/20` asks for the password, and config.sh's default
user is `omarchy`). omarchy-arm's `install.sh --dry-run`: 124 repository packages
(Chromium, Docker, clang and CUPS among them), 2 AUR ones (`mise-bin`,
`ufw-docker`, built with yay), 13 with no aarch64 build left out, the boot
chain's files skipped ("not ours on ARM").

`patches/omarchy-arm/0001` adds a `tegra210` platform: detection from
`nvidia,tegra210`, `omarchy-hw-tegra`, no Vulkan packages (NVK has no
Tegra support), the Pi's light Hyprland look and a software pointer, in the
session (`default/hypr/platform/tegra.lua`) and in SDDM's greeter.
omarchy-arm's tests pass, with new ones for it; the dry run on the SHIELD
reports "Platform: NVIDIA Tegra210".

n-codex's review (`research/ncodex-omarchy-review.md`), each point checked:
- **Networking moves at the next boot.** `install/hardware/network.sh`
  disables iwd and networkd, `install/config/enable-services.sh` enables
  NetworkManager (and resolved, avahi, SDDM, Docker's socket, CUPS). Only
  enabled, so the install keeps SSH, but NetworkManager would come up
  without the Wi-Fi. `scripts/20` writes it a profile from iwd's, with the
  permanent MAC and networkd's DHCPv4 client ID
  (`ff:…`: 0xff, IAID,
  systemd's DUID) so the router hands out the same lease, and
  `scripts/21` tries the switch live, with a timer that puts iwd and
  networkd back unless SSH comes back through NetworkManager.
- **The firewall** denies incoming connections from the next boot; the SSH
  exception depends on sshd being enabled (it is). `scripts/20` reports the
  rule and mDNS before any reboot.
- **SDDM's greeter can't run a predicate:** Hyprland reaps its children,
  so `os.execute()` gets no exit status (`default/hypr/helpers.lua:21-22`).
  The greeter config reads `/proc/device-tree/compatible` itself.
- **`AQ_DRM_DEVICES` stays,** as tested, set before Hyprland starts: in
  UWSM's environment for the session (when tegra-drm's by-path device
  exists) and in an SDDM drop-in the Tegra leaf writes for the greeter.
- **`linux-modules-cleanup.service`** deletes module trees no package owns;
  ours aren't pacman's, so it stays off on Tegra210.
- **Kernel #13 has neither PSI nor zram,** which Omarchy's zram swap and
  systemd-oomd need: `kernel/darcy.config` gains `CONFIG_PSI=y`,
  `CONFIG_ZRAM=m`, `CONFIG_ZRAM_BACKEND_ZSTD=y` (kernel #14).
- The temporary NOPASSWD sudo rule for the install is checked with
  `visudo`, and the install service's `ExecStopPost` removes it even if SSH
  drops.
- `mesa` isn't in Omarchy's lists, so nothing replaces `mesa-darcy`.

**The first install (kernel #14) stopped at the firewall.** 586 packages
(1.19 GB down, 4.9 GB installed), yay, the AUR packages, the deploy, the
settings and 150 shipped defaults went through in 13 minutes. Then
`install/config/firewall.sh` failed: `ufw` "Couldn't determine iptables
version", because Arch's `iptables` is `xtables-nft-multi` ("Failed to
initialize nft: Protocol not supported") and the kernel had no
`CONFIG_NF_TABLES` (nor NAT, which Docker needs). It left the system half
set up: NetworkManager enabled by `enable-services.sh`, while
`hardware/network.sh`, which disables iwd and networkd, hadn't run yet. A
reboot then would have started both. The install service's
`ExecStopPost` removed the temporary sudo rule as planned. Kernel #15
takes the netfilter options of Arch Linux ARM's `linux-aarch64` config
(nf_tables and its xtables compatibility, conntrack, NAT, veth, bridge,
overlayfs), less four that need Open vSwitch or IPsec. A bug found on the
way: systemd's `StandardOutput=file:` doesn't truncate, so the first lines
of the new log overwrote the dry run's and left its tail in place. Before
the kernel-#15 reboot, NetworkManager and SDDM were disabled again by hand,
so the half-set-up system booted on iwd as before.

**The second install (kernel #15) completed,** in 2.5 minutes (the packages
were there), with no failed step. `truncate:` then emptied the log at the
end, because systemd reopens a service's output for `ExecStopPost` too;
`scripts/20` now empties it first, appends, and ends it with install.sh's
exit code. The state for the next boot: sshd, NetworkManager, resolved,
avahi, SDDM, ufw (with `allow 22/tcp`, and mDNS in `before.rules`), oomd and
Docker's socket enabled; iwd, networkd and `linux-modules-cleanup` not;
`/var/lib/omarchy/platform` is `tegra210`, and the greeter's drop-in is in
place.

**`scripts/21` switched the Wi-Fi to NetworkManager live:** `wlan0`
connected to the network at **the same address** (the router recognised
networkd's client ID), SSH came back, and the rollback was cancelled.
NetworkManager gave resolved the router's DNS (192.168.1.1) a moment after
connecting: the first lookup, made at once, failed. networkd's old default
route stays until the reboot.

### B5: The first Omarchy boot: the login and the bar (2026-10-23)

The reboot (kernel #15) came up on NetworkManager at the same address, with
SDDM's Omarchy greeter on the TV; ufw let SSH in, oomd ran, and zram0
(2.8 GB) was the swap.

**The greeter turned the password down.** PAM logged "User name not set"
and "user unknown": the theme's form has only a password field, and logs in
as `userModel.lastUser` (`default/sddm/omarchy/Main.qml:10,106`), which
omarchy-arm writes only at its first-boot setup (`omarchy-provision-owner`'s
`configure_login`: `[Last]`, `Session=omarchy.desktop`, `User=<name>` in
`/var/lib/sddm/state.conf`). `scripts/20` makes the user itself, so nothing
wrote it. Written by hand, the login worked; `scripts/20` now writes it
(`/var/lib/sddm` stays sddm's, 750). SDDM rewrites the file after a login.

**The bar had no colours.** It was a 26-pixel strip with no background over
the wallpaper and nearly invisible text. `transparent` was true in
`~/.config/omarchy/shell.json`, though the default is false; the menu's
Style, Menu Bar, Transparency toggles it, and nothing in the journal says
what did at 13:28. `omarchy-bar transparent false` made the bar a black
strip, still with no text. The shell logged some 1100 errors at each start,
in the bar, the lock screen, the polkit dialog and the menus: `Unable to
assign [undefined] to QColor`, `Cannot read property 'text' of undefined`.
Every `Color.<surface>` was undefined. A shell of three imports (Quickshell,
QtQuick, qs.Commons) printed `Color=QQuickColor(...)`: Qt 6.12 exports a
`Color` singleton from QtQuick (`QQuickColor`, `exports:
["QtQuick/Color 6.12"]` in `/usr/lib/qt6/qml/QtQuick/plugins.qmltypes`, with
`rgba()` and the like), and a bare `Color` resolves to it. Omarchy 4.5, on
the laptop, imports `qs.Commons as Commons` in 75 files and writes
`Commons.Color` 346 times, with no bare `Color` left; omarchy-arm's 4.0
alpha has bare `Color` in 54 files. No other name in the shell's modules
collides with a Qt or Quickshell type.

`patches/omarchy-arm/0002` does what 4.5 does, with the commands in its
message, and the one test that matched `color: Color.accent` follows.
omarchy-arm's shell tests pass (2472), except three that need an
omarchy-pkgs checkout and fail without the patch too. The fix went onto the
running SHIELD as the 54 files copied into `/usr/share/omarchy/shell` (root's,
as install.sh leaves it; the old ones are in
`/root/omarchy-shell-before-color-fix.tar`), then `omarchy-restart-shell`; a
fresh install gets it from `scripts/20`. The shell starts with none of those
errors; the bar shows the theme's background (tokyo-night, `#1a1b26`) with
the workspaces, the clock and the icons, and the lock screen has its colours.

The dim icons that show left of the clock only while the pointer is on the
bar are Omarchy's inactive indicators (microphone, recording, stay awake, do
not disturb and the like), hidden until hovered, as on the laptop. The
indicators widget's `alwaysShow` setting keeps them shown.

**Restarting the shell while the session was locked** (the idle lock had
locked it, with the TV's screen off) killed the lock client. The new shell
took the lock and reported it secure within 7 s, but `omarchy-restart-shell`
still gave up after 30 s ("the session lock was not re-secured"), and when
the screen came back on, Hyprland showed its "lockscreen app died" screen
for up to half a minute before the shell's lock screen. n-codex's reading
(`research/ncodex-omarchy-color-review.md`): `omarchy-restart-shell` asks the
old shell for its lock state with a 0.5 s timeout and errors discarded, and
takes any answer but "secure or requested" for a dead lock screen, so a
slow or failed answer gets a healthy lock screen killed. Unlock first, then
restart the shell. Check `omarchy-hyprland-session-locked` before restarting:
it needs `HYPRLAND_INSTANCE_SIGNATURE` over SSH, or `hyprctl` fails and it
reports the session unlocked.

### B6: Gaming performance: SuperTuxKart (2026-10-23)

The user asked for a game to test the GPU with. SuperTuxKart 1.5 is in
Arch Linux ARM (663 MB) and has a benchmark: `supertuxkart --benchmark`
replays a race on its most demanding track, the same every time, and saves
its result and a CPU profile per frame in `~/.config/supertuxkart/
config-0.10/`. `tools/stk-benchmark.sh` runs it in the desktop over SSH,
records temperatures, power and clocks, and prints the lot. The game draws
through the GPU (renderer "tegra", OpenGL ES 3.2, our Mesa), in a 1054x1054
window, with its graphics at low but for dynamic lighting.

| kernel, settings | FPS | frames in | per frame |
|---|---|---|---|
| #15, dynamic lighting | 3.4 | 762 in 221 s | 293 ms: draw 140, draw-call generation 97, sync stall 90 |
| #16, dynamic lighting | 3.2 | 762 in 236 s | 307 ms: sync stall 241, draw 39 |
| #16, no dynamic lighting | 17.9 | 792 in 44 s | 57 ms: draw 32, draw-call generation 9 |
| #16, dynamic lighting, no float targets | 3.4 | 762 in 223 s | 290 ms: sync stall 165, end of scene 51 |

The last row ran with `MESA_EXTENSION_OVERRIDE=-GL_EXT_color_buffer_float`
(`tools/stk-benchmark.sh` passes NAME=value arguments to the game): STK
then renders into RGBA8 targets (its log loses "EXT Color Buffer Float",
and the context drops to OpenGL ES 3.1). No change, so float blending
isn't the cost of dynamic lighting; shader work, overdraw, the 4 KiB pages
or serialization remain.

**Kernel #15: the CPU cleaned caches.** `perf record -a -g` (perf 7.2.11,
the Cortex-A57 PMU works) mid-race: 69% of the game's samples in
`dcache_clean_poc`, from `nouveau_bo_sync_for_device()` in
`nouveau_bo_validate()`, from the pushbuf ioctl. On every pushbuf nouveau
cleaned the data cache over every page of every non-coherent BO it used,
because the GPU doesn't snoop the CPU's caches; textures and render
targets the CPU never writes included. `patches/linux/0006` (kernel #16)
syncs only BOs the CPU may have written: one a CPU mapping ever touched (a
userspace fault, kmap, vmap, ptrace), or one whose pages are new since its
last validation (a move). n-codex's review (`research/ncodex-nouveau-sync-review.md`)
found it sound for this stack, with two points before it goes upstream:
`CPU_FINI` should take the reservation the new fields are documented under,
and page population (`nouveau_ttm_tt_populate()`) should mark the BO too,
not only moves. Mesa maps buffer resources (vertex, uniform) directly, so
those keep being cleaned: the 26% of samples left.

**Kernel #16: the GPU is the limit.** The CPU went 86% idle and the GPU
sat at 998 MHz (pstate AC; board power 10.3 W against 6 W idle), and STK's
fence wait took 241 ms per frame. Its GPU timers read 0, so the passes
can't be timed from the game. Without dynamic lighting (STK's forward
renderer) the same replay ran 5.6 times faster: the deferred pipeline is
the slow path here, though SSAO, shadows, glow, bloom, light shafts and
MLAA were off. STK stays without dynamic lighting for the user
(`config.xml.bak-dynamic-lights` has the old settings).

glmark2-es2-wayland `--off-screen` (no compositor), FPS:

| size | terrain | texture | build |
|---|---|---|---|
| 1920x1080 | 15 | 201 | 217 |
| 960x540 | 28 | 707 | 680 |
| 480x270 | 44 | 1727 | 1277 |
| 240x135 | 51 | 3477 | 1412 |

A trivial textured scene scales with the pixels (about 415 Mpix/s at
1080p); terrain keeps about 20 ms per frame at any size. Suspects for the
GPU side, none measured yet: every GPU mapping uses 4 KiB pages (for GART
BOs nouveau skips page sizes above PAGE_SHIFT, `nouveau_bo.c:281-283`, and
on Tegra everything is GART), with the GMMU's page tables in instmem behind
the SMMU ("imem: using IOMMU"); no compression; EMC at 800 MHz, half of
stock's top rate. Brief: `research/gpu-slow-brief.md`.

n-codex's brainstorm (`research/ncodex-gpu-slow-review.md`), its source
claims checked where marked:
- STK's G-buffer is two RGBA8 targets; the lighting writes two
  R11G11B10F targets with additive blending (up to 32 point lights in one
  instanced draw, each fragment sampling normal and depth), and the combine
  reads six textures into an RGBA16F target. Both float formats are native
  and blendable on NVC0: no software fallback, just a heavy pass.
- **No compression on GM20B** (checked: `ltc/gf100.c:163-166`, "No VRAM,
  no tags for now", `num_tags = 0`). ZCULL and the L2 are set up; clock
  gating, ELPG and the tegra wrapper are unlikely causes.
- Our fixes don't add GPU work: 0006's longer fence wait is the same GPU
  time, now reached sooner by the CPU.
- Next measurements, cheapest first: the benchmark with dynamic lighting on
  and `MESA_EXTENSION_OVERRIDE=-GL_EXT_color_buffer_float` (STK then uses
  RGBA8 targets; a big gain means float blending and bandwidth); a
  resolution sweep with lighting on and off; GPU timer queries in a small
  GLES test (`GL_EXT_disjoint_timer_query`, 64-bit results), as STK's read 0;
  Mesa's GM200 SM counters through `GALLIUM_HUD`, checked on a simple shader
  first. Then the larger jobs: EMC at 1600 MHz (mainline needs
  firmware-trained `tegra210_emc_timing` records in reserved memory, not the
  downstream `emc-table` nodes), the GPU without `iommus` (tests the page
  tables' SMMU layer only), and big GPU pages last (a new allocation and
  mapping path, not just lifting the `PAGE_SHIFT` checks).

### B7: The memory clock: cboot's trained tables (2026-10-23)

The EMC runs at 800 MHz, the rate cboot left: the kernel has no EMC driver
(`# CONFIG_TEGRA210_EMC is not set`). Stock darcy scales it from 40.8 to
1600 MHz. Mainline's `tegra210-emc` takes its table from a reserved-memory
region (`nvidia,tegra210-emc-table`): an array of up to 16
`struct tegra210_emc_timing` (`drivers/memory/tegra/tegra210-emc.h`), all
u32 and char arrays, ending at a zero revision. It refuses rates above
204 MHz unless the entries are trained.

**cboot trains the table and puts it in the device tree it hands on.**
The live device tree captured from Android had only its layout (no root,
no property values), and Linux can't read cboot's tree from memory
(`STRICT_DEVMEM`: "Bad address"). `patches/u-boot/0002` puts cboot's
device tree, whole, in `/chosen/darcy,cboot-fdt` of the one Linux boots
with (`CONFIG_SYS_FDT_PAD=0x100000` leaves the room), and Linux shows it as
`/sys/firmware/devicetree/base/chosen/darcy,cboot-fdt` (564,579 bytes;
saved, git-ignored, in `device-info/cboot-fdt/`). Its
`external-memory-controller@7001b000` has two tables of ten rates (40.8,
68, 102, 204, 408, 665.6, 800, 1065.6, 1331.2 and 1600 MHz):
- `emc-table@0`, `nvidia,ram-code = <0>`, dvfs-version "03_...":
  `nvidia,trained = <0>` at every rate.
- `emc-table@1`, `nvidia,ram-code = <1>`, dvfs-version "02_...":
  `nvidia,trained = <1>` at every rate, with trained DRAM clock-tree
  values (1600 MHz: c0d0u0 0x14b, c0d0u1 0x157, c1d0u0 0x14f, c1d0u1
  0x157).

The board's RAM code is 1 (`APB_MISC_PP_STRAPPING_OPT_A` 0x00001c10, bits
7:4), so cboot trained the table that matches. The properties mirror the
struct's fields (`nvidia,trained_dram_clktree_c0d0u0` and so on).

At 1600 MHz the table asks for `nvidia,emc-min-mv` 887 (vdd-core is fixed
at 1125 mV, enough) and `nvidia,gk20a-min-mv` 1100, the same at every
rate, 800 MHz included, where vdd-gpu runs down to 838 mV without trouble:
not a floor for the higher rates (mainline doesn't apply it either).

Every rate from 665.6 MHz up runs from `pllm_ud`, undivided
(`src-sel-reg` 0x80188000), so each needs PLLM or its twin PLLMB at the
rate itself; `clk-tegra210-emc.c` retunes the idle one and hands the EMC
over. 408 MHz runs from `pllp_ud`, 204 MHz and below from `pllp_out0`.

**The handoff.** `patches/u-boot/0003` fills a reserved region of our
device tree (`emc-table@b0200000`, 0x14000 bytes, no-map, right after
ramoops; `&emc` takes it as `memory-region-names = "nominal"`) at each
boot, from cboot's table for the straps' RAM code, as an array of Linux's
struct (61 fields, 1232 words, checked at build). It checks every property
is there at its exact length, every string whole, every count within its
array, one revision throughout, and every rate above 204 MHz trained, and
sorts the rates. Anything amiss leaves the region zeroed: the driver then
finds no entry for the current rate and leaves the EMC alone. A copy goes
in `/chosen/darcy,emc-table`, and `tools/emc-table.py` builds the expected
table independently (the layout from the kernel's header, cboot's tree
through its own FDT parser) and compares. The driver is a module
(`CONFIG_TEGRA210_EMC=m`; the table handler is built in), and probe is
passive: it parses, attaches to the EMC clock and arms no timer; the rate
moves only through debugfs `emc/min_rate` and `max_rate`.

n-codex's review (`research/ncodex-emc-review.md`): the conversion matches
the ABI and the region is safe, but two hazards in mainline's driver came
first:
- **Refresh at high DRAM temperature never changed** (checked):
  `tegra210_emc_set_refresh()` compares with `emc->refresh` but never
  stores it, and `tegra210_emc_adjust_timing()` switches on it, so the
  MR4 poller's 2x/4x requests left the timing at nominal; and with no
  derated table (cboot has none) the hottest state fell back to nominal
  too. `patches/linux/0007` stores it before adjusting, and maps
  throttling to 4x refresh without a derated table. The poller runs only
  once the EMC cooling device is active (70 °C in tegra210.dtsi).
- **A clock change can hang with interrupts off:** r21021's DLL prelock
  polls with no timeout under `spin_lock_irqsave()`, where a sysrq timer
  can't fire. Kernel #18 adds the soft and buddy hard-lockup detectors
  with `BOOTPARAM_HARDLOCKUP_PANIC`: a stuck CPU panics through its buddy,
  and `panic=10` reboots. If the DRAM itself stops, the hardware watchdog
  (systemd, 60 s) resets.

Its plan, adopted: probe-only at 800 MHz first, with the table compared
from the same boot; a register snapshot (PLLM, PLLMB, `CLK_SOURCE_EMC`,
and the PMC's PLLM override through `tools/pmc-read`, as the PMC is
secure-only) before and after the first switch; 800 to 1065.6 MHz and
back several times before going further; at each rate memory, GPU and
display loads together, for 30 to 60 minutes, and hours at 1600 MHz;
watch for hash mismatches, crashes, MC/SMMU errors, display underflow;
cold and warm boots; and a service that sets the rate only last.

**Kernel #18 at 800 MHz (probe only).** The region came up
(`emc-table@b0200000`, 80 KiB, no-map), tegra210-emc took it with no
error, the clock stayed at 800 MHz from `pll_m_ud`, and debugfs lists the
ten rates. The table in `/chosen/darcy,emc-table` (54,208 bytes) is
identical to `tools/emc-table.py`'s from the same boot's cboot tree. cboot
retrains at each boot: the trained clock-tree values moved by one between
two boots (0x14b to 0x14c, 0x157 to 0x158, 0x14f to 0x150), which is why
U-Boot converts the table at each boot. The snapshot before the first
switch: PLLM M 3, N 125, P 1 (1600 MHz, halved: the EMC's 800), PLLMB M 3,
N 125, P 0, enabled and locked at 1600 MHz, `CLK_SOURCE_EMC` 0x80188000;
the PMC's `PLLP_WB0_OVERRIDE` (0xf8, read through `tools/pmc-read`)
0x00018416, with PLLM_OVERRIDE (bit 11) and PLLM_ENABLE (bit 12) clear: no
PLLM override, the CAR registers rule. The safety nets on: the buddy
hard-lockup detector with `hardlockup_panic` (10 s), the 1-minute hardware
watchdog, and a 3-minute sysrq reboot timer around each switch.

**The switches.** 800 to 1065.6 MHz moved the EMC to `pll_mb_ud` (PLLMB
retuned) in 7 ms. The clock framework keeps the rate it last set as its
target, so lowering `min_rate` again left it at 1065.6: a lowered
`max_rate` brings it down (`tools/emc-rate.sh` raises the floor to go up,
lowers the ceiling to go down, and restores the full range). Then
800 and 1065.6 MHz three times each way, 2 to 7 ms a switch, alternating
PLLM and PLLMB, then 1331.2 (PLLMB) and 1600 MHz (`pll_m_ud`: PLLM
reprogrammed). memtester over 256 MiB, one loop, passed at each: 133 s at
1065.6, 122 s at 1331.2, 115 s at 1600 MHz, 18 checks ok, no failure, no
MC, SMMU, display or nouveau message. At 1600 MHz the DRAM's MR4
temperature state read 2 (nominal) at 48 °C.

glmark2-es2-wayland `--off-screen` at 1600 MHz, against 800:

| size | terrain | texture | build |
|---|---|---|---|
| 1920x1080 | 24 (15) | 353 (201) | 433 (217) |
| 960x540 | 42 (28) | 1200 (707) | 1177 (680) |

The memory was the GPU's main limit: 50 to 100% more. STK's benchmark
read 10.0 FPS at 1600 MHz and 9.6 at 800, with 51 ms per frame in
"EndScene", but both ran with the session locked and the TV off (the idle
lock at 15:41, `dpmsStatus` false): Hyprland throttles the frame
callbacks of a hidden window, so those runs don't count. STK needs the
session unlocked on the TV.

**A soak at 1600 MHz** (15:51 to 16:27, 36 minutes):
memtester over 1 GiB, four loops, with glmark2 off-screen (terrain and
texture at 1080p) running alongside: 72 checks ok, no failure, no MC,
SMMU, nouveau, lockup or OOM message. CPU 54 to 64 °C, GPU 52 to 58, mem
54 to 59; the DRAM's MR4 state 3 under load (JEDEC's 1x refresh; 2 at
idle).

**The refresh at high temperature, tested, and a second bug.** With the
EMC cooling device (`cooling_device1`) forced on and debugfs
`emc/temperature` faking MR4 states, kernel #18 wrote: normal
`EMC_REFRESH` 0x1820, state 4 ("2x") 0x3040, states 5 and 6 ("4x", and
throttle mapped to 4x) 0x6080, state 3 back to 0x1820; and the same
scaling for `PRE_REFRESH_REQ_CNT` (0x608) and the low half of
`DYN_SELF_REF_CONTROL` (0x308c). 0x1820 is 6176 cycles, 3.9 µs at
1600 MHz: LPDDR4's refresh interval (EMC_REFRESH bits 15:6 are the
interval, 5:0 REFRESH_LO). `REFRESH_SPEEDUP()` multiplies it, so "4x
refresh" refreshed a quarter as often, exactly wrong for hot DRAM (JEDEC:
MR4 4 halves tREFI, 5 quarters it). Mainline's first bug, the refresh
never stored, kept the second from ever running; 0007 had made it
reachable (above the 70 °C trip, with MR4 at 4 or more: not reached, 59 °C
at most so far). `patches/linux/0007` now divides (kernel #19).

Kernel #19, the same test at 1600 MHz: normal 0x1820, state 4 0x0c10
(2x), states 5 and 6 0x0608 (4x), state 3 back to 0x1820; and
`PRE_REFRESH_REQ_CNT` 0x608, 0x304, 0x182, `DYN_SELF_REF_CONTROL`'s low
half 0x308c, 0x1846, 0x0c23. The table from that boot again matched
`tools/emc-table.py` byte for byte, and `tools/emc-rate.sh` took the EMC
from 800 to 1600 MHz in one switch (PLLMB).

**STK with the user at the TV** (kernel #19, unlocked, dynamic lighting
off, the same replay):

| EMC | FPS | steady, mostly stable, typical | GPU at 998 MHz |
|---|---|---|---|
| 800 MHz | 17.7 (787 frames in 44 s) | 11, 14, 17 | 82% of the time |
| 1600 MHz | 20.7 (845 frames in 41 s) | 14, 16, 19 | 56% of the time |

17% more frames on average and 27% in the slowest stretches, with the GPU
idle more of the time: STK is now limited by the CPU's side of drawing
("SP::Draw normal" 30 ms of a 49 ms frame).

**The CPU's side of drawing: still the cache cleaning.** `perf` on kernel
#19 at 1600 MHz: 41% of the game's CPU time in `dcache_clean_poc` under
`nouveau_bo_sync_for_device()`, STK itself 18%, Mesa 6%. 0006's sticky
flag kept cleaning, whole and on every pushbuf, any BO userspace had ever
mapped: Mesa's `mm_GART` slabs (vertex, index and uniform buffers, created
`NOUVEAU_BO_GART | NOUVEAU_BO_MAP`), pushbufs, staging. 0006 v3 (kernel
#20) tracks writes instead: a fault marks the pages it maps (the faulting
one and TTM's 16 prefaulted after it), and before the GPU's use the BO's
mappings are revoked (`ttm_bo_unmap_virtual()`) and only the marked pages
cleaned; the next write faults in again. *[Kernel #21 revokes only the
userspace mappings, with `drm_vma_node_unmap()`: see n-codex's review
below.]* Kernel maps (kmap, vmap) stay
"whole BO, every time", new pages "whole BO, once". (The other route,
write-combined GART slabs in Mesa with `NOUVEAU_BO_COHERENT`, as Mesa
already does for its fence BO, would make CPU reads of those buffers
slow.)

STK at 1600 MHz, dynamic lighting off, the same replay:

| kernel, window | FPS | steady, mostly stable, typical | GPU at 998 MHz |
|---|---|---|---|
| #19, 1054x1054 | 20.7 | 14, 16, 19 | 56% |
| #20, 1054x1054 | 37.2 (1418 frames in 38 s) | 24, 29, 36 | 84% |
| #20, full screen 1920x1080 | 30.7 to 30.9 | 17, 23, 30 | 75 to 84% |

80% more frames: "SP::Draw normal" went from 30 to 10 ms a frame, and the
GPU is the limit again. The full-screen runs (`--fullscreen
--screensize=1920x1080`) had Mesa's HUD on screen (`GALLIUM_HUD=fps;
frametime;cpu`, `GALLIUM_HUD_SCALE=2`) and STK's own counter
(`show_fps="true"` in its config), for the user to film; STK keeps
`--fullscreen` in its config afterwards.

n-codex's review of v3 (`research/ncodex-nouveau-dirty-review.md`, after
#20 was flashed): the revoke-then-clean ordering holds on arm64 (the
broadcast TLBI's DSB ISH completes the stores through the old mappings
before the clean), the page range is right (TTM prefaults forward only,
PTE by PTE; `vmf->pgoff - drm_vma_node_start()` is the BO's page for any
VMA), and GUP, `process_vm_writev`, io_uring, COW and mremap can't write a
`VM_IO|VM_PFNMAP` mapping. Fixed in kernel #21:
- the fault marked its pages before `nouveau_ttm_fault_reserve_notify()`,
  which can validate the BO (relocating a tiled one) and so consume the
  mark: it marks after now, right before the pages are mapped;
- a ptrace write (`.access`) marked under one reservation and wrote under
  another: it makes the BO sync whole for good instead;
- `ttm_bo_unmap_virtual()` also frees the BO's I/O mapping, which a lasting
  kmap of a tiled BO may still use: `drm_vma_node_unmap()` only;
- coherent BOs and coherent devices (`dma_dev_need_sync()` false, as on
  x86) aren't marked, so their mappings aren't revoked for nothing;
- kernel maps mark the BO only once they exist.

Kernel #21, full screen at 1920x1080 with the HUD, filmed by the user:
31.3 FPS (1195 frames in 38 s; steady 18, mostly stable 23, typical 31),
CPU load 26%, 12.5 W, CPU 57 °C: the fixes cost nothing.

### B8: Whole-system benchmarks (2026-10-23)

Kernel #21, Mesa 26.2.5-darcy, CPU up to 2014.5 MHz, EMC at 1600 MHz,
Omarchy's desktop logged in and idle. `tools/system-benchmark.sh` runs
everything but Geekbench, one test at a time.

| | Linux (this) | Android 11 (stock, as reported) |
|---|---|---|
| Geekbench 6.7.1 single-core | **317** | 302 |
| Geekbench 6.7.1 multi-core | **854** | 789 |

Geekbench: the Linux/AArch64 preview (`cdn.geekbench.com/
Geekbench-6.7.1-LinuxARMPreview.tar.gz`), which uploads every result:
https://browser.geekbench.com/v6/cpu/19382032 (the user agreed to the
upload). Its CLI shows no scores and exports nothing; the result page sits
behind Cloudflare's browser check, so it was read in the user's Chrome.

The rest:
- boot: 10.75 s kernel + 10.18 s userspace = 20.9 s to the login screen
- idle: 6.7 W (CPU 46 °C, GPU 44, mem 49) at EMC 1600 MHz
- 7-Zip 26.05 `7z b`, four cores: 7015 MIPS compressing, 12690
  decompressing, 9853 total
- memory, sysbench, 4 threads, 64 MiB blocks: read 9.8 GB/s, write
  19.6 GB/s at 1600 MHz; 8.8 and 10.4 GB/s at 800 MHz. *[Later: those are
  thousands of MiB/s, not GB/s. The writes, 19,632 MiB/s, are 20.6 GB/s; see
  `docs/benchmarks.md`.]* (1 MiB blocks read
  26.6 and 31.3 GB/s: the 2 MiB L2, not the DRAM, past the 25.6 GB/s a
  64-bit LPDDR4 bus at 1600 MHz carries.)
- glmark2 2023.01 `glmark2-es2-wayland --off-screen`: 847 at its default
  800x600, 288 at 1920x1080
- SuperTuxKart 1.5 benchmark, 1920x1080 full screen: 31.3 FPS (B6)
- storage, fio on the root filesystem: 25 MB/s sequential write, 28 MB/s
  read *[MiB/s: the tool's label was wrong]*, 2670 IOPS random 4 KiB reads: the SSD runs at USB 2 speed. Not the
  SHIELD's nor the hub's doing: the hub is a Genesys Logic USB 3.2 hub,
  whose SuperSpeed half (`2-2`, "USB3.2 Hub") is up at 5000 Mbit/s on the
  SHIELD's SuperSpeed port 2 (usb3-1) and idle (U3); its USB 2 half (`1-3`,
  "USB2.1 Hub") carries the keyboard, the mouse and the SSD. The SSD (an SSK
  enclosure, JMicron bridge 152d:581d, `usb-storage`) linked to the hub at
  480 Mbit/s (bcdUSB 2.10, as a USB 3 device on a USB 2 link reports
  itself): its cable, most likely, carries USB 2 only. To try: a USB 3
  cable, with the SHIELD off (it runs from this SSD).
- Wi-Fi: 5 GHz (5240 MHz), -67 to -69 dBm, link 270 Mbit/s down and
  88 Mbit/s up; TCP with the laptop, itself on Wi-Fi: 47 Mbit/s to the
  SHIELD, 22 Mbit/s from it.

### B9: Logins: the user's own password, the defaults locked (2026-10-23)

- **`config.sh` names no one's account.** Its `OMARCHY_USER` is `omarchy`.
  A name of your own goes in `config.local.sh`, which git ignores and
  `scripts/lib.sh` reads after `config.sh`.
- **`scripts/20` asks for a new user's password** at the start, twice and
  hidden, and sends it to `chpasswd` through SSH's input, so it appears in
  no command line or log. A user that exists keeps its password, if it has one.
- **`scripts/22` locks Arch Linux ARM's default root and alarm logins**
  once the desktop user has a password and is in wheel. It first checks
  that sshd uses PAM: with `UsePAM yes`, sshd doesn't turn a key away for a
  locked password; without PAM it does. (This OpenSSH's `sshd -T` prints
  `UsePAM`, not `usepam`.) A timer on the SHIELD unlocks root after 2
  minutes unless a new SSH login gets in. On this SHIELD: root and alarm
  locked, devsecai with a password; a new key login worked, and the timer
  was stopped.
- **What it costs:** no root login at the TV (the desktop user's sudo
  instead), and systemd's emergency shell, which asks for root's password,
  won't open.
- **After n-codex's audit** (`research/ncodex-docs-audit-review.md`):
  - `scripts/22` asks you to confirm the desktop user's password is one you
    chose (`CONFIRM_OWN_PASSWORD=yes` answers for you), since a password's
    existence says nothing about who chose it.
  - It stops the unlock timer and its service and checks both are gone. It
    locks root again, in case the unlock ran meanwhile, and fails unless
    root reads locked.
  - Neither script works on root, alarm or a system account (UID below
    1000), and an SSH failure while checking the user stops them, rather
    than being taken for a missing user.
  - `scripts/20` sets a password for an existing user that has none, as a
    run cut off between `useradd` and `chpasswd` would leave.
  - `scripts/lib.sh` refuses an `OMARCHY_USER` that isn't a plain account
    name, since it goes into commands run as root.

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
