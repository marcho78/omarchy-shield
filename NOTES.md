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

**Decision (2026-10-22): the root filesystem goes on the internal eMMC.**
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
