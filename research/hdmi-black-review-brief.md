# Review request: HDMI goes black about 1.8 s into mainline Linux on darcy

**Analysis only.** Don't run adb or fastboot, and don't edit any repo file.
Write your answer as Markdown to the output path in your prompt, then reply
with only that path. Aim for about 10 minutes, and cite file:line.

All paths below are relative to `~/projects/nvidia`. Background is in
`research/linux-handoff-review-brief.md` and `NOTES.md`.

## New facts

We recovered the kernel log through ramoops. darcy-init reboots into
recovery, and U-Boot shows the log.

**Linux 7.2.11 boots fully:** 4 CPUs, 2.9 GB of RAM, the eMMC is detected,
and darcy-init runs for 60 s and reboots. Selected lines, with times in
seconds:

```
0.000  OF: reserved mem: 0x92cc3000..0x934abfff (8100 KiB) nomap non-reusable framebuffer@92cc3000
0.000  OF: reserved mem: 0xb0000000..0xb01fffff (2048 KiB) nomap non-reusable ramoops@b0000000
0.000  psci: MIGRATE_INFO_UP_CPU reported invalid physical ID (0x80000000)
0.000  tegra-clk-debug: pll_a_out0_out_adsp / dmic1..3_sync_clk_mux: connection ID is greater than 16
0.118  iommu: DMA domain TLB invalidation policy: strict mode
0.159  tegra-pmc: access to PMC is restricted to TZ
0.159  tegra-pmc 7000e400.pmc: i2c-thermtrip node not found, emergency thermal reset disabled.
1.405  [drm] Initialized simpledrm 1.0.0 for 92cc3000.framebuffer on minor 0
1.449  Console: switching to colour frame buffer device 120x33
1.475  simple-framebuffer 92cc3000.framebuffer: [drm] fb0: simpledrmdrmfb frame buffer device
1.713  cpufreq-tegra124 cpufreq-tegra124: probe with driver cpufreq-tegra124 failed with error -2
1.723  failed to register cpuidle driver            (cpuidle.off=1)
1.842  reg-fixed-voltage regulator-max77620-gpio7: nonexclusive access to GPIO for (default) ...
1.871  irq: IRQ74: trimming hierarchy from :pmc@7000e400
12.05  tegra-mc / tegra-pmc: sync_state() pending due to actmon / host1x / mipi
33.81  regulator: Not disabling unused regulators
```

There are no "SMC failed" warnings. darcy-init's filter would have caught
any line containing "fail".

**Yet the TV goes black.** The user saw loading text, then the screen went
out. Back in cboot and U-Boot, HDMI works again.

## Hypothesis: the MAX77620 probe, around 1.8 s, breaks the HDMI power path

The MAX77620 PMIC setup in mainline (`tegra210-p2894.dtsi`, the pmic@3c
node, about lines 1330–1560) differs from the stock darcy DT
(`recovery/9.1.1/blob-parts/13-DTB.dts`, max77620, about line 6794) in only
two places:

1. **`sd2` "vdd-pre-reg".**
   - Mainline sets min = max = 3,000,000 µV, so the regulator core applies
     3.0 V at registration.
   - Stock sets 1,350,000 to 3,000,000 µV, so stock Linux never changes
     cboot's value.
   - Mainline Jetson TX1 (`p2180`), Jetson Nano (`p3450`) and Pixel C
     (`smaug`) all use 1.35 V for this rail.

   sd2 is `in-ldo0-1-supply` and `in-ldo7-8-supply`:
   - `ldo8` vdd-hdmi-dp, 1.05 V
   - `ldo7` vdd-gen-pll-edp, 1.05 V
   - `ldo0` avdd-sys, 1.2 V
   - `ldo1` vdd-pex, 1.075 V
2. **PMIC GPIO1** (pinmux `fps-out`).
   - Mainline sets `maxim,active-fps-source = MAX77620_FPS_SRC_0`.
   - Stock sets SRC_NONE (3).

   GPIO1 enables `vdd-sys-boost`, the 5V boost that feeds HDMI 5V. HDMI 5V
   itself is switched by Tegra GPIO CC7; our DT disables `vdd-hdmi` so Linux
   leaves that pin alone.

Everything else matches:
- every sd and ldo FPS source, voltage and always-on/boot-on flag
- the fps0/1/2 event sources
- gpio2/3/4/5–7
- the hog on PMIC gpio2 and gpio7

## Planned fix, in `kernel/dts/darcy.dts`

```dts
&max77620_sd2 { regulator-min-microvolt = <1350000>; };   /* stock's range */
&max77620_default { gpio1 { maxim,active-fps-source = <MAX77620_FPS_SRC_NONE>; }; };
```

darcy-init will also print `/sys/class/regulator`: name, microvolts and
state. The next log then shows sd2's real voltage.

## Questions

1. **Is the PMIC the most likely cause?** In particular:
   - the MAX77620 N-type LDO (ldo0/1/7/8) input limits against 3.0 V
   - what happens to ldo7 and ldo8 then
   - drivers/regulator/max77620-regulator.c and drivers/regulator/core.c
     behaviour at registration
2. **The GPIO1 sequencer change.** What does a MAX77620 GPIO in `fps-out`
   mode do when its FPS source changes from NONE to SRC_0 while FPS0 is
   active (EN0 asserted)? See drivers/pinctrl/pinctrl-max77620.c. Can the
   output glitch low?
3. **Anything else** at probe time, about 1.45–2 s, or later, that could
   blank HDMI?
4. **Is the planned fix safe and enough?** Should anything else change, for
   example disabling the PMIC node for one boot instead?
