# HDMI TMDS Link Drop Analysis (`darcy` / Mainline Linux 7.2.11)

## 1. Top Hypotheses (Ranked)

### Rank 1 (Smoking Gun): `tegra_pmc_probe()` unconditionally tears down `pd_sor` (`SOR1` reset + clock gate + PMC powergate off) — even when TZ SMC reports `sor` is ON

The brief lists as a candidate:
> *the PMC registering powergates and asserting the `pd_sor` resets (SOR0/SOR1/DPAUX/DPAUX1/MIPI_CAL/DSI) if its SMC read reports `sor` as off*

In fact, **`tegra_powergate_add()` kills `pd_sor` regardless of whether the SMC read reports `sor` as ON or OFF** (`vendor/linux/drivers/soc/tegra/pmc.c:1316-1407`):

```c
// vendor/linux/drivers/soc/tegra/pmc.c:1347-1380
	off = !tegra_powergate_is_powered(pmc, pg->id);
...
	/*
	 * If the power-domain is off, then ensure the resets are asserted.
	 * If the power-domain is on, then power down to ensure that when is
	 * it turned on the power-domain, clocks and resets are all in the
	 * expected state.
	 */
	if (off) {
		err = reset_control_assert(pg->reset);
		if (err) {
			pr_err("failed to assert resets: %d\n", err);
			goto remove_resets;
		}
	} else {
		err = tegra_powergate_power_down(pg);
		if (err) {
			dev_err(dev, "failed to turn off PM domain %s: %d\n",
				pg->genpd.name, err);
			goto remove_resets;
		}
	}
```

#### Exact execution trace at `t = 0.156 s` (`tegra_pmc_probe()`)
1. `tegra_pmc_probe()` (`vendor/linux/drivers/soc/tegra/pmc.c:2996-3124`) calls `tegra_pmc_init()` (`pmc.c:2806`) -> `tegra_powergate_init()` (`pmc.c:1428-1457`), which iterates `for_each_available_child_of_node()` over `/pmc@7000e400/powergates` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:921-1000`).
2. One of those available child nodes is `pd_sor: sor` (`tegra210.dtsi:941-960`), which owns:
   - **Clocks (10):** `sor0` (182), **`sor1` (183)**, `cilab` (144), `cilcd` (145), `cile` (146), `dsia` (48), `dsib` (82), `dpaux` (181), **`dpaux1` (207)**, **`mipi_cal` (56)**.
   - **Resets (7):** `sor0` (182), **`sor1` (183)**, `dsia` (48), `dsib` (82), `dpaux` (181), **`dpaux1` (207)**, **`mipi_cal` (56)**.
3. `tegra_powergate_is_powered(pmc, TEGRA_POWERGATE_SOR)` (`pmc.c:605-608`, ID 17) reads `PWRGATE_STATUS` (`0x038`) via the TZ SMC (`pmc.c:536-573`). Because cboot enabled HDMI on `SOR1`, `sor` is powered (`off == false`).
4. `tegra_powergate_add()` takes the **`else` branch** (`pmc.c:1373-1380`) and calls **`tegra_powergate_power_down(pg)`** (`pmc.c:895-942`), which executes:
   - `tegra_powergate_prepare_clocks(pg)` (`pmc.c:750-785`): clamps any clock in `pd_sor` above 100 MHz down to `100 MHz` (`clk_set_rate(pg->clks[i], 100000000)` — `sor1` is running at 148.5 MHz for 1080p60).
   - `tegra_powergate_enable_clocks(pg)` (`pmc.c:809-827`): calls `clk_prepare_enable()` on all 10 `pd_sor` clocks.
   - `reset_control_assert(pg->reset)` (`pmc.c:909`): **asserts the CAR reset bits (`RST_DEVICES_*`) for `SOR1` (183), `SOR0` (182), `DPAUX` (181), `DPAUX1` (207), `MIPI_CAL` (56), `DSIA` (48), and `DSIB` (82)**.
   - `tegra_powergate_disable_clocks(pg)` (`pmc.c:915`, `801-807`): calls `clk_disable_unprepare()` on all 10 `pd_sor` clocks. Because no driver has claimed them (`CONFIG_DRM_TEGRA=m`), their `enable_count` drops from 1 to 0 and **CAR clears `CLK_OUT_ENB` for `SOR1` (183), `SOR0` (182), `DPAUX` (181), `DPAUX1` (207), `MIPI_CAL` (56), `DSIA` (48), `DSIB` (82), `CILAB`/`CILCD`/`CILE`**.
   - **Cascade to `SOR_SAFE` (222):** In `vendor/linux/drivers/clk/tegra/clk-tegra210.c:3101-3111`, `sor_safe` (ID 222) is registered as the parent of `dpaux` (181) and `dpaux1` (207) without `CLK_IGNORE_UNUSED` or `CLK_IS_CRITICAL`. When `tegra_powergate_enable_clocks()` enables `dpaux` and `dpaux1`, `sor_safe->enable_count` becomes 2; when `tegra_powergate_disable_clocks()` disables `dpaux` and `dpaux1`, `clk_core_disable()` walks up to `core->parent` (`vendor/linux/drivers/clk/clk.c:1160-1176`), decrements `sor_safe->enable_count` to 0, and **gates `SOR_SAFE` (`CLK_OUT_ENB_Y` bit 30 = 0)** as well.
   - `tegra_powergate_set(pg->pmc, pg->id, false)` (`pmc.c:919`, `669-692`): writes `PWRGATE_TOGGLE_START | 17` (`0x111`) to `PWRGATE_TOGGLE` (`0x030`) via the TZ SMC, **power-gating the `SOR` partition off in hardware**.
   - `tegra_powergate_unprepare_clocks(pg)` (`pmc.c:923`): restores `CLK_SOURCE_SOR1`'s divider.
   - `pm_genpd_init(&pg->genpd, NULL, true)` (`pmc.c:1391`): registers the `sor` generic PM domain as `off`.
5. And if the TZ SMC read had instead reported `sor` as off (`off == true`), the `if (off)` branch (`pmc.c:1367-1372`) still executes `reset_control_assert(pg->reset)`, asserting CAR reset on `SOR1` (183) and killing TMDS output.

#### Why `pd_ignore_unused` and `clk_ignore_unused` did not prevent this, and why `DISP1` (`DC A`) survived
- `pd_ignore_unused` (`vendor/linux/drivers/pmdomain/core.c:1304-1330`) only skips the `late_initcall_sync(genpd_power_off_unused)` sweep. `tegra_powergate_add()` powers down `pd_sor` **synchronously during `tegra_pmc_probe()`** so that every Tegra genpd starts in the `off` state.
- `clk_ignore_unused` (`vendor/linux/drivers/clk/clk.c:1426-1482`) only skips `clk_disable_unused()` at `late_initcall_sync`; it does not block explicit `clk_disable_unprepare()` calls made by `tegra_powergate_disable_clocks()`.
- **Why `DISP1` (`DC A`) is untouched:** `/pmc@7000e400/powergates` in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:921-1000` only defines `aud`, `sor`, `mpe`, `nvdec`, `nvjpg`, `venc`, `vic`, `xusba`, `xusbb`, `xusbc`. It has **no `dis` or `disb` node**. Consequently, the `dis` powergate stays ON, `DISP1` (27) stays clocked and out of reset, and `simpledrm` (`1.403–1.472 s`) binds to `0x92cc3000` without hanging—scanning pixels into a `SOR1` serializer that was already reset, clock-gated, and power-gated at `t = 0.156 s`.
- **Why the TV showed "U-Boot's text, then a flicker, then 'No signal' ~1.5–2 s into Linux":** `SOR1` stops driving TMDS at `t = 0.156 s` (only 156 ms after U-Boot prints `Starting kernel ...`, while U-Boot's text is still on the panel). Abruptly halting the TMDS clock mid-frame causes the visual flicker on U-Boot's text, and the TV's HDMI receiver waits ~1.5–2 s after losing TMDS clock lock before displaying its `"No signal"` banner.

#### What Rank 1 will look like in the `aa661a8` dump
- **U-Boot `report_display_hw()`:**
  - `clocks: DISP1 1/0 ... MIPI_CAL 1/0 ... SOR1 1/0 DPAUX1 1/0 SOR_SAFE 1/0`
- **Linux `darcy-init`:**
  - `show_display_hw()` (`clocks:`): `DISP1 1/0` (still clocked and out of reset) and `HOST1X 1/0`, **but `SOR1 0/1`, `DPAUX1 0/1`, `DPAUX 0/1`, `SOR0 0/1`, `MIPI_CAL 0/1`, `DSIA 0/1`, and `SOR_SAFE 0/0`** (`SOR1` clock gated and held in reset; `SOR_SAFE` clock gated).
  - `show_display_hw()` (`PLLs:` and `DC A:`): `PLLD2_BASE`, `CLK_SOURCE_DISP1`, `CLK_SOURCE_SOR1`, and `DC A` (`command 00000020`) unchanged from U-Boot (`DC A` is still scanning out).
  - `show_powergates()`: `dis` listed under `powergates on:`, **`sor` listed under `powergates off:`** (or if `off == true` took the `if` branch, `sor` in `off` and `SOR1 1/1`).
  - `show_genpd()`: **`sor off-0;`** (alongside all other Tegra powergates in `off-0`).
  - `show_clks()`: `disp1 en 0 ... hw Y;`, `pll_d2 en 0 ... hw Y;`, **but `sor1 en 0 ... hw N;`, `sor1_out en 0 ... hw N;`, `sor_safe en 0 ... hw N;`, `dpaux1 en 0 ... hw N;`**.

---

### Rank 2: Tegra210 CAR clock init / `tegra210_init_table` (`drivers/clk/tegra/clk-tegra210.c`)

- **Early clock init (`0.000 s`):** `tegra210_clock_init()` (`vendor/linux/drivers/clk/tegra/clk-tegra210.c:3736-3820`) calls:
  - `tegra210_pll_init()` -> `tegra210_plld2_set_defaults()` (`clk-tegra210.c:1026`, `936-1001`): checks `if (val & PLL_ENABLE)` (`956`). When `PLL_D2` is already enabled by cboot, it **does not** disable or reprogram `PLL_D2`; it only clears `PLLDSS_BASE_LOCK_OVERRIDE` and sets `PLLDSS_MISC0_LOCK_ENABLE`.
  - `writel_relaxed(val, clk_base + PLLD_BASE)` (`clk-tegra210.c:3801-3803`): clears `BIT(25)` (`CSI_CLK_SRC`) in `PLLD_BASE` (`0x0d0`), which does not affect `PLL_D2`.
- **`arch_initcall(tegra_clk_apply_init_table)` (`drivers/clk/tegra/clk.c:451` -> `clk-tegra210.c:3617-3625`):**
  - `TEGRA210_CLK_HOST1X` (`clk-tegra210.c:3563`): reparents `host1x` to `pll_p` at 136 MHz and enables it (`enable = 1`), deasserting `HOST1X` reset and setting `CLK_OUT_ENB_L[28] = 1`.
  - `TEGRA210_CLK_PLL_DP` (`clk-tegra210.c:3591`): `{ TEGRA210_CLK_PLL_DP, TEGRA210_CLK_CLK_MAX, 270000000, 0 }`. Calls `clk_set_rate(pll_dp, 270000000)`. This only affects HDMI if cboot unexpectedly clocked `DISP1` or `SOR1` from `pll_dp` instead of `pll_d2`.
- **What it would look like in the `aa661a8` dump:**
  - `HOST1X` changes from U-Boot's state to `HOST1X 1/0` (`host1x en 1 135999999 Hz hw Y`).
  - `PLLDP_BASE` (`0x590`) changes between U-Boot and Linux; if `PLL_D2` were disturbed, `PLLD2_BASE` (`0x4b8`) would lose `BIT(30)` (`PLL_ENABLE`) or `BIT(27)` (`PLL_BASE_LOCK`), or `pll_d2` rate in `show_clks()` would differ from `297000000 Hz` / `148500000 Hz`.

---

### Rank 3: `pinctrl-tegra210` clearing `parked_bitmask` (`drivers/pinctrl/tegra/pinctrl-tegra.c`)

- At `arch_initcall(tegra210_pinctrl_init)` (`vendor/linux/drivers/pinctrl/tegra/pinctrl-tegra210.c:1582`), `tegra_pinctrl_probe()` (`vendor/linux/drivers/pinctrl/tegra/pinctrl-tegra.c:709-725`) iterates over all 107 pingroups in `tegra210_groups[]` (`pinctrl-tegra210.c:1352-1543`) and clears `PINGROUP_BIT_PARKED` (`BIT(5)`, `.parked_bitmask = BIT(5)` at `pinctrl-tegra210.c:1316`) on every bank-1 pingroup (`0x3000..0x3290`), including `pcc7` (`0x3194`), `hdmi_cec_pcc0` (`0x3198`), `hdmi_int_dp_hpd_pcc1` (`0x319c`), and `dp_hpd0_pcc6` (`0x31b0`).
- Because neither `tegra210.dtsi` nor `darcy.dts` defines `pinctrl-0` default states on the pinmux controller, `pinctrl-tegra210` does **not** alter `PMUX`, `PUPD`, `TRISTATE`, `E_INPUT`, or `E_OD` on any pin, and the HDMI TMDS lanes are dedicated analog pads on `SOR1` (not routed through `apb_misc` pingroups).
- **What it would look like in the `aa661a8` dump:** All CAR clocks, resets, PLLs, DC A registers, and `sor` powergate would remain identical to U-Boot (`SOR1 1/0`, `sor` in `powergates on:`).

---

### Rank 4: Memory Controller (`tegra-mc`), SMMU, or Latency Allowance (`drivers/memory/tegra/`, `drivers/iommu/tegra-smmu.c`)

- `tegra_mc_probe()` (`vendor/linux/drivers/memory/tegra/mc.c:930-1013`, `arch_initcall` at `1054`) calls `tegra_smmu_probe()` (`vendor/linux/drivers/iommu/tegra-smmu.c:1105-1183`), which writes `SMMU_CONFIG_ENABLE` (`tegra-smmu.c:1164`). However, per-client translation for `display0a` (`MC_SMMU_TRANSLATION_ENABLE_0` `0x228` bit 1 and `SMMU_DC_ASID` `0x240` bit 31, `vendor/linux/drivers/memory/tegra/tegra210.c:16-30`, `1169`) is only set when a device attaches to an IOMMU domain (`tegra_smmu_attach_dev()`). Because `host1x` and `drm` are modules (`=m`), `dc@54200000` never attaches and remains in SMMU bypass.
- During interconnect registration (`mc.c:869-886`), `icc_node_add()` calls `tegra30_mc_icc_set(node, node)`, which explicitly bails out on `if (src == dst) return 0;` (`vendor/linux/drivers/memory/tegra/tegra30.c:1305-1306`), leaving bootloader latency allowances (`0x2e8`) untouched.
- Furthermore, MC/SMMU errors or display FIFO underflows only corrupt or blank pixel data while `SOR1` continues transmitting a valid TMDS clock and syncs (so the TV would show a black screen, **not** `"No signal"`), and `tegra30_mc_irq_handlers` (`mc.c:734`) would print ratelimited `display0a:` errors caught by `show_highlights()`.
- **What it would look like in the `aa661a8` dump:** `SOR1 1/0`, `DISP1 1/0`, `sor` powergate `on`, plus `tegra-mc 70019000.memory-controller: display0a: ...` error lines in `show_highlights()`.

---

### Rank 5: XUSB padctl or other built-in drivers (`drivers/phy/tegra/xusb.c`)

- `tegra-xusb-padctl` (`vendor/linux/drivers/phy/tegra/xusb.c`, `xusb-tegra210.c`) only maps `0x7009f000` (`padctl@7009f000`) and touches USB2/USB3/PCIe/SATA pad registers. It has no path to `SOR1`, `DPAUX1`, `PLL_D2`, or `pd_sor`.

---

## 2. Review of the `aa661a8` Diagnostics (`tools/darcy-init.c` & `p2894.c`)

### Register offsets and clock/reset IDs
All CAR bank offsets, clock/reset IDs, PLL offsets, and DC A offsets in `tools/darcy-init.c:130-157` and `vendor/lineage-u-boot/board/nvidia/p2894/p2894.c:90-122` match Tegra210 hardware and Linux headers:
- **CAR bank arrays (`L, H, U, V, W, X, Y`):**
  - `car_enb[] = { 0x010, 0x014, 0x018, 0x360, 0x364, 0x280, 0x298 }` and `car_rst[] = { 0x004, 0x008, 0x00c, 0x358, 0x35c, 0x28c, 0x2a4 }` (`tools/darcy-init.c:146-147`, `p2894.c:102-103`) match `periph_regs[]` in `vendor/linux/drivers/clk/tegra/clk.c:101-179`.
- **Clock/reset IDs (`bank = id / 32`, `bit = id % 32`):**
  - `DISP1` (27, L[27]), `DISP2` (26, L[26]), `HOST1X` (28, L[28]), `DSIA` (48, H[16]), `MIPI_CAL` (56, H[24]), `DPAUX` (181, X[21]), `SOR0` (182, X[22]), `SOR1` (183, X[23]), `DPAUX1` (207, Y[15]), `SOR_SAFE` (222, Y[30]) match `vendor/linux/include/dt-bindings/clock/tegra210-car.h:46-249` and `dt-bindings/reset/tegra210-car.h`.
  - *Minor hardware note on `SOR_SAFE` (222):* `SOR_SAFE` is a peripheral fixed clock (`CLK_OUT_ENB_Y` bit 30, `vendor/linux/drivers/clk/tegra/clk-tegra210.c:3101`) without a separate reset entry in `pd_sor` (`tegra210.dtsi:954-958`), though `tegra_clk_periph_fixed_is_enabled()` (`vendor/linux/drivers/clk/tegra/clk-periph-fixed.c:22-27`) also checks `RST_DEVICES_Y` bit 30 (`0x2a4`). Reading `car_rst[6]` bit 30 is safe and matches Linux's `hw` enable check.
- **PLL and mux offsets:**
  - `CAR_PLLD_BASE = 0x0d0`, `CAR_PLLD2_BASE = 0x4b8`, `CAR_PLLDP_BASE = 0x590`, `CAR_CLK_SOURCE_DISP1 = 0x138`, `CAR_CLK_SOURCE_SOR1 = 0x410` (`tools/darcy-init.c:134-138`) match `vendor/linux/drivers/clk/tegra/clk-tegra210.c:35,71,87,96` and `clk-tegra-periph.c:630`.
- **DC A offsets and indexing:**
  - `DC_CMD_DISPLAY_COMMAND = 0x032` (byte `0x0c8`), `DC_CMD_DISPLAY_POWER_CONTROL = 0x036` (byte `0x0d8`), `DC_CMD_STATE_CONTROL = 0x041` (byte `0x104`), `DC_DISP_DISP_CLOCK_CONTROL = 0x42e` (byte `0x10b8`) match word offsets in `vendor/linux/drivers/gpu/drm/tegra/dc.h:197,203,246,456`.
  - In `tools/darcy-init.c:198-201`, `dc` is `volatile uint32_t *` mapped with size `0x2000`, so `dc[0x42e]` accesses byte offset `0x10b8` (`< 0x2000`), matching U-Boot's `dc_readl(reg)` (`readl(DC_BASE + reg * 4)` at `p2894.c:194-197`).

### Could any read hang the CPU?
- **No.**
  - `CAR_BASE` (`0x60006000`) is always powered, clocked, and world-readable from NS EL0/EL1.
  - `DC_BASE` (`0x54200000`) is guarded in both U-Boot (`p2894.c:394-395`) and `darcy-init` (`tools/darcy-init.c:196-197`) by checking `CLK_OUT_ENB_L[27] == 1 && RST_DEVICES_L[27] == 0`. Because `dis` has no node under `/pmc@7000e400/powergates`, Linux never power-gates the `dis` partition while `DISP1` stays clocked.
  - With `CONFIG_STRICT_DEVMEM=y` and `CONFIG_IO_STRICT_DEVMEM` unset (`build/linux/.config:5205-5206`), `/dev/mem` permits `mmap()` of non-RAM MMIO ranges (`0x60006000` and `0x54200000`) even when `ioremap()`ped by kernel drivers.

### Parser and buffer review (`show_powergates`, `show_genpd`, `show_clks`)
- **`show_powergates()` (`tools/darcy-init.c:208-229`):** Matches `powergate_show()` in `vendor/linux/drivers/soc/tegra/pmc.c:1228-1247` (`" %9s %7s\n"`). `sscanf(line, "%31s %15s", name, state)` skips leading whitespace, ignores the `"powergate"` header and `"---..."` separator, and `on[320]`/`off[320]` easily hold all 23 T210 powergate names (~115 bytes total).
- **`show_genpd()` (`tools/darcy-init.c:232-249`):** Matches `summary_show()` / `genpd_summary_one()` in `vendor/linux/drivers/pmdomain/core.c:3824-3898`. Domain lines start at column 0 (`"%-30s  %-30s  %u"`), whereas subheaders and child devices start with `' '` or `'-'`. Note that `genpd_summary_one()` formats off states as `"%s-%u"` (`core.c:3843`), so `show_genpd()` will print `sor off-0;`.
- **`show_clks()` (`tools/darcy-init.c:257-291`):** Matches `clk_summary_show_one()` in `vendor/linux/drivers/clk/clk.c:3274-3313`. `strtok_r(line, " \t\n", &save)` strips the tree indentation (`level * 3 + 1` spaces), and the 9 tokens `tok[0..8]` map to `name` (`0`), `enable_count` (`1`), `prepare_count` (`2`), `protect_count` (`3`), `rate` (`4`), `accuracy` (`5`), `phase` (`6`), `duty_cycle` (`7`), and `hardware enable` (`8`). Splitting 11 clocks into `out[0]` (5 clocks, ~170 B) and `out[1]` (6 clocks, ~205 B) fits comfortably inside `out[2][300]` and `say()`'s `line[512]`.

---

## 3. What Else Should This Run Capture?

U-Boot's `report_last_log()` displays the last `LOG_LINES = 56` lines (`vendor/lineage-u-boot/board/nvidia/p2894/p2894.c:87`). Currently, the end-of-log block in `tools/darcy-init.c:413-420` emits up to **48 lines**:
- `show_highlights()`: 1 header + up to 30 lines (23 lines in Run 3)
- `show_regulators()`: 6 lines (21 regulators, 4 per line)
- `show_clks()`: 2 lines
- `show_genpd()`: 1 line
- `show_powergates()`: 2 lines
- `show_display()`: 1 line
- `show_display_hw()`: 3 lines
- `darcy-init` reboot line + kernel `reboot: Restarting system...`: 2 lines

That leaves **8–15 lines of headroom** in the 56-line ramoops window. Two small additions in `tools/darcy-init.c` would make the next photo 100% conclusive even if something unexpected happens:

1. **Capture `show_display_hw()` immediately when `darcy-init` starts (`t ≈ 1.5 s`) and print that saved 1-line clock/reset snapshot at the end (`t = 60 s`):**
   - Today, `show_display_hw()` only runs at `t = 60 s` (`tools/darcy-init.c:419`). Recording the `clocks:` string at `t ≈ 1.5 s` (right after `mount("/dev", ...)` at line 391) and printing `clocks at 1s: ...` right above `clocks:` at line 419 costs **1 line** and proves whether `SOR1` was already in reset by the time userspace started (`t = 0.156 s`) vs killed later during the 60 s window.
2. **Conditionally dump `SOR1` state & `MC` status (1 line):**
   - In `show_display_hw()`, **only if `SOR1` is clocked and out of reset** (`CLK_OUT_ENB_X[23] == 1 && RST_DEVICES_X[23] == 0`), map `SOR1` (`0x54580000`) and print `SOR_SUPER_STATE1` (`0x02`), `SOR_STATE1` (`0x04`), `SOR_PWR` (`0x15`), `SOR_PLL0` (`0x17`), and `SOR_CSTM` (`0x1b`) (`vendor/linux/drivers/gpu/drm/tegra/sor.h:13-143`).
   - On the same line (or a 1-line `MC:` line), map `MC` (`0x70019000`) and print `MC_INTSTATUS` (`0x000`), `MC_ERR_STATUS` (`0x008`), `MC_SMMU_TRANSLATION_ENABLE_0` (`0x228`), and `MC_LATENCY_ALLOWANCE_DC_0` (`0x2e8`).

---

## 4. Candidate Fix vs. Purely Diagnostic Run

### The Candidate Fix (1-line DT change, no kernel C patch required)
In `kernel/dts/darcy.dts`, disable the `sor` powergate node under `/pmc@7000e400/powergates`:

```dts
&{/pmc@7000e400/powergates/sor} {
	status = "disabled";
};
```

#### Why this works cleanly
- `tegra_powergate_init()` (`vendor/linux/drivers/soc/tegra/pmc.c:1437`) iterates over powergate subnodes with `for_each_available_child_of_node(np, child)`.
- Marking `/pmc@7000e400/powergates/sor` as `status = "disabled"` causes `tegra_pmc_probe()` to skip `tegra_powergate_add()` for `sor` completely:
  - It never calls `tegra_powergate_power_down(pg)` at `t = 0.156 s`.
  - It never asserts the `SOR1`, `DPAUX1`, or `MIPI_CAL` CAR resets.
  - It never disables `SOR1`, `DPAUX1`, `MIPI_CAL`, or their parent `SOR_SAFE` (and `clk_ignore_unused` keeps them enabled at `late_initcall_sync`).
  - It never sends the `PWRGATE_TOGGLE` TZ SMC to power off `TEGRA_POWERGATE_SOR` (17).
- No built-in driver in `build/linux/.config` references `&pd_sor` (its only DT consumers in `tegra210.dtsi` are `dsi`, `sor0`, `sor1`, `dpaux`, and `dpaux1`, which belong to `CONFIG_DRM_TEGRA=m` and are not loaded).

### Should we add it to this run or stay purely diagnostic?
- **Keep this run (`aa661a8`) purely diagnostic** (do not add the DT fix to the same image yet).
- **Why:**
  1. Each test cycle only takes ~2 minutes (`NOTES.md`), and `aa661a8` is specifically built to catch the hardware state delta between U-Boot and Linux. Running `aa661a8` unmodified first will show `SOR1 1/0` in U-Boot turning into `SOR1 0/1`, `SOR_SAFE 0/0`, `powergates off: ... sor`, and `power domains: ... sor off-0;` in Linux—giving unambiguous proof of the root cause.
  2. If you applied `status = "disabled"` on `pd_sor` in the same run and the screen stayed on, you would not know for certain whether `tegra_powergate_add()` was the only killer; conversely, if a secondary issue also existed, disabling `pd_sor` simultaneously would change the `powergates`, `genpd`, and `clk_summary` outputs that `aa661a8` was written to inspect.
  3. Once `aa661a8` confirms `SOR1 0/1` and `sor` in `powergates off:`, adding `&{/pmc@7000e400/powergates/sor} { status = "disabled"; };` to `kernel/dts/darcy.dts` is a 1-line follow-up test.
