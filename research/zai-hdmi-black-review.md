# Review: HDMI goes black ~1.8 s into mainline Linux on darcy

**Verdict up front:** the sd2 (`vdd-pre-reg`) hypothesis is correct and well-
aimed — it is the only rail Linux *forces* to a new voltage at PMIC-probe
time, and that rail directly feeds the two 1.05 V LDOs that power HDMI
(ldo8 = `avdd_hdmi`, ldo7 = the PLL analog rail). The GPIO1 FPS-source
change is almost certainly *not* what killed the picture (FPS0 is
demonstrably active while Linux runs, so GPIO1 stays high either way).
The planned fix in `kernel/dts/darcy.dts:73-81` is right and sufficient;
one small transient to watch for on the next boot, and one fallback if the
fix doesn't cure it. Details, evidence, and answers to the four questions
below. All paths relative to `~/projects/nvidia`; line numbers from
`vendor/linux` (7.2.11), the stock DTB decompile, and the downstream
kernel-dts as checked out.

---

## 1. Is the PMIC the most likely cause? — Yes, via sd2 → 3.0 V at registration

### The software mechanism is exactly as hypothesized

1. `of_get_regulation_constraints()` sets `apply_uV` whenever *both* min and
   max are non-zero — a range counts too, min==max is not required
   (`drivers/regulator/of_regulator.c:109-111`).
2. At registration, `machine_constraints_voltage()` reads the current
   voltage; if it is below `min_uV` it raises the rail to `min_uV`, if above
   `max_uV` it lowers it (`drivers/regulator/core.c:1315-1367`, the clamps
   at `core.c:1346-1354`). It logs
   ` Bringing %duV into %d-%duV` at `core.c:1356-1358` (KERN_INFO).
3. Mainline pins sd2 to min = max = 3,000,000 µV
   (`arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1443-1454`), and sd2 is
   the input of the two N-type LDO groups
   (`tegra210-p2894.dtsi:1417-1418`: `in-ldo0-1-supply`, `in-ldo7-8-supply`).
   So if cboot leaves sd2 below 3.0 V (it leaves 1.35 V — below), the
   max77620-pmic child probe reprograms SD2 to 3.0 V mid-boot.
4. Nothing in the driver validates that against the LDO inputs: the probe
   path (`drivers/regulator/max77620-regulator.c:779-854`) and
   `max77620_of_parse_cb()` (`max77620-regulator.c:602-642`) never look at
   the supply's constraints. The write goes straight through
   `regulator_set_voltage_sel_regmap` to the SD2_VOLT register.
5. Timing matches: the max77620 MFD cascade (pinctrl → clock → regulators →
   … → gpio) runs at ~1.80–1.87 s — the recovered log shows the cascade's
   fixed regulators at 1.842 s and the IRQ trim at 1.871 s. The screen died
   at ~1.8 s, i.e. inside this window, and nothing else in the log touches
   hardware there.

**A confirmation is already in your hands:** the *full* ramoops dump should
contain the `Bringing … uV into 3000000-3000000uV` line (it's `rdev_info`,
not an error, so darcy-init's "fail" filter dropped it). It also names
cboot's actual sd2 voltage in the first field — worth grepping the unfiltered
log for `Bringing` before the next flash.

### The N-type LDO input limits

- The driver classifies exactly LDO0, LDO1, LDO7, LDO8 as
  `MAX77620_REGULATOR_TYPE_LDO_N`; LDO2–6 are P-type
  (`max77620-regulator.c:732-740`). These four are the MAX77620's
  low-voltage-input LDOs — the entire reason the "pre-regulator" rail
  exists is to feed INL1/INL5 from a low input.
- I could not fetch the MAX77620 datasheet PDF in this environment, so I
  can't quote the exact INL1/INL5 maximum rating — **please verify that
  number in the datasheet's DC/absolute-max tables before treating this as
  settled.** But the system-level evidence is unanimous that 1.35 V is the
  sanctioned operating point for this input, on every NVIDIA-authored
  source for T210 boards with this wiring:
  - Jetson TX1 module: sd2 = `VDD_PRE_REG_1V35`, min = max = 1,350,000
    (`tegra210-p2180.dtsi:218` and its pmic@3c/sd2 node).
  - Pixel C: `pp1350: sd2` = `PP1350`, min = max = 1,350,000, and it is
    explicitly `in-ldo0-1-supply`/`in-ldo7-8-supply`
    (`tegra210-smaug.dts:1530,1533,1557-1558`).
  - Stock darcy DTB: sd2 = 1,349,488–3,000,000 µV (0x149970–0x2dc6c0),
    a range, so stock Linux never moves the rail
    (`recovery/9.1.1/blob-parts/13-DTB.dts:6941-6957`).
  - NVIDIA's downstream darcy DTS source: same 1.35 V–3.0 V range
    (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:67-78`).
  Mainline's `tegra210-p2894.dtsi` min=max=3.0 V is the lone outlier and
  traces to no NVIDIA board source — almost certainly an upstream
  transcription error from the day the dtsi was added.

### What happens to ldo7/ldo8 then, and why the TV goes black

The downstream power tree names the consumers
(`tegra210-darcy-power-tree-p2894-0000-a00.dtsi`):

- ldo8 (`vdd-hdmi-dp`, 1.05 V) → **`avdd_hdmi-supply`**
  (`…power-tree…dtsi:283`) — the HDMI PHY analog supply. (HDMI 5V0 is a
  different, fixed rail: `vdd_hdmi_5v0-supply = <&vdd_hdmi>` at line 285;
  the HDMI PLL runs off sd3 at line 284.)
- ldo7 (`vdd-gen-pll-edp`, 1.05 V) → **`avdd-pll-uerefe` /
  `avddio_pll_uerefe`** (`…power-tree…dtsi:307,313,327,341,352`) — the
  analog supply of the UE/REFE PLL domain (on TX1 the same node is named
  `AVDD_1V05_PLL`, `tegra210-p2180.dtsi` pmic@3c/ldo7). If the TMDS-bound
  clocks live in that domain, this alone kills the link.

So when SD2 jumps 1.35 → 3.0 V on INL1/INL5, whatever the exact electrical
failure mode is — input over-stress shutdown, current-limit/thermal
reaction of the N-LDO pass element — the plausible outcome is ldo7/ldo8
collapsing or derating, which takes out `avdd_hdmi` and the PLL analog
supply simultaneously: the TV loses TMDS immediately and reports "no
signal". That matches the observation:

- the blackout is instant at the PMIC-probe instant, not a slow fade or a
  30 s-later cleanup (which `regulator_ignore_unused` already excludes —
  the log's 33.81 s "Not disabling unused regulators" confirms nothing was
  disabled late);
- it is *permanent* for the whole 60 s run, yet HDMI works again in
  cboot/U-Boot after the warm reboot — consistent with a rail-state failure
  that the bootloader's own PMIC re-init repairs, and with no permanent
  damage having occurred.

Note for the next boot's diagnosis: if sd2 → 3.0 V *is* the mechanism, the
`/sys/class/regulator` dump you planned should show sd2 at 3,000,000 µV on
the broken boot, and ldo7/ldo8 either "off" or sagging; on the fixed boot
sd2 should read ~1,350,000 µV with ldo7/ldo8 "on"/normal. That pair of
readings is the cleanest confirmation available without a scope.

## 2. The GPIO1 sequencer change — real, but almost certainly not the killer

Mechanics of the change at probe:

- Applying the `default` pinmux state muxes gpio1 to `fps-out` by setting
  its bit in `AME_GPIO` (`drivers/pinctrl/pinctrl-max77620.c:237-259`), then
  `max77620_set_fps_param()` writes the FPS-source field of `FPS_GPIO1`
  (`pinctrl-max77620.c:335-389`, the `param_val < 0` guard at line 381 lets
  SRC_0 (0) through) — i.e. SRC_NONE (3) → SRC_0 (0), a single regmap RMW.
- A GPIO in `fps-out` with source NONE is driven by the GPIO output
  register; with a real source it follows that FPS's state.

Why it doesn't blank the screen on this board:

- FPS0's state is not in doubt while Linux runs: **sd1 (`vddio-ddr`),
  sd3 (`vdd-1v8`) and ldo4 are all on FPS source 0**
  (`tegra210-p2894.dtsi:1440,1465,1521`; same in stock), and the box ran
  60 s on DDR and eMMC. So FPS0 (event source EN0, `tegra210-p2894.dtsi:
  1351-1354`) was ACTIVE the entire time — meaning EN0 is asserted. A GPIO
  switched from "OUT_DRV high" to "FPS0 output" while FPS0 is active stays
  high. No glitch-low is expected from the mux swap itself, and even a
  microsecond-level glitch would be absorbed by the 5 V boost's output
  capacitors.
- The MFD-side FPS register writes at probe
  (`drivers/mfd/max77620.c:363-376,390-391`, WK_EN0 at `438-445`) program
  the same event sources as stock/cboot (EN0/EN1/EN0; stock `13-DTB.dts:
  6877-6893`), so they don't perturb the running sequencer either. The
  stock-only `maxim,shutdown-fps-time-period` values only matter during
  suspend sequencing, which this boot never enters.

So: GPIO1's FPS source is a *latent* risk (it ties the 5 V boost to FPS0's
fate — any future EN0 toggle, suspend path via `pinctrl-max77620.c:608-638`,
or re-sequencing glitch drops HDMI 5V), and reverting to stock's SRC_NONE is
the right hygiene — but it is not what blacked this screen. That also
matches the log: nothing else on FPS0 (DDR!) so much as hiccupped at 1.8 s.

**One caveat about the fix itself, checkable on the next boot:** with
SRC_NONE, GPIO1 is driven by OUT_DRV. If cboot happens to leave GPIO1
FPS-driven with OUT_DRV = 0, the pinctrl write hands the pin to "0" and the
boost sags until `vdd-sys-boost`'s registration-enable (~40 ms later in the
same cascade: PMIC probe at ~1.80 s, fixed regulator at 1.842 s) drives
OUT_DRV high via `core.c:1662-1688` → `gpio-max77620.c:192-204`. Stock
Android does exactly this and ships fine, so cboot almost certainly leaves
OUT_DRV = 1 (stock's own config *requires* it). If the TV flickers once at
~1.8 s on the fixed boot, this is why — brief enough that most sinks won't
react, but worth knowing before misattributing it.

## 3. Anything else that could blank HDMI at ~1.45–2 s or later

Ranked, with why each is unlikely to be *the* cause:

1. **sd2 → 3.0 V (the PMIC hypothesis)** — high confidence; see §1.
2. **GPIO1 FPS source** — low; see §2.
3. **Fixed regulators on PMIC GPIOs probing at 1.842 s** — `vdd-3v3`'s
   enable is PMIC GPIO3 (`tegra210-p2894.dtsi:1648-1658`), which the
   pinmux puts in fps-out/SRC_0 *exactly like stock* (`tegra210-p2894.dtsi:
   1397-1402`, `13-DTB.dts:6830-6835`); with FPS0 active the rail enable
   stays asserted, and the `regulator-fixed` enable write to OUT_DRV is
   inert while the pin is in fps-out. The `regulator-max77620-gpio7` line
   in the log is the DSI/CSI analog rail (`avdd_dsi_csi`,
   `…power-tree…dtsi:289`) — not HDMI — and its "nonexclusive access"
   message is just gpiolib noting the pin is shared with the hog
   (`drivers/gpio/gpiolib.c:4863`). Benign noise.
4. **The regulator driver force-enabling SRC_NONE rails**: `max77620_init_pmic()`
   unconditionally sets power mode NORMAL for FPS-source-NONE rails
   (`max77620-regulator.c:408-413`), which enables the otherwise-off ldo2
   (`vddio-sdmmc3`) and ldo5 (`avdd-ts-hv`). Wasteful but harmless, and
   identical to stock's behavior.
5. **MC/SMMU**: probe writes only global config/TLB registers and enables
   no client translation; the display controller scans out a physical
   address in bypass. The 12.05 s `sync_state() pending` message is a
   non-action (nothing gets disabled — `clk_ignore_unused`,
   `pd_ignore_unused` are set, and the picture was already gone at 1.8 s).
6. **simpledrm/fbcon**: took over cleanly at 1.405–1.475 s; no DRM,
   host1x or clock driver exists in this kernel to touch DC A/SOR1/PLLD
   afterwards. The early `tegra-clk-debug` warning (0.000 s) is a
   PLL_A/DMIC mux warning, unrelated to SOR1.
7. **DT property deltas the mainline driver ignores** (ramp-delay-scale,
   disable-ramp-delay, init-mode, fps pu/pd periods on regulators — e.g.
   stock `13-DTB.dts:6949-6950` vs nothing in mainline): either unused by
   the mainline driver or only applied on suspend. Benign.

Nothing else in the 1.45–2 s window writes to hardware that HDMI depends
on. If the fixed DT still blacks the screen at ~1.8 s, the remaining suspect
space is inside the PMIC cascade only, and §4's fallback settles it.

## 4. Is the planned fix safe and enough?

**Yes on both counts, as written in `kernel/dts/darcy.dts:73-81`.**

- **sd2 min → 1,350,000 µV** (`darcy.dts:73-75`): with max still 3.0 V and
  the live voltage inside [1.35, 3.0], `machine_constraints_voltage()` now
  performs *no write at all* (`core.c:1346-1354` only moves a rail that is
  outside its constraint range) — byte-identical to stock semantics, i.e.
  "Linux keeps cboot's value". The alternative of pinning min = max =
  1,350,000 like p2180/smaug is equally safe and slightly stronger (it
  would force 1.35 V even if cboot left something else); the range version
  is the more conservative choice for a first boot and I'd keep it. Either
  way 3.0 V is never applied, which is the point.
- **gpio1 → SRC_NONE** (`darcy.dts:77-81`): restores stock semantics and
  removes the 5 V boost's dependence on FPS0/suspend paths. Keep the
  `regulator-boot-on` on `vdd_sys_boost` (`darcy.dts:55-57`) so its
  registration-enable drives OUT_DRV high in the same cascade
  (`core.c:1662-1688`). Note the ~40 ms OUT_DRV-handover caveat in §2 —
  expected to be a non-issue with cboot's OUT_DRV already 1.

**Diagnostics to keep:** the planned `/sys/class/regulator` dump is exactly
right — on the fixed boot check `max77620-sd2` reads ~1,350,000 µV and
`max77620-ldo7`/`ldo8` are on; if you keep a copy from a broken boot, sd2
at 3,000,000 µV there would close the case. Also grep the *unfiltered*
ramoops text from the failed boot for `Bringing` (see §1) — that line
records cboot's actual sd2 voltage and proves the write happened.

**Disabling the whole PMIC node instead** (`pmic@3c { status = "disabled" }`):
not needed now, and I'd keep it only as a **fallback differential test** if
the targeted fix doesn't cure the blackout. It makes Linux touch nothing in
the PMIC at all (no pinmux writes, no SD2_VOLT write, no fixed-regulator
enables on PMIC GPIOs), which is the closest equivalent of "what U-Boot
already does successfully" — but it costs you the regulator visibility that
confirms the diagnosis, defers every rail behind its GPIOs, and drops
RTC/thermal/clock32k cells. With sd2 fixed at the stock range there is no
remaining write in the PMIC cascade that is known to change HDMI-relevant
state, so prefer the surgical fix plus diagnostics; keep the PMIC-off boot
in reserve to separate "PMIC" from "everything else" if the screen still
dies at 1.8 s.

---

### TL;DR

- sd2 (`vdd-pre-reg`) is forced 1.35 → 3.0 V by the mainline DT at
  max77620 regulator registration (~1.8 s) via `apply_uV`
  (`of_regulator.c:109-111`, `core.c:1346-1360`); it is the only rail Linux
  rewrites, it feeds the N-type LDO0/1/7/8 inputs, and ldo7/ldo8 are the
  HDMI PLL-analog and `avdd_hdmi` supplies. That's the blackout.
- The GPIO1 FPS change is benign at boot (FPS0 is active — DDR proves it),
  but restoring SRC_NONE is still correct hygiene; watch for a possible
  ~40 ms boost handover dip on the next boot.
- The fix in `kernel/dts/darcy.dts:73-81` is safe and sufficient; the
  `/sys/class/regulator` dump will confirm it, and `grep Bringing` the old
  full log confirms the failed boot's write for free.
- Fallback if still black: disable `pmic@3c` for one differential boot.
