# Review: first mainline Linux handoff on darcy

Analysis only. Nothing was flashed and no repo file was edited. Line numbers are from the tree as it sits now. Guesses are marked UNCERTAIN.

`clk_ignore_unused` and `pd_ignore_unused` still have to stay. DC A (`dc@54200000`) and DC B have no `status` in `tegra210.dtsi` (192–220), so they are enabled, but `CONFIG_DRM_TEGRA=m` and `CONFIG_TEGRA_HOST1X=m` (`build/linux/.config` 5060, 5353) mean no driver claims DISP1, SOR, PLL_D, or `pd_sor`. SOR1 itself is `status = "disabled"` (`tegra210.dtsi:353`). The inherited scanout lives only because those two flags leave cboot's clocks and domains alone. The flags do not stop pinmux, the MAX77620, a regulator GPIO at probe, PSCI idle, or the SMMU.

## 2. The two changes

Both are correct. Neither is enough.

**no-map framebuffer.** `ft_board_setup()` (`p2894.c:440–455`) page-rounds the live window and calls `fdtdec_add_reserved_memory(..., FDTDEC_RESERVED_MEMORY_NO_MAP)`. `fdtdec.c:1421–1424` writes `no-map` and no `compatible`. `fdt_setup_simplefb_node()` (`fdt_support.c:2069`) sets `reg` to `height * stride` bytes, unrounded, under `/framebuffer@<base>`. The kernel still reserves a `reg` node that has no matching reserved-mem driver: `fdt_validate_reserved_mem_node()` returns `-ENODEV`, and `__reserved_mem_reserve_reg()` continues (`of_reserved_mem.c:162–170`). That is the right fix for arm64 refusing to `ioremap` linear RAM. Do not go back to `/memreserve/`.

Three holes remain:

- Either call failing is only a `printf` (`p2894.c:456`). `ft_board_setup()` still returns 0, and Linux boots with no console.
- The simplefb node and the reserved node are not linked. `phandlep` is NULL (`p2894.c:454`). That matches other U-Boot boards and works because reserved-mem runs before simpledrm maps the buffer. There is no second chance if the reserved node is missing.
- p2894 does not call `ft_carveout_setup()`. p2371, p2771, and p3450 do (`p2371-2180.c:95`). cboot's other carveouts are not copied. The three banks already omit cboot's holes, and the live window is the only extra reservation this board adds. VPR and the rest of the fb carveout stay unmapped only because they are outside those banks.

`/memory@80000000` in the FIT is still one 3 GB bank, `0x80000000/0xc0000000` (`tegra210-p2894.dtsi:19–22`), which covers the hole. U-Boot should replace it: `CONFIG_ARCH_FIXUP_FDT_MEMORY=y`, `CONFIG_NR_DRAM_BANKS=8` (`build/u-boot/.config`), `cboot_dram_init_banksize()` (`board2.c:390`), `arch_fixup_fdt()` (`bootm-fdt.c:43–54`). Confirm with the on-screen meminfo. If that fixup did not run, Linux allocates in the hole and dies before simpledrm. Fix: leave the banks as cboot published them. Do not write the 3 GB node into `darcy.dts`.

**Bootargs.** `vdd-hdmi` is `regulator-boot-on` and not `regulator-always-on`, GPIO CC7 active-high, vin `vdd_sys_boost` (`tegra210-p2894.dtsi:1719–1730`). Nothing consumes it, because the SOR driver is absent. Late unused cleanup (~30 s) would drop HDMI 5 V. `regulator_ignore_unused` is the right blunt fix. `consoleblank=0` is the right fix for fbcon. Keep all four ignore flags and `console=tty0` last (`darcy.dts:20`).

## 1. What else can kill this boot

Ranked. (a) is a dead TV while the CPU may still be running. (b) is a hang or a reset.

### 1. MAX77620 probe — (a) and (b), highest

`i2c@7000d000` and `pmic@3c` are `status = "okay"` (`tegra210-p2894.dtsi:1329–1334`). `CONFIG_MFD_MAX77620=y` and `CONFIG_REGULATOR_MAX77620=y`. The driver will write the DT's FPS setup at probe. `regulator_ignore_unused` runs much later and does not stop that.

- `sd0` / `vdd-core` is always-on and boot-on, FPS source 1 (`1420–1430`). A glitch here hangs the CPU. Frozen last frame.
- `sd2` / `vdd-pre-reg` is the input for LDO7/8 (`1418`, `1443–1452`), same FPS source.
- `ldo8` / `vdd-hdmi-dp` is the 1.05 V HDMI PHY rail, always-on, FPS source 1 (`1558–1568`). A glitch blanks HDMI and leaves the CPU up.
- The hog forces PMIC gpio2 and gpio7 output-high (`1368–1372`). gpio7 is also `regulator-max77620-gpio7` (`1660–1671`). The hog and the regulator fight over one pin. UNCERTAIN which one wins; neither is the Tegra CC7 HDMI-5 V pin.

Fix for this boot: in `darcy.dts`, set `i2c@7000d000` (or just `pmic@3c`) to `status = "disabled"`. cboot already programmed the rails.

### 2. PSCI cpu-sleep — (b)

`tegra210.dtsi:2060–2068` defines `cpu-sleep` with `arm,psci-suspend-param = <0x40000007>` and `status = "disabled"`. `tegra210-p2894.dtsi:1614–1617` turns it okay. Every CPU points at it (`tegra210.dtsi:2053`). `CONFIG_ARM_PSCI_CPUIDLE=y` and `CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y`. `darcy-init` sleeps 30 s (`tools/darcy-init.c:78–80`), and the kernel idle thread sleeps earlier than that.

cboot's monitor often does not implement that suspend the way mainline expects. UNCERTAIN that this 2019 cboot hangs rather than returning `NOT_SUPPORTED`. The symptom if it hangs is the last HDMI frame frozen, because the DC is not what stopped. That can be before simpledrm (looks like a stuck U-Boot console) or after the banner.

Fix: in `darcy.dts`, set `cpu-sleep` back to `status = "disabled"`, and add `cpuidle.off=1` on the command line. Do both. The DT status is what creates the idle state; the command line covers the governor if a state still appears.

### 3. Pinmux `state_boot` — (a)

`pinmux@700008d4` is okay with `pinctrl-0 = <&state_boot>` (`tegra210-p2894.dtsi:24–27`). `CONFIG_PINCTRL_TEGRA210=y`, so that state is applied at probe. The HDMI TMDS pins are not in this table (only `hdmi_cec_pcc0`, `hdmi_int_dp_hpd_pcc1`, `dp_hpd0_pcc6`). The data pins stay as cboot left them.

What does change:

- `hdmi_int_dp_hpd_pcc1` (`1150–1157`): pull-down, input enabled, no function. HPD is driven by the sink. A weak pull-down should not make the TV drop an already-running link, and no DRM driver is watching HPD. Low by itself.
- `pcc7` (`1200–1207`): pull none, tristate off, input disabled, no `nvidia,function`. This is GPIO CC7, the `vdd-hdmi` enable (`1728`). The pin is forced driven before `regulator-fixed` claims it. UNCERTAIN whether the output latch stays at cboot's high. If it drops, HDMI 5 V dies, the scanout hardware keeps running, and the TV goes black.

Fix: in `darcy.dts`, set the pinmux node `status = "disabled"` for this boot so cboot's mux stands. Do not edit individual groups first.

Also disable the fixed regulators that are not boot-on and drive a GPIO low at probe. They do not feed HDMI, and they do kill the USB port you will want later:

- `usb_vbus1` GPIO CC5, `usb_vbus2` GPIO CC4 (`1800–1820`)
- `en_vdd_sd` GPIO Z4 (`1685–1695`), `en_vdd_cam` GPIO S4 (`1697–1705`), `vdd_fan` GPIO E4 (`1789–1798`)

Leave `vdd-hdmi` enabled only together with the pinmux disable, so CC7 can be a GPIO and the boot-on request drives it high. If the pinmux stays, disable `vdd-hdmi` too and rely on cboot's 5 V. `regulator_ignore_unused` still covers `lcd_bl_en` (GPIO V1, boot-on, not always-on, `1674–1683`).

### 4. SMMU enable plus TLB flush — (a), UNCERTAIN

`memory-controller@70019000` has no `status = "disabled"` (`tegra210.dtsi:1021–1031`). `CONFIG_TEGRA_MC=y` and `CONFIG_TEGRA_IOMMU_SMMU=y`. `tegra_smmu_probe()` writes the PTC and TLB config, flushes both, then sets `SMMU_CONFIG_ENABLE` (`drivers/iommu/tegra-smmu.c:1147–1164`). DC A has `iommus = <&mc TEGRA_SWGROUP_DC>` (`tegra210.dtsi:201`) but no driver attaches it.

Per-client translation is normally enabled only when a driver attaches. If cboot left the DC in bypass, pointing the window at physical `0x92cc3000`, this flush does not blank the screen. If cboot had the DC translating through the SMMU, the flush drops that mapping and the scanout faults. UNCERTAIN which this cboot does. `clk_ignore_unused` does not help. MC hotreset is only asserted when a reset consumer asks (`mc.c:228`); host1x is a module, so it will not ask.

Fix if the picture dies as MC probes: set the `mc` node `status = "disabled"` for this image, or build without `CONFIG_TEGRA_IOMMU_SMMU`. Disabling `mc` also drops its reset controller, which this boot does not use.

### 5. Earlycon on UART-A — (b), lower

`serial@70006000` is okay (`tegra210-p2894.dtsi:1323–1327`). Bootargs have `earlycon=uart8250,mmio32,0x70006000` and `console=ttyS0,115200n8` (`darcy.dts:20`). `CONFIG_SERIAL_8250=y` and `CONFIG_SERIAL_8250_TEGRA=y`. The UART has nowhere to go. That is harmless if the clock and pins come up. A pinmux or clock stall on UART-A hangs before simpledrm, with the old HDMI frame still scanning out.

Fix: drop `earlycon` and `console=ttyS0` for this boot. Keep `console=tty0` last so `darcy-init` writes the TV.

### 6. Things that look scary and are not this boot

- **PCIe, XUSB, padctl, DFLL.** `pcie@1003000` disabled (`tegra210.dtsi:59`). `xusb` disabled (`1113`). `padctl@7009f000` disabled (`1124`). `dfll@70110000` disabled (`1440`). p2894 does not turn them on. `CONFIG_PCI_TEGRA=y`, `CONFIG_USB_XHCI_TEGRA=y`, and `CONFIG_PHY_TEGRA_XUSB=y` have nothing to bind. The board DTS has no `operating-points-v2`, so `CONFIG_CPUFREQ_DT=y` and `CONFIG_ARM_TEGRA20_CPUFREQ=y` should not move Vdd-CPU. Add `cpufreq.off=1` only if a hang lines up with cpufreq.
- **eMMC.** `mmc@700b0600` is okay (`1585–1588`) and `CONFIG_MMC_SDHCI_TEGRA=y` will probe it. That can delay boot. It should not blank HDMI.
- **Watchdog.** `CONFIG_TEGRA_WATCHDOG` is not set (`build/linux/.config:4251`). `CONFIG_WATCHDOG=y` has no Tegra driver to bind. U-Boot already sits on HDMI, so cboot's watchdog is petted or stopped. If the picture freezes a few seconds after Linux starts and USB comes back as fastboot, look again; it is not the built-in Tegra driver.
- **Logo.** `CONFIG_LOGO=y` paints the inherited FB. Ugly, not fatal. `CONFIG_SYSFB=y` but `CONFIG_SYSFB_SIMPLEFB` is not set, so sysfb will not bind a second firmware FB. Unset `CONFIG_LOGO` when convenient.
- **FIT layout.** Image load `0x80200000`, `image_size` `0x1980000`, so the image ends at `0x81b80000`. cboot DTB is `0x83100000`, FIT is `0x84100000`, FB is `0x92cc3000`. No overlap. Initrd is gzip bytes with `compression = "none"` (`kernel/darcy.its:41–47`) and `CONFIG_RD_GZIP=y`. U-Boot's `initrd_high` is already `ffffffffffffffff` (`tegra-common-post.h:54`), and `darcy_boot` clears `fdt_high` (`p2894.env:13`) so the FDT is relocated before `ft_board_setup` adds the no-map. `CONFIG_VIDEO_SIMPLE=y`, so the live FB should already be out of U-Boot's allocation. UNCERTAIN only if `video_bottom` was never set; the symptom would be the screen corrupting at "Booting the FIT", before Linux. `fdt_add_fb_mem_rsv()` (`fdt_support.c:2103–2117`) can add a second no-map of `video_bottom..top`. Harmless when the range matches.
- **PMC.** `maybe_tz_only` is true for Tegra210 (`pmc.c:3874`) and probe detects TZ-only (`2931`, `2961–2962`). Direct PMC writes are skipped when that flag sticks (`534`). The Jetson suspend timings on `pmc@7000e400` (`tegra210-p2894.dtsi:1573–1582`) are not a reason to hold this boot.

## What to change before the first Linux boot

In `darcy.dts` only, on top of the two changes already made:

1. `pinmux@700008d4` `status = "disabled"`.
2. `i2c@7000d000` `status = "disabled"`.
3. `cpu-sleep` `status = "disabled"`.
4. Bootargs: add `cpuidle.off=1`, drop `earlycon` and `console=ttyS0`, keep `console=tty0` last, keep `consoleblank=0` and the four ignore flags.
5. `ramoops@b0000000`: add `no-map` (see below).
6. Disable `usb_vbus1`, `usb_vbus2`, `en_vdd_sd`, `en_vdd_cam`, and `vdd_fan`.

Do not enable PCIe, XUSB, padctl, or a USB gadget on this image. If the TV dies at the MC probe and the CPU is clearly still up, the next image disables `memory-controller@70019000`.

## 3. Debug channel after this boot

The TV is the channel for this boot. Do not add USB to the image whose job is to keep HDMI.

If that boot dies, the next no-solder step is ramoops at the stock `0xb0000000` / 2 MB hole. The node is already there (`darcy.dts:29–35`) with mainline `compatible = "ramoops"`, a 1 MB console zone, and no `no-map`. Stock is `compatible = "nvidia,ramoops"` plus `no-map` (`recovery/9.1.1/blob-parts/13-DTB.dts:936–939`). The stock zone layout was not read and lives in NVIDIA's kernel. `dumpsys dropbox --print SYSTEM_LAST_KMSG` is best-effort only. UNCERTAIN that Android will parse a mainline layout. Add `no-map` so the reservation matches the carveout and the region stays out of the linear map; that does not fix the parser. pstore also cannot show a hang that never flushes. `CONFIG_PSTORE=y`, `CONFIG_PSTORE_RAM=y`, and `CONFIG_PSTORE_CONSOLE=y` are already set, and `darcy-init` mounts `/sys/fs/pstore`.

A USB gadget console on the far port (tegra-xudc) is the right live channel later, not on this boot. `CONFIG_USB_TEGRA_XUDC=m` and `CONFIG_USB_CONFIGFS=m` (`build/linux/.config:6554`, `6572`), so this built-in image has no gadget function. The xusb and padctl nodes are disabled. The fixed `usb_vbus*` regulators would drive VBUS off if left enabled. Bring the gadget up only after a boot that has shown the TV, with padctl proven not to kill the port, and with those VBUS regulators left as cboot set them.

No wired UART.
