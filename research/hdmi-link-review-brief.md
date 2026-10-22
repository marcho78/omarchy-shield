# Review request: the HDMI link drops about 1.5–2 s into mainline Linux on darcy

**Analysis only.** Don't run adb or fastboot, and don't edit any repo file.
Write your answer as Markdown to the output path in your prompt, then reply
with only that path. Aim for about 15 minutes, and cite file:line.

Several models get this same brief in parallel. Be concrete; an independent
read is worth more than agreeing with the hypotheses below.

All paths are relative to `~/projects/nvidia`. Background:
- `NOTES.md`, the sections from "Boot chain design" to "Run 3"
- `research/*hdmi-black*`, the previous round of reviews

## Setup

SHIELD TV 2017 "darcy": Tegra X1 (T210), 3 GB RAM, unlocked bootloader.

**Boot chain:**
1. cboot loads our U-Boot from the recovery slot. U-Boot is
   `vendor/lineage-u-boot` plus `patches/u-boot/0001-*.patch`; the board
   code is `board/nvidia/p2894/p2894.c` inside that tree.
2. U-Boot runs `bootm` on a FIT image holding:
   - mainline Linux 7.2.11 (`vendor/linux`, config `build/linux/.config`,
     built in only, no modules; DRM_TEGRA and HOST1X are modules, so they
     are absent)
   - our DT, `kernel/dts/darcy.dts`, on top of mainline
     `tegra210-p2894-0050-a08.dts`
   - an initramfs whose `/init` is `tools/darcy-init.c`

**Display:**
- cboot drives HDMI on display controller A (window A) and SOR1. The
  framebuffer is at 0x92cc3000, 1080p, a8b8g8r8.
- The stock DT says the HDMI pixel clock parent is `pll_d2`.
- U-Boot hands the framebuffer to Linux as a simple-framebuffer, reserved
  `no-map`.
- Bootargs include `clk_ignore_unused pd_ignore_unused
  regulator_ignore_unused cpuidle.off=1`.

**Log channel:**
1. Before the kernel starts, U-Boot sets the PMC "recovery" reboot reason
   and arms the watchdog.
2. darcy-init reboots into recovery after 60 s.
3. U-Boot then prints the last 56 lines of the kernel's console log from
   ramoops on the TV.

This path is proven working.

## What we know after 3 runs

**Linux runs fully:** 4 CPUs, 2.9 GB of RAM, the eMMC, and darcy-init.

Key log lines, with times in seconds (the same in all runs):

```
0.000 OF: reserved mem: 0x92cc3000..0x934abfff (8100 KiB) nomap non-reusable framebuffer@92cc3000
0.000 tegra-clk-debug: pll_a_out0_out_adsp / dmic1..3_sync_clk_mux: connection ID is greater than 16
0.075 smp: Bringing up secondary CPUs ...
0.118 iommu: DMA domain TLB invalidation policy: strict mode
0.156 tegra-pmc: access to PMC is restricted to TZ
0.156 tegra-pmc 7000e400.pmc: i2c-thermtrip node not found, emergency thermal reset disabled.
1.403 [drm] Initialized simpledrm 1.0.0 for 92cc3000.framebuffer on minor 0
1.445 Console: switching to colour frame buffer device 120x33
1.472 simple-framebuffer 92cc3000.framebuffer: [drm] fb0: simpledrmdrmfb frame buffer device
1.722 cpufreq-tegra124 cpufreq-tegra124: probe with driver cpufreq-tegra124 failed with error -2
1.735 failed to register cpuidle driver
1.854 reg-fixed-voltage regulator-max77620-gpio7: nonexclusive access to GPIO ...
1.883 irq: IRQ74: trimming hierarchy from :pmc@7000e400
12.07 tegra-mc / tegra-pmc: sync_state() pending due to actmon / host1x / mipi
33.81 regulator: Not disabling unused regulators
```

There are no "SMC failed" lines. darcy-init only sees lines matching its
keywords (error, fail, warn, drm, simple, regulator, pmc, and so on), so
other lines in the 1.4–2.0 s window are not visible to us.

**What the user saw:** U-Boot's text, then a **flicker** (we think the
console taking over at 1.45 s), then the TV said **"No signal"** until the
reboot. Once cboot and U-Boot run again, HDMI works. So the TMDS link
itself stops, not just the picture.

**Run 3 applied the stock PMIC values,** with no change in the result:
- sd2 at the stock 1.35–3.0 V range
- PMIC GPIO1 sequencer source NONE

The regulator dump confirms:
- `vdd-pre-reg` is at 1,350,000 µV, with no "Bringing" line.
- All the HDMI rails are on: `vdd-hdmi-dp` (ldo8, avdd_hdmi) 1.05 V,
  `vdd-gen-pll-edp` (ldo7) 1.05 V, `vdd-1v8` (sd3, avdd_hdmi_pll) 1.8 V,
  `vdd-sys-boost` 5 V.
- The `vdd-hdmi` (CC7, HDMI 5V) and `vdd-fan` nodes are disabled in our DT,
  so Linux never touches CC7.

## The run about to happen (commit aa661a8; see `git show aa661a8`)

**U-Boot**, in `report_display_hw()` in p2894.c, prints cboot's state.
**darcy-init**, in `show_display_hw()`, prints the same lines under Linux:
- each display block's CAR clock-enable and reset bit: DISP1 27, DISP2 26,
  HOST1X 28, DSIA 48, MIPI_CAL 56, DPAUX 181, SOR0 182, SOR1 183, DPAUX1
  207, SOR_SAFE 222
  - bank = id / 32, bit = id % 32
  - CLK_OUT_ENB L/H/U/V/W/X/Y = 0x010/0x014/0x018/0x360/0x364/0x280/0x298
  - RST_DEVICES = 0x004/0x008/0x00c/0x358/0x35c/0x28c/0x2a4
- the raw PLLD_BASE 0x0d0, PLLD2_BASE 0x4b8 and PLLDP_BASE 0x590
- CLK_SOURCE_DISP1 0x138 and CLK_SOURCE_SOR1 0x410
- DC A's DC_CMD_DISPLAY_COMMAND, DC_CMD_DISPLAY_POWER_CONTROL,
  DC_CMD_STATE_CONTROL and DC_DISP_DISP_CLOCK_CONTROL, only while DISP1 is
  clocked and out of reset

darcy-init reads these from `/dev/mem`: STRICT_DEVMEM is on, and
IO_STRICT_DEVMEM is off.

darcy-init also prints three views from inside Linux:
- `/sys/kernel/debug/powergate`, the PMC's yes/no per partition, read
  through the TZ SMC
- `pm_genpd_summary`
- the `clk_summary` rows for pll_d, pll_d_out0, pll_d2, pll_d2_out0,
  pll_dp, disp1, sor1, sor1_out, sor_safe, host1x and dpaux1

## Questions

1. **Your top hypotheses** for what stops the HDMI link after the console
   takes over. Rank them, and point at code in `vendor/linux` that runs in
   this window with only built-in drivers. Candidates we have not
   excluded:
   - the PMC registering powergates and asserting the `pd_sor` resets
     (SOR0/SOR1/DPAUX/DPAUX1/MIPI_CAL/DSI) if its SMC read reports `sor`
     as off
   - Tegra210 clock init or the init table (PLL_DP to 270 MHz, HOST1X
     reparenting), or PLL defaults
   - the MC, SMMU or latency allowance
   - pinctrl clearing parked bits
   - XUSB padctl or other built-in drivers
   - anything else

   For each, say what it would look like in the dump above.
2. **Review the diagnostics** (`git show aa661a8`, plus the U-Boot patch
   diff). Are the register offsets and clock IDs right for T210? Could any
   read hang the CPU? Is there a parsing bug?
3. **What else should this run capture**, so the next photo pinpoints the
   cause in one go? The U-Boot screen shows the last 56 log lines.
4. **Is there a candidate fix** we could add to the same image without
   confusing the diagnosis? Or should this run stay purely diagnostic?
