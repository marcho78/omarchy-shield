# Review request: first mainline Linux boot on the SHIELD TV 2017 (darcy)

**Analysis only.** Don't run adb or fastboot, and don't edit any repo file.
Write your full answer as Markdown to the output path in your prompt, then
reply with only that path. Aim for about 10 minutes, and keep it concrete:
cite file:line, and give a fix for each finding.

All paths below are relative to `~/projects/nvidia`.

## Where we are

- **Device:** SHIELD TV 2017 "darcy", board P2894-0050-a08, Tegra X1 (T210),
  3 GB RAM. The bootloader is unlocked.
- **Working boot chain:**
  1. cboot starts our U-Boot, booted from the recovery partition. U-Boot is
     v2025.07, the LineageOS tree plus `patches/u-boot/0001-*.patch`, and
     sits in the boot image's kernel slot.
  2. U-Boot shows its console on HDMI, using the framebuffer that cboot's
     display left running:
     - display controller A, window A
     - address 0x92cc3000, 1920x1080, stride 7680, format a8b8g8r8
     - output on SOR1/HDMI
     - see `dc_framebuffer()` in
       `vendor/lineage-u-boot/board/nvidia/p2894/p2894.c`
  3. U-Boot runs `bootm` on a FIT image carried as the boot image's ramdisk.
     cboot loads it at 0x84100000.
- **Memory banks from cboot,** which U-Boot passes on to Linux:
  0x80000000+0x1f200000, 0xa0000000+0x5ee00000, 0x100000000+0x40000000. The
  framebuffer lies inside bank 0.
- **PMC:** secure-only. The stock DT has `nvidia,secure-pmc`, and Linux 7.2
  detects the TZ-only PMC on T210 by itself.
- **U-Boot env:** `fdt_high` is cleared before `bootm`, so the FDT gets
  relocated. `initrd_high=ffffffffffffffff`, so the initramfs is used in
  place inside the FIT.
- **Debug channel:** only the TV. No UART is wired. If the display dies we
  are blind, and every test costs the user a manual cycle.

## The test we are about to run

The FIT (`kernel/darcy.its`) holds three things:
- **Kernel:** mainline Linux 7.2.11 (`vendor/linux`). The config is
  `build/linux/.config`: arm64 defconfig with every platform but ARCH_TEGRA
  off, plus `kernel/darcy.config`. It is built in only, with no modules
  (DRM_TEGRA and HOST1X are `=m`, so they are absent). Image.gz is loaded at
  0x80200000. The Image is 26 MB, with `image_size` 0x1980000.
- **Device tree:** `kernel/dts/darcy.dts`, which is mainline
  `tegra210-p2894-0050-a08.dts` plus bootargs and a ramoops node.
- **Initramfs:** its `/init` is `tools/darcy-init.c`.

Builds: `scripts/11-build-kernel.sh` and `scripts/12-make-payload.sh`.

`ft_board_setup()` in p2894.c adds a `/framebuffer@92cc3000`
simple-framebuffer node for Linux. The expected result is the kernel log on
the TV through simpledrm and fbcon, then darcy-init's banner.

## Already changed this round (please verify)

1. The framebuffer used to be reserved with a `/memreserve/`, which leaves
   it in the linear map. arm64 `ioremap` refuses linear-mapped RAM
   (`arch/arm64/mm/ioremap.c`), so simpledrm would fail. It is now a
   `/reserved-memory/framebuffer@92cc3000` node with `no-map`, added with
   `fdtdec_add_reserved_memory()` into the `/reserved-memory` node our
   darcy.dts already has.
2. Bootargs gained:
   - `regulator_ignore_unused`: the `vdd-hdmi` 5V fixed regulator
     (GPIO CC7) is `regulator-boot-on` but not always-on, so the
     regulator late cleanup would switch it off 30 s after boot.
   - `consoleblank=0`

   `clk_ignore_unused` and `pd_ignore_unused` were already there.

## Questions

1. **What else could break this boot?** Two failure modes:
   - (a) something kills the HDMI console that Linux inherits through
     simpledrm. With only the built-in drivers in `build/linux/.config`,
     think of anything that resets or reclocks DC A, SOR1, DPAUX, host1x,
     PLL_D/PLL_D2/PLL_DP, the MC/SMMU (TEGRA_IOMMU_SMMU=y, TEGRA_MC=y),
     pinmux, the MAX77620 PMIC, or the XUSB/PCIe drivers.
   - (b) the boot hangs or crashes before or after simpledrm takes over.
     Think of DFLL/cpufreq, PSCI/cpuidle, memory map, initrd, FDT
     placement, and so on.

   Rank what you find by likelihood. For each, give evidence and a fix.
2. **Are the two changes above correct and enough?**
3. **Later, a no-soldering debug channel:** which one is most practical?
   Keep this brief.
   - pstore/ramoops read back from Android as the shell user, e.g.
     `dumpsys dropbox --print SYSTEM_LAST_KMSG`. The stock DT
     (`recovery/9.1.1/blob-parts/13-DTB.dts`, `ramoops_carveout`) has
     0xb0000000, 2 MB, `compatible = "nvidia,ramoops"`, `no-map`. The stock
     zone layout lives in NVIDIA's kernel and is unknown.
   - a USB gadget console (tegra-xudc) on the USB port farthest from HDMI,
     which is the one the laptop uses for fastboot.
   - anything better.

`NOTES.md` has the full device log, including U-Boot's on-screen report.
