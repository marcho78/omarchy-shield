# Review: Bring-Up Plan (Part A: CPU Power & Thermal, Part B: GPU, Hyprland & Omarchy)

---

## Part A — CPU Power & Thermal Management

### 1. Cap as a Kernel Patch vs. Boot-Time Governor (`cpufreq.default_governor=`) — and What Else Is Needed for the OPP Table

#### Kernel patch vs. `cpufreq.default_governor=`
A **kernel patch** to `tegra210_cpu_max_freq_table[2]` in `vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:178` is **strictly safer and more deterministic** than relying on `cpufreq.default_governor=powersave` (or `schedutil`), for three code-level reasons:

1. **Eliminates OPPs above the cap from existing at all:**
   In `tegra124_dfll_fcpu_probe()` (`vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:696-701`), `soc->max_freq = fcpu_data->cpu_max_freq_table[speedo_id];` is passed directly to `tegra_cvb_add_opp_table()` -> `build_opp_table()` (`vendor/linux/drivers/clk/tegra/cvb.c:55-82`), which stops adding OPPs as soon as `entry->freq > max_freq` (`cvb.c:67-68`). With `tegra210_cpu_max_freq_table[2]` patched, frequencies above the cap do not exist in `cpu0`'s OPP table, in `cpufreq`'s `scaling_available_frequencies`, or in the Energy Model (`CONFIG_ENERGY_MODEL=y`, `vendor/linux/arch/arm64/configs/defconfig:94`).
2. **Prevents boot-window and userspace/governor excursions to `2.2185 GHz`:**
   With `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` (`defconfig:96`), `schedutil` boosts to `policy->cpuinfo.max_freq` as soon as boot tasks create utilization. Even if `cpufreq.default_governor=powersave` were passed on the kernel command line, `2218500000` Hz (`2.2185 GHz` — the Pixel C bin, above stock Shield TV's `2014500000` Hz ceiling) would remain in `scaling_max_freq` where any userspace tool or governor change could select it.
3. **Clamps the DFLL hardware closed-loop voltage ceiling (`DFLL_OUTPUT_CFG_MAX`):**
   In `tegra_dfll_register()` -> `dfll_build_lut()` (`vendor/linux/drivers/clk/tegra/clk-dfll.c:1765-1783`), `dev_pm_opp_find_freq_floor(td->soc->dev, &rate)` (with `rate = ULONG_MAX`) fetches the voltage `v_max` of the highest registered OPP and passes it to `dfll_build_pwm_lut(td, v_max)` (`clk-dfll.c:1645-1685`), which sets `td->lut_size` and `td->lut_max = td->lut_size - 1` (`clk-dfll.c:746, 754`). A governor only limits software frequency requests; patching `tegra210_cpu_max_freq_table[2]` also limits the hardware PWM duty-cycle ceiling register `DFLL_OUTPUT_CFG`.

#### Subtlety with the `1036800000UL` validation cap (`DFLL_OUTPUT_CFG_MAX` headroom)
- Note how `TEGRA210_CPU_CVB_TABLE` (`clk-tegra124-dfll-fcpu.c:189-214`, selected for `speedo_id = 2, process_id = 0` at `clk-tegra124-dfll-fcpu.c:515-524`) is stepped in multiples of `ref_rate / 2 = 25.5 MHz` (`clk-dfll.c:200-203`):
  - `... 816000000UL`, `918000000UL`, **`1020000000UL`**, `1122000000UL ...` (`clk-tegra124-dfll-fcpu.c:199-202`).
  - There is no `1036800000UL` entry in `TEGRA210_CPU_CVB_TABLE`; setting `tegra210_cpu_max_freq_table[2] = 1036800000UL` (or `1020000000UL`) includes OPPs up through **`1020000000UL` (`1020 MHz`)**.
  - Crucially, the cap **must not** be set below `1020000000UL` (e.g., to `1017600000UL`), because in `tegra124_cpu_switch_to_dfll()` (`vendor/linux/drivers/cpufreq/tegra124-cpufreq.c:36-46`), `rate = clk_get_rate(priv->cpu_clk)` reads cboot's `pll_x` rate (`1017600000` Hz) and calls `dev_pm_opp_set_rate(priv->cpu_dev, 1017600000)`, which uses `dev_pm_opp_find_freq_ceil()` to round **up** to `1020000000` Hz.
- **Hardware LUT ceiling (`lut_max`) at `1020 MHz`:**
  For Darcy's fuse `cpu_speedo_value = 2089` (`NOTES.md:1224`), `get_cvb_voltage()` + `round_cvb_voltage()` (`cvb.c:14-36`) with `align.offset_uv = 708000, align.step_uv = 19200` (`clk-tegra124-dfll-fcpu.c:551-554`) computes:
  - `min_mv = round_voltage(870, align, UP) = 880` mV (`880800 uV`, PWM step `lut_bottom = 9`).
  - At `1020000000UL` (`{ 1400411, -31965, 370 }`, `clk-tegra124-dfll-fcpu.c:201`): unrounded `mv = 894122` -> rounded up to `900000 uV` (`900 mV`, PWM step `10`).
  - In `dfll_build_pwm_lut(td, 900000)` (`clk-dfll.c:1652-1673`), the loop stops at `i = 11` (`td->lut_size = 11`), which barely passes the check `if (lut_bottom + 1 >= td->lut_size)` (`9 + 1 >= 11` is false; at `918 MHz` `lut_size` would be `10` and probe would fail with `-EINVAL: "no voltage above DFLL minimum 870 mV"`).
  - Consequently, `dfll_init_out_if()` (`clk-dfll.c:745-756`) programs `td->lut_min = 9` (`880.8 mV`), `td->lut_max = 10` (`900.0 mV`), and `td->lut_safe = 10`. That leaves only **1 PWM step (`19.2 mV`)** of closed-loop voltage range between `lut_min` and `lut_max`. Because the DFLL in PWM closed-loop mode drives duty cycle directly from its frequency-error integrator (`clk-dfll.c:1641-1642`) and the CVB voltage is only a nominal curve, if the silicon needs step `11` (`919.2 mV`) at `1020 MHz`, `DFLL_OUTPUT_CFG_MAX = 10` will clip the output. If you observe under-clocking at the initial cap, bump the initial validation cap in `tegra210_cpu_max_freq_table[2]` slightly to **`1224000000UL` (`1.224 GHz`, `957.6 mV`, `lut_max = 13`)** so the closed-loop integrator has 4 PWM steps of headroom while still staying below cboot's `1.0 V` boot voltage.

#### Is anything else needed to keep the DFLL's OPP table at or below the cap?
**No.** Neither `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi` (`cpu@0..3` at lines `2019-2055`) nor `darcy.dts` defines a static `operating-points-v2` property on the CPU nodes.
- `tegra124_dfll_fcpu_probe()` (`clk-tegra124-dfll-fcpu.c:696-701`) is the **sole** producer of CPU OPPs via `tegra_cvb_add_opp_table()` on `cpu0`.
- When `tegra124-cpufreq` (`vendor/linux/drivers/cpufreq/tegra124-cpufreq.c:88`) registers `cpufreq-dt`, `dt_cpufreq_early_init()` (`vendor/linux/drivers/cpufreq/cpufreq-dt.c:199-248`) calls `dev_pm_opp_of_cpumask_add_table()`, gets `-ENOENT`, falls back to the dynamic OPP table already attached to `cpu0` by `tegra_cvb_add_opp_table()`, and marks those OPPs shared across all 4 CPUs via `dev_pm_opp_set_sharing_cpus()` (`cpufreq-dt.c:240-246`).

---

### 2. Is the DFLL Node Plus Pin States Complete for Mainline? What Should `dmesg` and `debugfs` Show?

#### Completeness of the DT changes in `darcy.dts`
**Yes — the proposed `&dfll` node and `&pinmux` `dvfs_pwm_active_state` / `dvfs_pwm_inactive_state` nodes are complete** and satisfy every property required by the mainline driver stack:

1. **Base SoC properties already present in `tegra210.dtsi`:**
   - `dfll: clock@70110000` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:1424-1441`) already provides `compatible = "nvidia,tegra210-dfll"`, `reg` (4 regions: base, i2c, i2c controller, LUT), `interrupts`, `clocks` (`soc`, `ref`, `i2c`), `resets` (`dfll`, `dvco`), `#clock-cells = <0>`, and `clock-output-names = "dfllCPU_out"`.
   - `cpu@0` (`tegra210.dtsi:2019-2031`) already provides `clocks = <&tegra_car TEGRA210_CLK_CCLK_G>, <&tegra_car TEGRA210_CLK_PLL_X>, <&tegra_car TEGRA210_CLK_PLL_P_OUT4>, <&dfll>;` and `clock-names = "cpu_g", "pll_x", "pll_p", "dfll";` required by `tegra124_cpufreq_probe()` (`tegra124-cpufreq.c:116-135`).
2. **Board-level properties in `darcy.dts` verified against driver consumers:**
   - `dfll_fetch_common_params()` (`clk-dfll.c:1904-1924`): reads `nvidia,droop-ctrl`, `nvidia,sample-rate`, `nvidia,force-mode`, `nvidia,cf`, `nvidia,ci`, `nvidia,cg`, and optional `nvidia,cg-scale`. All 6 required properties match `tegra210-p3450-0000.dts:595-601`.
   - `tegra_dfll_register()` (`clk-dfll.c:1968-1975`): checks `of_property_read_bool(td->dev->of_node, "nvidia,pwm-to-pmic")` to set `td->pmu_if = TEGRA_DFLL_PMU_PWM` (bypassing `vdd-cpu-supply` regulator lookup, `clk-dfll.c:1974`).
   - `dfll_fetch_pwm_params()` (`clk-dfll.c:1846-1895`): reads `nvidia,init-uv`, `nvidia,align-step-uv`, `nvidia,align-offset-uv` (also read earlier in `tegra124_dfll_fcpu_probe()` at `clk-tegra124-dfll-fcpu.c:627-639` before `tegra_cvb_add_opp_table()`), fetches `clocks = <&pmc TEGRA_PMC_CLK_BLINK>` (`pwm_rate = 32768`), and looks up `pinctrl-names = "dvfs_pwm_enable", "dvfs_pwm_disable"` (`clk-dfll.c:1872-1884`).
   - **Small pinmux tip:** In `dvfs_pwm_active_state` / `dvfs_pwm_inactive_state`, include `nvidia,function = "cldvfs";` alongside `nvidia,pins = "dvfs_pwm_pbb1";` (even though cboot already left `0x70003184 = 0x11` muxed to `cldvfs`, `NOTES.md:1223`, `tegra210-p3450-0000.dts:494-510` omits `nvidia,function` only because Nano sets it in a separate boot hog).

#### What `dmesg` and `debugfs` should show when the DFLL locks and `cclk_g` reparents
1. **`dmesg`:**
   - Neither `clk-tegra124-dfll-fcpu.c`, `clk-dfll.c`, nor `tegra124-cpufreq.c` logs a `dev_info()` message on successful probe.
   - Instead, success in `dmesg` is indicated by:
     - **Disappearance** of `cpufreq-tegra124: probe of cpufreq-tegra124 failed with error -2` (`NOTES.md:1218`).
     - **Absence** of any `tegra_dfll_fcpu` or `cpufreq-dt` `dev_err()` messages.
     - Presence of the Energy Model registration message from `dev_pm_opp_of_register_em()` (`cpufreq-dt.c:112`, `CONFIG_ENERGY_MODEL=y` in `defconfig:94`), e.g. `cpu cpu0: EM: created perf domain`.
2. **`/sys/devices/system/cpu/cpufreq/policy0/`:**
   - `scaling_driver` = `cpufreq-dt`
   - `scaling_available_frequencies` = `204000 306000 408000 510000 612000 714000 816000 918000 1020000` (with the `1036800000UL` cap) or up to `2014500` (with the `2014500000UL` cap).
3. **`/sys/kernel/debug/clk/clk_summary`:**
   - `dfllCPU_out` shows `enable_cnt = 1`, `prepare_cnt = 1`, and rate matching the current CPU frequency (e.g. `204000000` at idle or `1020000000` under load).
   - `cclk_g` appears indented as a child of **`dfllCPU_out`** (reparented away from `pll_x` by `tegra124_cpu_switch_to_dfll()`, `tegra124-cpufreq.c:50`).
   - `pll_x` shows `enable_cnt = 0`, `prepare_cnt = 0`.
4. **`/sys/kernel/debug/tegra_dfll_fcpu/` (`clk-dfll.c:1363-1388`):**
   - `enable` = `1` (`dfll_is_running(td)` is true, `clk-dfll.c:1237-1242`).
   - `lock` = `1` (`td->mode == DFLL_CLOSED_LOOP`, `clk-dfll.c:1272-1277`).
   - `rate` = live hardware DVCO counter reading from `DFLL_MONITOR_DATA` (`clk-dfll.c:1299-1305`), within ~1–2% of `scaling_cur_freq * 1000`.
   - `registers` (`clk-dfll.c:1314-1361`):
     - `[0x00] = 0x00000002` (`DFLL_CTRL` = `DFLL_CLOSED_LOOP - 1 = 2`).
     - `[0x10]` (`DFLL_FREQ_REQ`) has bit 22 (`DFLL_FREQ_REQ_FREQ_VALID = 0x00400000`) set.
     - `[0x18]` (`DFLL_OUTPUT_FORCE`) has bit 7 (`DFLL_OUTPUT_FORCE_ENABLE`) **cleared** (`0x000000xx`, closed-loop in control).
     - `[0x40]` (`DFLL_OUTPUT_CFG`) has bit 6 (`DFLL_OUTPUT_CFG_PWM_ENABLE = 0x40`) set along with the `SAFE`, `MAX`, and `MIN` LUT bounds.

---

### 3. Thermal Trips & Cooling Maps Next to the Fan's Active Trips — and Does `mem-thermal`'s Existing EMC Map Matter?

#### Are `cpu-thermal` (`82 °C`) and `gpu-thermal` (`84 °C`) passive trips right next to the fan's active trips?
**Yes — the placement relative to the fan curve in `kernel/dts/darcy.dts:252-322` (`d4cd616`) is well-staged:**
- In `darcy.dts:265-299`, `cpu-thermal` has active fan trips at `45, 55, 65, 75, 85, 95 °C` (`3 °C` hysteresis) mapped to `pwm-fan` levels 1–6 (`darcy.dts:496`: `cooling-levels = <255 190 145 125 96 16 1>`).
- By the time `cpu-thermal` reaches `75 °C` (`fan-75`), the fan is at cooling state 4 (`PWM = 96/255`, ~62% speed).
- Placing the CPU `passive` trip at **`82 °C` (`82000` mC, `2000` mC hysteresis)** means:
  1. For normal workloads (`45–81 °C`), acoustic/active cooling (`pwm-fan` states 1–4) handles the heat without any CPU DVFS throttling.
  2. At `82 °C`, `step_wise` begins stepping down `cpufreq-cpu0` OPPs, and just `3 °C` higher (`85 °C`, `fan-85`) the fan jumps to state 5 (`PWM = 16/255`, ~94% speed), followed by state 6 (`100%` at `95 °C`), hardware `throttle_heavy` (`85%` clock skip at `98.5 °C`, `tegra210.dtsi:2112-2116`), and `critical` (`102.5 °C`, `tegra210.dtsi:2118-2122`).
- Similarly, `gpu-thermal` `passive` at **`84 °C` (`84000` mC)** throttles CPU load before `gpu-Margin-hot-trip` (`99.5 °C`, `tegra210.dtsi:2185-2189`) and `critical` (`103 °C`, `tegra210.dtsi:2191-2195`).
- Adding `#cooling-cells = <2>;` to `&{/cpus/cpu@0}` (or all four `cpu@0..3` nodes, matching `tegra210-smaug.dts:1735-1749`) is required because `of_cpufreq_cooling_register()` (`vendor/linux/drivers/thermal/cpufreq_cooling.c:650-668`) checks `of_property_present(np, "#cooling-cells")` on `policy->cpu` (`cpu0`).

#### Critical catch on `mem-thermal` (`tegra210.dtsi:2133-2177`): `polling-delay-passive` and existing `dram_nominal` (`50 °C`) trip!
**Yes, `mem-thermal`'s existing definition in `tegra210.dtsi:2133-2177` matters in two ways that will break `mem-thermal` passive cooling unless overridden in `darcy.dts`:**

1. **`mem-thermal` has `polling-delay-passive = <0>;` in `tegra210.dtsi:2134`!**
   Look at `tegra210.dtsi:2105` vs `2134` vs `2180`:
   - `cpu-thermal` (`tegra210.dtsi:2105`): `polling-delay-passive = <1000>;`
   - `gpu-thermal` (`tegra210.dtsi:2180`): `polling-delay-passive = <1000>;`
   - `mem-thermal` (`tegra210.dtsi:2134`): **`polling-delay-passive = <0>;`**
   If `polling-delay-passive` is left at `<0>` on `mem-thermal`, the thermal core never schedules periodic passive polling after the `85 °C` threshold interrupt fires: `step_wise` will step `cpufreq-cpu0` down by **1 single OPP step** when `mem-thermal` crosses `85 °C` and then never step down again between `85 °C` and `100 °C` (`mem-hot-trip`).
   **Fix:** Override `polling-delay-passive = <1000>;` in `&{/thermal-zones/mem-thermal}` in `darcy.dts`.

2. **`mem-thermal` already has a `50 °C` `passive` trip (`dram_nominal: mem-nominal-trip`, `tegra210.dtsi:2141-2145`)!**
   In `tegra210.dtsi:2141-2151` and `2166-2176`, `mem-thermal` defines:
   - `dram_nominal: mem-nominal-trip` (`temperature = <50000>; type = "passive";`) mapped in `dram-passive` to `<&emc 0 0>`
   - `dram_throttle: mem-throttle-trip` (`temperature = <70000>; type = "active";`) mapped in `dram-active` to `<&emc 1 1>`
   Because `&emc` registers no cooling device (no EMC table in DT), `dram-passive` and `dram-active` never bind. However, once you set `polling-delay-passive = <1000>;` on `mem-thermal`, the thermal core enables passive polling (`tz->passive > 0`) whenever **any** `passive` trip is crossed — meaning `dram_nominal` (`50 °C`, which `mem-thermal` exceeds constantly even at idle: `46–50.5 °C`) would keep `mem-thermal`'s 1 Hz passive polling timer firing continuously above `50 °C` even though CPU throttling doesn't start until `85 °C`.
   **Fix:** In `&{/thermal-zones/mem-thermal}` in `darcy.dts`, either `/delete-node/ mem-nominal-trip;`, `/delete-node/ mem-throttle-trip;`, `/delete-node/ dram-passive;`, `/delete-node/ dram-active;`, or simply override `dram_nominal`'s `temperature = <85000>;` and `dram-passive`'s `cooling-device = <&{/cpus/cpu@0} THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;`!

---

### 4. Is the Order `A1 → A4 → A2 → A3` Right?

Mostly yes, with **one refinement within `A2` and `A3`**:
- **`A1` (done) → `A4` (next) is right:** `A4` (`darcy-tempmon` systemd unit logging the 4 zones every 10s and calling `systemctl poweroff` if any zone `>= 92000` mC for 2 consecutive readings) is pure userspace, zero kernel risk, and gives an independent safety net at `92 °C` below hardware `throttle_heavy` (`98.5 °C`) and `critical` (`102.5 °C`).
- **Split `A2` across `A3`: `A1 → A4 → A2a (DFLL capped at ~1.02–1.22 GHz) → A3 (thermal passive cooling) → A2b (raise DFLL cap to 2.0145 GHz)`:**
  - Booting **`A2a`** (DFLL + `cpufreq-dt` with `tegra210_cpu_max_freq_table[2]` capped near cboot's frequency) *before* `A3` is good engineering because it isolates the DFLL clock-parent switch (`pll_x` -> `dfllCPU_out`) at a known-safe thermal envelope (power draw at `204–1020 MHz` / `881–900 mV` is *lower* than cboot's fixed `1017.6 MHz` / `1000 mV`).
  - However, **do not raise `tegra210_cpu_max_freq_table[2]` to `2014500000UL` (`A2b`, `2.01 GHz` @ `1227 mV`) until after `A3` (`cpufreq-cpu0` passive cooling maps) is in place and verified.** Even Better: since `A3` is only ~35 lines of DT in `darcy.dts` (`#cooling-cells = <2>` + passive trips/maps) and `of_cpufreq_cooling_register()` is a no-op if `cpufreq-dt` isn't loaded yet, landing `A3` either right after `A2a` (before `A2b`) or together with `A2a` guarantees `2.01 GHz` is never booted without `cpufreq` thermal throttling.

---

## Part B — GPU Test, Hyprland, and Omarchy

### 5. What breaks when Hyprland / Aquamarine Meets `tegra-drm` + `nouveau` on Tegra210?

Tegra210 is a **split render/display (PRIME / KMSRO) architecture** (`vendor/linux/drivers/gpu/drm/tegra/` + `vendor/linux/drivers/gpu/drm/nouveau/`):
- **Display KMS node** (e.g. `/dev/dri/card0`, driver name `tegra`): `tegra-drm` (`host1x` + `dc@54200000` + `dc@54240000` + `sor@54580000`), which has **CRTCs, planes, and the HDMI-A-1 connector**, but **no 3D render node** (`renderD*`).
- **3D Render node** (e.g. `/dev/dri/card1` + `/dev/dri/renderD128`, driver name `nouveau`): `nouveau` bound to `gpu@57000000` (`GM20B`), which has **3D/compute engines (`gr3d`) and `renderD128`**, but **`0` CRTCs and `0` connectors**.

In Mesa, `tegra_dri.so` is a `kmsro` (KMS Render-Only) pipe-loader stub that opens the `nouveau` render node (`nvc0` Gallium driver on GM20B) and shares buffers with the `tegra` KMS fd via PRIME DMA-BUF. When **Aquamarine / Hyprland** starts on this setup, watch out for **four specific failure modes**:

1. **Primary vs. secondary DRM device selection (`AQ_DRM_DEVICES`):**
   - If Aquamarine opens both `/dev/dri/card0` (`tegra`, display-only) and `/dev/dri/card1` (`nouveau`, 0 connectors), or if `card0` happens to be `nouveau` and `card1` is `tegra` (probe order is asynchronous), Aquamarine must create its GBM device on a fd that Mesa can back with `kmsro` (`tegra_dri.so` -> `nouveau`) or render on `nouveau` and import into `tegra`.
   - With Mesa's `kmsro` (`tegra_dri.so` installed in `/usr/lib/dri/tegra_dri.so` via the `mesa` package), calling `gbm_create_device()` directly on the **`tegra` KMS fd** works transparently (Mesa internally opens `renderD128` on `nouveau` and allocates scanout BOs on `tegra`).
   - If Aquamarine's multi-GPU auto-discovery gets confused by the 0-connector `nouveau` card or picks the wrong primary allocator, explicitly setting `AQ_DRM_DEVICES=/dev/dri/cardX` (pointing to the `tegra-drm` card, or `/dev/dri/by-path/platform-50000000.host1x-card`) forces Aquamarine onto the `tegra` KMS device through Mesa `kmsro`.

2. **Hardware cursor plane constraints in `tegra-drm` (`cursor:no_hardware_cursors = true`):**
   Look at `tegra_cursor_atomic_check()` and `tegra_dc_cursor_plane_create()` in `vendor/linux/drivers/gpu/drm/tegra/dc.c:957-1001, 1208-1258`:
   - Because `tegra210_dc_soc_info.has_nvdisplay = false` (`dc.c:3044`), `tegra-drm` creates the cursor plane with **only `DRM_FORMAT_RGBA8888`** (`tegra_legacy_cursor_plane_formats`, `dc.c:957-959, 1231-1233`) — **not** `DRM_FORMAT_ARGB8888`!
   - Furthermore, `tegra_cursor_atomic_check()` (`dc.c:988-995`) rejects any cursor buffer that is not square (`32x32`, `64x64`, `128x128`, or `256x256`), and `tegra_dc_cursor_plane_create()` (`dc.c:1247`) only allows `DRM_FORMAT_MOD_LINEAR`.
   - Wayland compositors (including Aquamarine/Hyprland) standardly allocate `ARGB8888` (`DRM_FORMAT_ARGB8888` / `GBM_FORMAT_ARGB8888`) cursor buffers and often hit atomic commit failures (`-EINVAL`) or channel-swapped cursors on `tegra-drm`'s `RGBA8888`-only legacy cursor plane.
   - **Fix:** Set `cursor:no_hardware_cursors = true` in the Tegra Hyprland platform profile (`default/hypr/platform/tegra.lua`), or `AQ_NO_HARDWARE_CURSORS=1` during Step B2 testing.

3. **NVIDIA block-linear format modifiers (`16BX2_BLOCK`) across `nouveau` + `tegra-drm` (`AQ_NO_MODIFIERS=1` fallback):**
   - In `dc.c:3049` and `706-715`, `tegra210_dc_soc_info.modifiers` advertises `DRM_FORMAT_MOD_LINEAR` and `DRM_FORMAT_MOD_NVIDIA_16BX2_BLOCK(0..5)` (without `SECTOR_LAYOUT`, which `tegra_plane_format_mod_supported()` rejects on Tegra210 at `vendor/linux/drivers/gpu/drm/tegra/plane.c:91-122` because `supports_sector_layout = false` at `dc.c:3039`).
   - `nouveau` (`nvc0`) on GM20B and `tegra-drm` both support `DRM_FORMAT_MOD_NVIDIA_16BX2_BLOCK(0..5)` (`supports_block_linear = true`, `dc.c:3038`). However, if `gbm_bo_create_with_modifiers()` via `kmsro` allocates a tiled BO whose pitch is not 64-byte aligned (`pitch_align = 64`, `dc.c:3041`) or whose modifier metadata fails `tegra_fb_get_tiling()` (`dc.c:759`), atomic pageflip fails with `-EINVAL`.
   - **Fallback to keep in pocket for B2:** If Hyprland starts (`kms` session acquired) but fails its first atomic commit (`drmModeAtomicCommit: Invalid argument`), test with `AQ_NO_MODIFIERS=1` to force `DRM_FORMAT_MOD_LINEAR`.

4. **Missing `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` removal check:**
   - Currently `bootargs` in `darcy.dts:26` and `darcy-system.dts:31` still has `clk_ignore_unused pd_ignore_unused regulator_ignore_unused`. Keep those in place through B1/B2 until GPU/display power domains are fully validated.
   - Also check `nouveau` GPU reclocking / pstate after B1 probe: on Tegra210 GM20B, examine `/sys/kernel/debug/dri/*/pstate` during B1 to verify what clock state `nouveau` selects at boot.

---

### 6. Every Place in `vendor/omarchy-arm` That Needs a Tegra Touch (Plus Anything Missing)

Searching all platform switches across `vendor/omarchy-arm` confirms the port is cleanly factored around `omarchy-hw-platform`. Below is the **complete list of files** that branch on platform or hardware, compared against your Step B3 list:

| # | File in `vendor/omarchy-arm` | Lines | What it currently does & what to change for `tegra` | In brief's B3 list? |
|---|---|---|---|---|
| 1 | `bin/omarchy-hw-platform` | `20-55` | Reads `/proc/device-tree/compatible` (`NUL` -> spaces) and `/proc/device-tree/model`. Match `*nvidia,tegra210*` or `*nvidia,darcy*` -> `echo "tegra"` in both the `compatible` `case` (`:25-39`) and `model` fallback `case` (`:42-55`, e.g. `*"NVIDIA SHIELD"*`). Update summary comment (`:3`). | **Yes** |
| 2 | `bin/omarchy-hw-tegra` *(new)* | — | New predicate script (modeled on `bin/omarchy-hw-apple-silicon:1-7` and `bin/omarchy-hw-raspberry-pi:1-12`): `[[ $(omarchy-hw-platform) == "tegra" ]]`. Used by `default/hypr/platform.lua` and `install/hardware/arm/tegra.sh`. | **Missing from brief** (needed so `platform.lua` & `hardware/arm/tegra.sh` follow repo convention) |
| 3 | `install.sh` | `61-62`, `184-208` | Help text (`:61-62`) and `case "$platform"` banner (`:192-205`): add `tegra) info "Detected NVIDIA Tegra (aarch64)" ;;`. | **Yes** |
| 4 | `install/hardware/arm/vulkan.sh` | `9-21` | `case "$(omarchy-hw-platform)"`: add `tegra)` arm. **Important package check:** In Arch Linux ARM (`alarm`), check `pacman -Ss vulkan` before hardcoding `vulkan-nouveau` — NVK on ALARM `aarch64` may not be built in the stock `vulkan-nouveau` package or may only support Turing+ in the shipped Mesa build (Maxwell GM20B support in NVK is experimental/partial). Gate with `if pacman -Si vulkan-nouveau &>/dev/null; then omarchy-pkg-add vulkan-nouveau; fi` or install `vulkan-swrast` / skip gracefully so `install.sh` never aborts on a missing package. | **Yes** (with ALARM `vulkan-nouveau` caveat) |
| 5 | `install/hardware/arm/tegra.sh` *(new)* | — | New leaf (modeled on `install/hardware/arm/raspberry-pi.sh:1-27`): `source "$OMARCHY_INSTALL/arm/platform.sh"`, `omarchy-hw-tegra || return 0`, writes `"tegra"` to `${OMARCHY_STATE_DIR:-/var/lib/omarchy}/platform`, and installs/enables `darcy-tempmon.service` (or board udev/audio rules). | **Yes** |
| 6 | `install/hardware/all.sh` | `20-24` | Calls `run_logged_arm "$OMARCHY_INSTALL/hardware/arm/apple-silicon.sh"` and `raspberry-pi.sh`. Add `run_logged_arm "$OMARCHY_INSTALL/hardware/arm/tegra.sh"`. | **Yes** |
| 7 | `default/hypr/platform.lua` | `18-20` | Currently checks `omarchy-hw-raspberry-pi` and loads `default.hypr.platform.raspberry-pi`. Add: `elseif o.shell_succeeds(o.shell_quote(paths.omarchy_path .. "/bin/omarchy-hw-tegra")) then require_optional.module("default.hypr.platform.tegra")`. | **Yes** (`bootstrap.lua:20` requires `default.hypr.platform`, which is the actual file that branches) |
| 8 | `default/hypr/platform/tegra.lua` *(new)* | — | Modeled on `default/hypr/platform/raspberry-pi.lua:1-39`: disable blur (`decoration:blur:enabled = false`), shadow (`decoration:shadow:enabled = false`), reduce animations, set `cursor:no_hardware_cursors = true` (see Q5 #2), and set `monitors` default `HDMI-A-1, 1920x1080@60, 0x0, 1` (so a 4K TV defaults to 1080p60 rather than 4K60 on GM20B, while allowing user override in `~/.config/hypr/monitors.lua`). | **Yes** |
| 9 | `default/agents/skills/omarchy/arm.md` & `docs/arm64-port.md` | `arm.md:10`, `arm64-port.md:205-270` | Update documentation and agent skill references if keeping repo tests/docs consistent. | Optional / nice-to-have |
| 10 | `test/shell.d/arm64-platform-test.sh` & `arm64-gating-test.sh` | `26-85`, `41` | If running the repo test suite, add a Darcy DT fixture (`nvidia,darcy\0nvidia,tegra210\0`) and add `hardware/arm/tegra.sh` to the leaf loop in `arm64-gating-test.sh:41`. | Optional / nice-to-have |

#### Two things we checked that do **not** break on Tegra210:
- **`bin/omarchy-hw-nvidia` (`:1-16`) & `default/hypr/nvidia.lua` (`:1-19`):** `omarchy-hw-nvidia` scans `/sys/bus/pci/devices/*` for vendor `0x10de` and PCI class `0x03*`. Because GM20B (`gpu@57000000`) is a platform/SoC device and PCIe is disabled in `darcy.dts`, `omarchy-hw-nvidia` exits `1` (false). That is **good**, because `default/hypr/nvidia.lua` exports `__GLX_VENDOR_LIBRARY_NAME=nvidia` and `LIBVA_DRIVER_NAME=nvidia` for the proprietary desktop driver, which would break Mesa `nouveau`/`tegra` on Darcy.
- **`install/arm/settings.sh` (`:1-227`):** `omarchy_arm_configure_Limine()` skips cleanly on Darcy (`[[ -f /boot/limine.conf || -f /boot/limine/limine.conf || -d /boot/EFI/limine ]] || return 0` at `:21-23`), because Darcy boots via cboot `LNX` android-bootimg partition rather than Limine.

---

### 7. What would I drop or reorder across Part A and Part B?

1. **Reorder `A2` and `A3` into `A1 → A4 → A2a (1.02–1.22 GHz cap) → A3 (passive thermal cooling + mem-thermal fix) → A2b (2.0145 GHz cap)`:**
   - Don't boot `2.0145 GHz` (`A2b`) before `cpufreq-cpu0` passive cooling (`A3`) is active.
   - In `A2a`, consider `1224000000UL` (`1.224 GHz`, `957.6 mV`, `lut_max = 13`) instead of `1036800000UL` (`1.020 GHz`, `900.0 mV`, `lut_max = 10`) so `dfll_build_pwm_lut()` gives the hardware closed-loop integrator 4 PWM steps of headroom above `lut_min = 9` (`880.8 mV`) instead of just 1 step.
2. **In `A3`, fix `mem-thermal` (`polling-delay-passive = <1000>` and remove/override the `50 °C` `dram_nominal` passive trip):**
   - Without `polling-delay-passive = <1000>;` on `mem-thermal`, the `85 °C` passive trip on `mem-thermal` will never poll after its initial threshold interrupt (`tegra210.dtsi:2134`).
   - Without removing or raising `dram_nominal` (`50 °C` `passive` in `tegra210.dtsi:2141-2145`), `mem-thermal` will poll every 1s whenever `mem-thermal > 50 °C`.
3. **In `B2` (Bare Hyprland smoke test), test with `cursor:no_hardware_cursors = true` (or `AQ_NO_HARDWARE_CURSORS=1`) from the start:**
   - `tegra-drm` on Tegra210 only advertises `DRM_FORMAT_RGBA8888` on its hardware cursor plane (`dc.c:957-959, 1231-1233`), which is a known trap for `ARGB8888` Wayland compositors. Setting `cursor:no_hardware_cursors = true` upfront avoids burning a debugging cycle on missing/rejected cursors during the first Hyprland launch.
4. **In `B3` (`install/hardware/arm/vulkan.sh`), don't let `install.sh` hard-fail if `vulkan-nouveau` is absent or non-functional on GM20B:**
   - Hyprland uses GLES2/EGL (`mesa` `nouveau`/`tegra` KMSRO), not Vulkan. Make `vulkan-nouveau` installation conditional (`pacman -Si vulkan-nouveau &>/dev/null`) so `install.sh` succeeds cleanly.
