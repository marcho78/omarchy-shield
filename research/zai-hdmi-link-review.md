# Review: the HDMI link drops ~1.5–2 s into mainline Linux on darcy

**Verdict up front:** the strongest suspect is not in the 1.4–2.0 s window at
all — it is `tegra_powergate_add()` powering down the `sor` partition at the
**tegra-pmc probe, 0.156 s** (`drivers/soc/tegra/pmc.c:1365-1385`), asserting
SOR0/SOR1/DPAUX/DPAUX1/DSIA/DSIB/MIPI_CAL resets and gating their clocks
while cboot's HDMI output is still running. The "1.5–2 s" estimate comes
from the TV holding the last frame for ~1.3 s after TMDS dies: the "flicker
at 1.45 s" is almost certainly the held frame expiring, not the fbcon
switch (a console switch in the log cannot be seen on a TV that lost the
link at 0.156 s). I understand n-codex/n-grok reached this independently
(`research/*hdmi-link*`, NOTES) — my read of the 7.2.11 source confirms it;
the fix already in the tree at HEAD (`06ec1f0`, delete `pd_sor` + the nine
`power-domains` references) is the right one and should be sufficient. The
diagnostics commit `aa661a8` is verified correct: every offset, clock ID
and parser checks out against this kernel's source, including the
easy-to-get-wrong DC word-offset convention. Details below; all paths
relative to `~/projects/nvidia`, `vendor/linux` = 7.2.11.

---

## 1. Top hypotheses, ranked

### H1 — `pd_sor` is powered down at the PMC probe, 0.156 s (high confidence)

The chain, in this kernel:

- The PMC device probes at 0.156 s (log: `tegra-pmc 7000e400.pmc:
  i2c-thermtrip node not found`), and `tegra_pmc_probe()` calls
  `tegra_powergate_init()` (`drivers/soc/tegra/pmc.c:3141`), which walks the
  `powergates` children of the PMC node (`pmc.c:1501-1530`).
- Mainline `tegra210.dtsi:921-961` defines ten of them, including
  **`pd_sor`**, whose `clocks`/`resets` lists cover SOR0, SOR1, DSIA, DSIB,
  DPAUX, DPAUX1, MIPI_CAL (`tegra210.dtsi:941-961`).
- For each gate found **on**, `tegra_powergate_add()` —
  `pmc.c:1365-1385` — calls `tegra_powergate_power_down()`, which
  (`pmc.c:1000-1032` region) **enables the clocks briefly, asserts the
  resets, disables the clocks, and switches the partition off**
  (`tegra_powergate_set(pmc, id, false)`; on this board through the secure
  monitor, which succeeded — no "SMC failed" lines). It then registers the
  genpd as off (`pm_genpd_init(&pg->genpd, NULL, true)`).
- cboot left the `sor` partition on (it is driving HDMI), so all three runs
  so far had SOR1 put into reset and unclocked at **0.156 s**. SOR1 cannot
  transmit TMDS through a reset assertion: the link died right there, in
  every run.

Why the user perceives ~1.5–2 s: with no signal, a TV typically holds its
last frame for on the order of a second before declaring "No signal". The
frozen U-Boot/FIT-loading text ("the user saw loading text"), then a flicker
~1.3 s after kernel start, then "No signal" is exactly that pattern. The
coincidence that the flicker lines up with the 1.445 s fbcon switch in the
ramoops log is what pulled attention into the wrong window — note the
console switch did happen and the framebuffer did update (simpledrm logs at
1.403–1.472 s), but nothing of it could reach the TV; the DC kept scanning a
picture into a dead transmitter.

**What it looks like in the aa661a8 dump:** U-Boot side (before the kernel):
`SOR1 1/0`, `SOR0 1/0`, `DPAUX1 1/0`, powergate status bit for `sor` set.
Linux side (had the dump existed then): `SOR1 0/1`, `DPAUX1 0/1` (clock off,
in reset), `/sys/kernel/debug/powergate` reporting `sor no`. One glance, case
closed. **With the `06ec1f0` fix** the expected result is both sides
identical and the screen alive for the full 60 s.

This also cleanly explains why run 3's PMIC fix changed nothing, and why the
regulator dump shows every HDMI supply on: none of that was ever broken.

### H2 — another partition, or a second mechanism if the fix doesn't cure it (low)

If the screen still dies with `pd_sor` deleted, the remaining partitions in
the DT (`aud`, `mpe`, `nvdec`, `venc`, `vic`, `xusba/b/c`, `nvjpg`) get the
same treatment at 0.156 s, but none of their clock/reset lists touch the
display path (`tegra210.dtsi:921-961`), and `pd_dis`/`pd_disb` — the DC
partitions — have **no DT nodes**, so the DC itself is untouched by the PMC.
The dump then points at the next tier: PLLD2/PLLDP registers and the
`clk_summary` rates vs U-Boot's raw values, or the SOR1 source mux.

### H3 — everything else I could check is excluded, with citations

- **Tegra pinmux**: our DT's pinmux node carries its table as a `"boot"`
  state (`tegra210-p2894.dtsi:26-27`), which the pinctrl core never applies
  (only `"default"` is). No device in the DT uses a `"default"` Tegra-pad
  state, so no pinmux register is ever written.
- **XUSB padctl**: `padctl@7009f000` is `status = "disabled"`
  (`tegra210.dtsi:1116-1124`) and the p2894 DT never enables it, so
  `PINCTRL_TEGRA_XUSB`/`PHY_TEGRA_XUSB=y` never bind.
- **Clock init table**: it exists — `clk-tegra210.c:3551-3602` — and does
  reparent HOST1X to PLL_P at 136 MHz, set SCLK to 102 MHz and PLL_DP to
  270 MHz (none on the DISP1/SOR1/PLLD2 path; the stock DT puts the HDMI
  pixel clock on `pll_d2`, unused by the table). It runs as an
  arch_initcall, ~0.1 s; per H1 the transmitter was already dead at
  0.156 s and the table contains no display-path entry in any case.
  Note `tegra210_clk_resume()`'s CLK_OUT_ENB blanket writes
  (`clk-tegra210.c:3492-3498`) are PM-resume-only and never run.
- **gpio-tegra probe**: writes only `GPIO_INT_ENB = 0` per port
  (`drivers/gpio/gpio-tegra.c`, end of `tegra_gpio_probe`); it never touches
  CNF/DDR/OUT, so pin muxing and levels survive (~1.8 s).
- **Fixed regulators probing ~1.85 s**: `usb_vbus1/2` (CC5/CC4) driven low,
  `en_vdd_sd` (Z4), `en_vdd_cam` (S4) low; `vdd_3v3_eth` (D4),
  `vdd_disp_3v0` (I3), `lcd_bl_en` (V1) high. Cross-checked against
  NVIDIA's downstream darcy power tree and GPIO hog lists — all are USB/SD/
  cam/eth pins on this board too (CC1 is the HPD input; CC7, HDMI 5V, is
  correctly left alone by our DT). None is a display pin.
- **SMMU**: T210's SMMU binds to `tegra-smmu`, which programs client
  registers only at attach; no display device attaches. (`ARM_SMMU=y` is
  for T186+ parts and does not match this node.) The 0.118 s "strict mode"
  line is the iommu core.
- **MC**: `tegra210.c` has no `.init`/latency-allowance hook in mainline;
  the MC probe requests IRQs and sets INTMASK only.
- **Late cleanups**: excluded by bootargs (`clk_ignore_unused`,
  `pd_ignore_unused`, `regulator_ignore_unused` — the 33.81 s line confirms)
  and, for the powergates, additionally by
  `GENPD_FLAG_NO_SYNC_STATE` (`pmc.c:1342`); in any case the 12.07 s line
  shows sync_state never fired.

## 2. The diagnostics (`aa661a8` + the U-Boot patch at HEAD) — verified

**Register offsets and clock IDs — all correct:**

| Item | Code | Verified against |
|---|---|---|
| DISP2 26, DISP1 27, HOST1X 28, DSIA 48, MIPI_CAL 56, DPAUX 181, SOR0 182, SOR1 183, DPAUX1 207, SOR_SAFE 222 | both sides | `include/dt-bindings/clock/tegra210-car.h:46-249` |
| CLK_OUT_ENB L/H/U/V/W/X/Y = 0x010/0x014/0x018/0x360/0x364/0x280/0x298; RST = 0x004/0x008/0x00c/0x358/0x35c/0x28c/0x2a4 | both sides | `drivers/clk/tegra/clk.h:13-42` |
| `bank = id/32, bit = id%32` over those seven banks | both | consistent with the L<H<U<V<W<X<Y id order in the header |
| PLLD_BASE 0x0d0, PLLD2_BASE 0x4b8, PLLD2_MISC0 0x4bc, PLLDP_BASE 0x590 | U-Boot | `clk-tegra210.c:87-96` |
| CLK_SOURCE_DISP1 0x138 | both | `clk-tegra-periph.c:78` |
| CLK_SOURCE_SOR1 0x410 | both | `clk-tegra210.c:35` (SOR0 = 0x414 at :36, the pair checks out) |
| DC_CMD_DISPLAY_COMMAND 0x032, DC_CMD_DISPLAY_POWER_CONTROL 0x036, DC_CMD_STATE_CONTROL 0x041, DC_DISP_DISP_CLOCK_CONTROL 0x42e | both | `drivers/gpu/drm/tegra/dc.h:196-395` |
| PINMUX_HDMI_CEC 0x70003198, PINMUX_HDMI_HPD 0x7000319c | U-Boot | mux register bank 2 of the pinmux node (`tegra210.dtsi:585-589`, 0x70003000+0x294) and `pinctrl-tegra210.c:1453-1454` (offsets 0x3198/0x319c) |
| PMC_PWRGATE_STATUS 0x038 (read via `tegra_pmc_readl`) | U-Boot | standard PMC map; the SMC path handles the TZ-only PMC |

**The DC word-offset trap is handled correctly on both sides.** dc.h offsets
are in *word* units: `tegra_dc_readl()` does `readl(dc->regs + (offset <<
2))` (`drivers/gpu/drm/tegra/dc.c`). darcy-init indexes a `uint32_t *`
(`dc[0x032]` → byte 0xC8) and U-Boot's `dc_readl(reg)` is
`readl(DC_BASE + reg * 4)` — both correct, and the 0x2000 mapping covers
0x42e words = 0x10B8 bytes.

**Parsers match the 7.2.11 formats:** `powergate_show` prints
`" %9s %7s"` with `yes/no` (`pmc.c:1228-1242`) — the name/state scan and the
`powergate`/`-` skips are right. genpd summary lives at
`/sys/kernel/debug/pm_genpd/pm_genpd_summary`
(`drivers/pmdomain/core.c:4143-4145`) with the header and device indents the
code skips. `clk_summary` rows always print at least the nine leading
columns the parser requires (name, enable/prepare/protect, rate, accuracy,
phase — `-----` when unsupported, still one token — duty, hardware-enable
Y/N/?; `drivers/clk/clk.c`, `clk_summary_show_one`), so `n < 9` only drops
the header/divider lines; tok[1]/tok[4]/tok[8] are enable/rate/hardware-
enable as the comment says.

**Hang safety:** the only genuinely hang-prone reads are of unclocked
peripheral blocks. The code touches DC only while DISP1 is clocked and out
of reset (both sides) — good. CAR, PLL, pinmux-mux and PMC registers are
always safe, and the PMC read goes through U-Boot's SMC path. `/dev/mem`
with STRICT_DEVMEM on, IO_STRICT_DEVMEM off allows the MMIO maps. One
caution for future additions: if you ever dump SOR1's or DPAUX1's own
registers, guard them the same way on their clock-enable bits first.

**Two nits, neither fatal:** `show_clks` truncates clk_summary rows at 400
bytes (tree depth ×3 + 35-char names fit, fine), and `show_display_hw`'s
`map_regs` returns `MAP_FAILED` as NULL for DC while CAR was already
checked — consistent.

## 3. What else this run should capture

The run is already well-instrumented; three cheap additions, all
log-output only:

1. **`initcall_debug` on the cmdline.** The biggest blind spot is that
   darcy-init's keyword filter hides silently-probing drivers, and U-Boot
   only shows the last 56 lines. `initcall_debug` timestamps every initcall
   and driver probe, which pins the exact ordering around the PMC probe —
   and costs nothing behaviorally. (The early lines won't fit in U-Boot's
   56-line tail, but darcy-init's `show_highlights` could re-print the
   0.0–2.5 s slice of dmesg verbatim; the console zone in ramoops is 1 MB.)
2. **Expected-result checklists on screen**: nothing to add — but when you
   transcribe the photo, record SOR1/SOR0/DPAUX1 clock+reset bits on both
   sides, the `sor` line of the powergate views on both sides, and PLLD2
   BASE+MISC0 on both sides. Those six fields decide H1 vs H2 outright.
3. **If the screen now survives**: grab one photo of the report anyway; the
   "both sides identical" capture is the reference for every future
   bring-up regression (HDMI, GPU, USB).

Deliberately *not* recommended for this run: raw SOR1/DPAUX1 register dumps
(hang risk without clock guards — belongs in a follow-up with the guard
pattern already proven on DC).

## 4. Candidate fix in the same image?

There already is one: HEAD is `06ec1f0` ("Keep the SOR power partition away
from the PMC driver"), which deletes the `pd_sor` node and the nine
`power-domains = <&pd_sor>` references (`kernel/dts/darcy.dts:96-149`). That
is precisely targeted at H1 — the mechanism in `tegra_powergate_add()`
applies only to powergates that have DT nodes, and with the node gone the
PMC never touches the partition, clocks or resets; the other ten gates keep
their harmless-at-boot treatment. It does not muddy the diagnosis: if the
picture lives, the six fields in §3.2 confirm nothing else moved; if it
still dies, the same dump shows what did. Two notes:

- The commit message's claim is confirmed by source — for the record, my
  first pass at `tegra_powergate_add()` read only its tail and missed the
  power-down block; the full function (`pmc.c:1365-1385`) powers down gates
  found on, and asserts resets for gates found off. Credit n-codex/n-grok.
- Deleting `pd_sor` is the right *interim* state only: when tegra-drm lands
  it must come back so the driver owns the partition (the dts comment
  already says this). Also expect a latent surprise: once a real display
  driver exists, the ten remaining partitions will still be power-cycled at
  PMC probe — fine now, worth remembering then.

One thing I would *not* bundle: any additional mitigations (clock
`critical` flags, extra `status = "disabled"`, SMMU/MC nodes). The fix and
the diagnostics as they stand give a clean yes/no on H1 with a fallback
differential in the same photo. Keep `initcall_debug` (§3.1) as the only
addition — it changes logging only.

---

### TL;DR

- The link most likely dies at **0.156 s**, not 1.5–1.9 s:
  `tegra_powergate_add()` (`pmc.c:1365-1385`) powers down the DT `pd_sor`
  partition found on — asserting SOR1/DPAUX1 resets and gating their clocks
  — while cboot's HDMI transmitter is live. The TV's ~1.3 s last-frame hold
  produced the misleading "flicker at console takeover".
- HEAD's `06ec1f0` (delete `pd_sor` + the nine `power-domains` refs) is the
  correct, sufficient fix; run 3's PMIC values were also correct but beside
  the point.
- All aa661a8 diagnostics verified against the 7.2.11 source: clock IDs,
  CAR bank offsets, PLL/SOURCE/DC/pinmux/PMC addresses, the DC word-offset
  convention on both sides, and the three debugfs parsers. No hang risks
  given the existing clock guards; keep future SOR1/DPAUX1 dumps guarded.
- Add only `initcall_debug` (and optionally a verbatim 0.0–2.5 s dmesg
  re-print in darcy-init). If the picture still dies, the six dump fields
  (SOR/SOR0/DPAUX1 bits, `sor` powergate state, PLLD2 BASE+MISC0 on both
  sides) pick the next suspect in one photo.
