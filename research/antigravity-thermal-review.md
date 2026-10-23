# Power & Thermal Management Review (`darcy` / Tegra210 A02)

## 1. What Most Likely Powered the Board Off — and Why Order of Events Matters

### A. Why Hardware Throttling Never Fired Before Shutdown: A Mainline `soctherm.c` Bug
In `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:2104-2165`, the four on-die `soctherm` thermal zones define a 3–4 °C gap between their `hot` trip (bound to `&throttle_heavy`) and their `critical` trip:

| Zone (`tegra210.dtsi`) | `hot` trip (`&throttle_heavy`) | `critical` trip |
|---|---|---|
| `cpu-thermal` (`:2104-2121`) | `98500` mC (98.5 °C) | `102500` mC (102.5 °C) |
| `gpu-thermal` (`:2123-2140`) | `100000` mC (100.0 °C) | `103000` mC (103.0 °C) |
| `mem-thermal` (`:2142-2152`) | `100000` mC (100.0 °C) | `103000` mC (103.0 °C) |
| `pllx-thermal` (`:2154-2164`) | `100000` mC (100.0 °C) | `103000` mC (103.0 °C) |

Yet `journalctl -k` reported that **both** `thermtrip` and `throttrip` (`cpu-heavy` / `gpu-heavy` / `mem-heavy`) were programmed to **102.5 °C (CPU) and 103 °C (GPU/MEM/PLLX)**.

This is caused by a bug in mainline `tegra_soctherm_set_hwtrips()` (`vendor/linux/drivers/thermal/tegra/soctherm.c:737-798`):
1. At `soctherm.c:747-752`, because `nvidia,thermtrips` is absent in `darcy.dts`, the driver logs `"missing thermtrips, will use critical trips as shut down temp"` and sets local variable `temperature` to the `critical` trip (`102500` or `103000` mC).
2. At `soctherm.c:754`, it calls `thermtrip_program(dev, sg, temperature)`, writing `102.5 °C` / `103 °C` into `THERMCTL_THERMTRIP_CTL` (`soctherm.c:481-500`).
3. At `soctherm.c:761`, it looks up `hot_trip = get_hot_trip(tz);` (`98500` / `100000` mC) and finds the bound `throttle_heavy` cooling device (`soctherm.c:765-777`).
4. **Bug at `soctherm.c:780` and `:789`:** It never updates `temperature = hot_trip->temperature;`! It calls `throttrip_program(dev, sg, stc, temperature)` using the stale `thermtrip`/`critical` `temperature` (`102500` / `103000` mC):
   ```c
   /* vendor/linux/drivers/thermal/tegra/soctherm.c:761-790 */
   hot_trip = get_hot_trip(tz);
   if (!hot_trip)
       continue;
   ...
   ret = throttrip_program(dev, sg, stc, temperature); // <-- BUG: passes critical/thermtrip temp instead of hot_trip->temperature!
   ```
5. Worse still, in `tegra210.dtsi:2095-2099`, `throttle_heavy: heavy` has no `nvidia,cpu-throt-percent` property, so `soctherm` couldn't even configure a valid heavy throttle depth until board DT properties are supplied (`soctherm.c:1886-1901`).

As a result, the board had **zero passive cooling** (no `passive` trips in `tegra210.dtsi`, no `cpufreq` driver) and **zero hardware heavy throttling** below the `102.5 °C / 103 °C` shutdown threshold.

### B. What Actually Powered the Board Off?
Two minutes before the power-off, temperatures were already `mem = 93.5 °C` and `cpu = 92.5 °C` and rising while a compile and `pacman` install started (`thermal-brief.md:17-19`). Reaching `102.5 °C` (CPU) or `103.0 °C` (MEM) within ~2 minutes under compile + I/O load is expected. At `102.5 °C / 103.0 °C`, two mechanisms race at the exact same threshold:

1. **Linux software `critical` trip -> PSCI `SYSTEM_OFF` (Most likely #1a):**
   - Although `polling-delay = <0>` on all four zones (`tegra210.dtsi:2105, 2124, 2143, 2155`) and `polling-delay-passive = <1000>` does not poll when no `passive` trip is active (`drivers/thermal/thermal_core.c`), `soctherm` implements `.set_trips = tegra_thermctl_set_trips` (`soctherm.c:661-684, 718`).
   - During registration, `tegra_thermctl_set_trips()` programs `THERMCTL_LVL0_CFG` `UP_THRESH` to the lowest trip above current temperature—which, in `tegra210.dtsi`, is `hot` (`98.5 °C` CPU / `100 °C` MEM) and then `critical` (`102.5 °C` CPU / `103 °C` MEM)—and enables the `THERM_IRQ_TSENSE_VIOLATION` interrupt (`soctherm.c:553-577`).
   - When `cpu` hit `102.5 °C` or `mem` hit `103.0 °C`, `soctherm_thermal_isr_thread()` (`soctherm.c:837-899`) called `thermal_zone_device_update()`, triggering `handle_critical_trips()` -> `hw_protection_shutdown("Temperature too high", ...)` -> `orderly_poweroff()` -> PSCI `SYSTEM_OFF`.
   - Because `darcy` has no physical power button (`key-power` is `status = "disabled"` in `tegra210-p2894.dtsi:1625-1632`), PSCI `SYSTEM_OFF` tells ATF/TLK to power down the MAX77620 PMIC (`i2c@7000d000/pmic@3c`), turning off the TV output and LEDs and latching off until AC power is unplugged and replugged.

2. **Hardware `soctherm` `THERMTRIP` -> PMC (Most likely #1b):**
   - At the exact same `102.5 °C` (CPU) / `103.0 °C` (MEM/GPU/PLLX) threshold, `soctherm` hardware asserts `THERMTRIP` to the PMC (`soctherm.c:481-500`).
   - Why could hardware `THERMTRIP` power off the board even though Linux logged `"i2c-thermtrip node not found, emergency thermal reset disabled"`?
     - Look at `tegra_pmc_init_tsense_reset()` in `vendor/linux/drivers/soc/tegra/pmc.c:2000-2074`: when `i2c-thermtrip` is missing (`:2011-2015`), the kernel prints that warning and **returns immediately without modifying `PMC_SENSOR_CTRL` (`0x1b0`) or `PMC_SCRATCH54`/`55` (`0x258`/`0x25c`)**.
     - Whatever `nvtboot` / `cboot` programmed into `PMC_SENSOR_CTRL` and the PMC scratch / bootrom I2C command block remains active in hardware. Notably, in stock `darcy` (`recovery/9.1.1/blob-parts/13-DTB.dts:6345-6389` and `vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:423-462`), NVIDIA defines `pmc@7000e400/bootrom-commands/power-off-commands/commands@4-003c` writing `0x3b=0x01, 0x42=0x5b, 0x41=0xf8` to MAX77620 (`0x3c` on I2C5). (If `cboot` had instead only armed `PMC_SENSOR_CTRL_ENABLE_RST` without PMIC power-off, the board would have warm-reset and rebooted instead of staying dark.)

3. **MAX77620 PMIC's own thermal shutdown (`TJ > 140 °C`) (Unlikely):**
   - MAX77620 has a hardware die thermal shutdown at `140 °C` (and stock DT sets a software `PMIC-Die` active trip at `120 °C` = `0x1d4c0`, `recovery/9.1.1/blob-parts/13-DTB.dts:438-452`). With the Tegra die at ~100 °C and total board input power under 15 W, the PMIC die on the PCB will not reach 140 °C before Tegra's on-die `cpu`/`mem` sensors hit `102.5 °C / 103.0 °C`.

*How to confirm between (1) and (2) on the next boot:* Run `journalctl -b -1 -n 50` on the SSD. If software `critical` shut it down, `thermal_zoneX: critical temperature reached, shutting down` and systemd shutdown messages will be recorded; if hardware `THERMTRIP` cut PMIC power directly, the journal will end abruptly mid-compile.

### C. Does the Order of Events Matter for What We Configure?
**Yes, directly:**
1. **Stacking all trips at `102.5 / 103 °C` defeated multi-stage protection.** Right now, passive cooling (none), hardware heavy throttling (`throttrip`, due to `soctherm.c:780`), software `critical` shutdown, and hardware `thermtrip` all sit at `102.5 °C / 103 °C`.
2. **Required separation of thresholds:**
   - **80–85 °C (`passive`):** Software `cpufreq` DVFS steps down CPU frequency/voltage smoothly while keeping workloads running.
   - **98.5 °C CPU / 100 °C GPU, MEM, PLLX (`hot` -> `throttle_heavy`):** Hardware CCROC skips 85% of CPU clock pulses (`soctherm.c:1915`) if software DVFS cannot keep up. **Requires fixing `soctherm.c:780`** so `throttrip_program()` uses `hot_trip->temperature` instead of `temperature`.
   - **101.0 °C (`critical`) vs. 102.5 / 103.0 °C (`nvidia,thermtrips`):** Setting software `critical` 1.5 °C below hardware `nvidia,thermtrips` gives Linux a window to sync the SSD and power off cleanly before hardware `THERMTRIP` yanks the PMIC rails.

---

## 2. Removing `cpuidle.off=1`

### A. Is Removing It Safe on This Firmware (PSCI v1.1, NVIDIA's Monitor)?
**Yes.**
- `darcy`'s TOS/ATF secure monitor implements PSCI v1.1 (`NOTES.md:1080`) and already handles `CPU_ON` for `cpu@1..3` (`tegra210-p2894.dtsi:1597-1613`).
- In `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:2057-2070` and `tegra210-p2894.dtsi:1614-1618`, `/cpus/idle-states/cpu-sleep` is already enabled (`status = "okay"`):
  ```dts
  cpu-sleep {
      compatible = "arm,idle-state";
      arm,psci-suspend-param = <0x40000007>;
      entry-latency-us = <100>;
      exit-latency-us = <30>;
      min-residency-us = <1000>;
      status = "okay";
  };
  ```
- Stock `darcy` (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:94-103` and `recovery/9.1.1/blob-parts/13-DTB.dts:791, 10899`) uses the **exact same** PSCI suspend parameter `0x40000007` (Tegra210 C7 individual CPU core power-gate) on this exact secure monitor, and likewise leaves cluster `cc6` disabled.
- `CONFIG_ARM_PSCI_CPUIDLE=y` and `CONFIG_NO_HZ_IDLE=y` are already built into the kernel (`vendor/linux/arch/arm64/configs/defconfig:4, 95`).

### B. What Could Go Wrong (C7 Entry/Exit Hangs, GIC, Timers) and How Would We See It?
1. **Per-CPU Timers across C7 (`arch_timer` vs. `tegra_timer`):**
   - Look at `vendor/linux/drivers/clocksource/timer-tegra.c:372-381`:
     ```c
     static int __init tegra210_init_timer(struct device_node *np)
     {
         /*
          * Arch-timer can't survive across power cycle of CPU core and
          * after CPUPORESET signal due to a system design shortcoming,
          * hence tegra-timer is more preferable on Tegra210.
          */
         return tegra_init_timer(np, false, 460);
     }
     ```
   - Because the Cortex-A57 per-CPU architectural timer loses state when a core power-gates in C7, `timer-tegra.c` registers per-CPU MMIO timers `TIMER10`–`TIMER13` (`timer@60005000`, `tegra210.dtsi:996-1003`, wired to LIC/GIC SPIs `122..125`) with **rating 460** (`timer-tegra.c:379`), beating `arch_sys_timer` (rating 400).
   - Because `TIMER10`–`TIMER13` live in the always-on `timer@60005000` block outside the CPU power partition, per-CPU timer wakeups survive C7 natively—which is why `cpu-sleep` in `tegra210.dtsi:2059-2069` does not even need `local-timer-stop`.
   - *How we would see a timer bug if `tegra_timer` weren't active:* `/sys/devices/system/clockevents/clockevent*/current_device` would say `arch_sys_timer` instead of `tegra_timer`, SSH typing would stutter by hundreds of milliseconds until another IRQ woke the core, and `dmesg` would log `rcu_preempt detected stalls on CPUs/tasks`.

2. **GIC / LIC / PMC Wake Routing:**
   - When `psci_enter_idle_state()` (`drivers/cpuidle/cpuidle-psci.c:218-224`) calls `CPU_PM_CPU_IDLE_ENTER_PARAM_RCU(psci_cpu_suspend_enter, idx, 0x40000007)`, `cpu_pm_enter()` notifies the GICv2 (`gic@50041000`) and LIC (`interrupt-controller@60004000`, `drivers/soc/tegra/irq.c`), and ATF/TLK programs the hardware `flow-controller@60007000` to wake the core on any enabled GIC/LIC interrupt.
   - Note that both mainline `tegra210-p2894.dtsi:1576-1577` and stock `recovery/9.1.1/blob-parts/13-DTB.dts:6190-6191` set `nvidia,cpu-pwr-good-time = <0>` and `nvidia,cpu-pwr-off-time = <0>` on `pmc@7000e400`; ATF/TLK already sets the internal C7 rail timing registers before Linux boots.

3. **C7 Entry/Exit Hang:**
   - *How we would see it:* An immediate hard lockup as soon as `cpuidle-psci` registers during late boot (or when all 4 cores go idle), followed by a hardware watchdog reset (`CONFIG_TEGRA_WATCHDOG=y`, `darcy.config:43`) and a crash log or truncated boot log in `ramoops` (`0xb0000000`, `darcy.dts:26-37`).
   - *How to verify healthy operation over SSH:*
     - `cat /sys/devices/system/cpu/cpuidle/current_driver` -> `psci_idle`
     - `grep . /sys/devices/system/cpu/cpu*/cpuidle/state1/{name,usage,time,rejected}` -> `name: cpu-sleep`, `rejected: 0`, `time` increasing by ~950,000+ us/sec per core at idle.

### C. Expected Savings at Idle
- With `cpuidle.off=1`, all 4 Cortex-A57 cores sit in architectural `WFI` (clocks gated at the core pipeline, but core logic/caches powered and PLLX/clock trees active at `1017.6 MHz` and `VDD_CPU ≈ 1.0 V`).
- Power-gating idle cores in C7 (`cpu-sleep`) removes per-core leakage and clock distribution power. At fixed `1.0 V` / `1017.6 MHz` (before DFLL is enabled), expect **`0.6–1.2 W`** drop in `VDD_SYS` idle power (from `6.0–6.35 W` down to `~5.0–5.5 W`).

---

## 3. The DFLL in PWM Mode (`clock@70110000`)

### A. Is Copying Jetson Nano's Node Correct for `darcy`?
**Yes — the hardware parameters are identical.**
Comparing stock `darcy` (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:54-72`, `vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:86-112`, and compiled `recovery/9.1.1/blob-parts/13-DTB.dts:7599-7629`) against Jetson Nano (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts:117-131, 594-613`):
- Stock `darcy` disables the I2C `max77621@1b` regulator (`status = "disabled"` in `recovery/9.1.1/blob-parts/13-DTB.dts:6749-6768`) and drives `VDD_CPU` via the OVR2 PWM controller on `dvfs_pwm_pbb1` (`clock@70110000`).
- Every single electrical parameter in stock `darcy` (`recovery/9.1.1/blob-parts/13-DTB.dts:7611-7626`) matches Jetson Nano (`tegra210-p3450-0000.dts:594-613`):
  - `nvidia,pwm-to-pmic;`
  - `nvidia,pwm-tristate-microvolts = <1000000>;` (`0xf4240`)
  - `nvidia,pwm-min-microvolts = <708000>;` (`0xacda0`)
  - `nvidia,pwm-voltage-step-microvolts = <19200>;` (`0x4b00`, 33 steps `708.0 mV .. 1322.4 mV`)
  - `nvidia,pwm-period-nanoseconds = <2500>;` (`0x9c4`, 400 kHz PWM)
  - `nvidia,sample-rate = <25000>;` (`0x61a8`), `nvidia,droop-ctrl = <0x00000f00>;`, `nvidia,force-mode = <1>;`
  - `nvidia,cf = <6>;`, `nvidia,ci = <0>;`, `nvidia,cg = <2>;`
- For `pinmux@700008d4`: `tegra210-p2894.dtsi:1110-1117` already configures `dvfs_pwm_pbb1` in `state_boot` with `nvidia,function = "cldvfs"`, `nvidia,pull = <TEGRA_PIN_PULL_NONE>`, `nvidia,tristate = <TEGRA_PIN_ENABLE>`, `nvidia,open-drain = <TEGRA_PIN_DISABLE>` (matching the measured `0x70003184 = 0x11`). Toggling `nvidia,tristate` between `<TEGRA_PIN_DISABLE>` (`dvfs_pwm_active_state`) and `<TEGRA_PIN_ENABLE>` (`dvfs_pwm_inactive_state`) as in `tegra210-p3450-0000.dts:117-131` is completely valid.

### B. Which CVB / Speedo Tables Does Mainline Use for SKU `0x87` (135), CPU Speedo 2?
1. **Speedo ID selection (`vendor/linux/drivers/soc/tegra/fuse/speedo-tegra210.c:62-75`):**
   - For `sku = 0x87` (135) and `tegra_sku_info.revision != TEGRA_REVISION_A01` (our chip is A02, `cpu_process_id = 0`, `cpu_speedo_value = 2089`, `NOTES.md:1078`), `rev_sku_to_speedo_ids()` assigns **`cpu_speedo_id = 2`**.
2. **CVB table & max frequency (`vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:175-214, 515-524`):**
   - `get_dfll_data()` (`:659`) selects `tegra210_dfll_fcpu_ops` (`:646`), which uses `tegra210_cpu_cvb_tables` (`:503-526`) and `tegra210_cpu_max_freq_table` (`:175-180`).
   - It matches the entry at **`clk-tegra124-dfll-fcpu.c:515-524`**:
     - `.speedo_id = 2`, `.process_id = 0`
     - `.min_millivolts = 870` (`870 mV` minimum OPP clamp)
     - `.max_millivolts = 1227` (`1227 mV` maximum OPP clamp)
     - `.entries = TEGRA210_CPU_CVB_TABLE` (`:189-214`, 20 OPPs from `204 MHz` to `2218.5 MHz`)
   - And `tegra210_cpu_max_freq_table[2]` (`:178`) is **`2218500000UL` (2.2185 GHz)**.
3. **Computed Voltages for `darcy` (`speedo = 2089`, `cvb.c:30-60`, `19.2 mV` PWM steps above `708 mV`):**
   - **`204.0 MHz` – `921.6 MHz`:** Raw CVB formula yields `< 870 mV`, so `tegra_cvb_add_opp_table()` (`cvb.c:103`) clamps all of them to `min_millivolts = 870 mV`. In `clk-dfll.c:663`, `find_vdd_map_entry_min(td, 870000)` rounds up to PWM step `vsel = 9` -> **`880.8 mV`**.
   - **`1036.8 MHz`:** CVB = `872 mV` -> PWM step `vsel = 9` (**`880.8 mV`**). *(Compare to cboot's fixed `1017.6 MHz` @ `1000 mV`: even at 1.04 GHz, DFLL drops `VDD_CPU` from `1.000 V` to `0.881 V`, cutting dynamic power by `22%`!)*
   - **`1530.0 MHz`:** CVB = `1025 mV` -> PWM step `vsel = 17` (**`1034.4 mV`**).
   - **`1912.5 MHz`:** CVB = `1175 mV` -> PWM step `vsel = 25` (**`1188.0 mV`**).
   - **`2014.5 MHz` & `2218.5 MHz`:** Both entries in `TEGRA210_CPU_CVB_TABLE` (`:211-212`) have flat coefficients `{ 1227000, 0, 0 }` = `1227 mV` -> PWM step `vsel = 28` (**`1245.6 mV`**).
   - **Important Warning (`2218.5 MHz` vs. Stock `2014.5 MHz`):** Stock `darcy` (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-foster-cpufreq.dtsi:19-40` and `recovery/9.1.1/blob-parts/13-DTB.dts:10803`) caps the CPU frequency table at **`2014.5 MHz`** (`0x1ebd24` kHz), whereas mainline `tegra210_cpu_max_freq_table[2]` (`clk-tegra124-dfll-fcpu.c:178`) exposes **`2218.5 MHz`**. Without a `scaling_max_freq` cap or passive thermal cooling, `cpufreq` will boost to `2.2185 GHz` @ `1.246 V` (`~3.3x` higher dynamic power than cboot's `1.017 GHz` @ `1.0 V`).

### C. What the Switch from `pll_x` to the DFLL Does to the Rail at Hand-Over
Tracing `tegra_dfll_register()` (`vendor/linux/drivers/clk/tegra/clk-dfll.c:1951-2023`) and `tegra124_cpu_switch_to_dfll()` (`vendor/linux/drivers/cpufreq/tegra124-cpufreq.c:31-55`):
1. **During DFLL probe (`dfll_init_out_if`, `clk-dfll.c:729-782`):**
   - `dvfs_pwm_pbb1` is placed in `dvfs_pwm_disable` (tristated -> `VDD_CPU = 1.000 V`).
   - Because `nvidia,force-mode = <1>` (`DFLL_FORCE_FIXED`) and `reg_init_uV = 1000000`, `find_vdd_map_entry_min(td, 1000000)` (`clk-dfll.c:766`) computes `vsel = DIV_ROUND_UP(1000000 - 708000, 19200) = 16` (**`1015.2 mV`**).
   - `dfll_set_force_output_value(td, 16)` and `dfll_set_force_output_enabled(td, true)` (`:772-774`) arm `DFLL_OUTPUT_FORCE` with `vsel = 16` (`1015.2 mV`) while the PWM pin is still tristated.
2. **During `cpufreq-tegra124` probe (`tegra124_cpu_switch_to_dfll`, `tegra124-cpufreq.c:36-50`):**
   - `clk_set_rate(priv->dfll_clk, rate)` (`:37`, `rate = 1017.6 MHz`): records `td->last_req` for `1017.6 MHz` (`lut_index` for `880.8 mV`) while DFLL is still disabled (`clk-dfll.c:1158-1161`).
   - **`clk_set_parent(priv->cpu_clk, priv->pllp_clk)` (`:41`):** switches `cclk_g` from `pll_x` (`1017.6 MHz`) down to `pll_p_out4` (**`408 MHz`**).
   - **`clk_prepare_enable(priv->dfll_clk)` (`:45`):**
     - `dfll_enable()` (`clk-dfll.c:983-1002`) enters `DFLL_OPEN_LOOP` (PWM pin still tristated at `1.000 V`).
     - `dfll_lock()` (`clk-dfll.c:1016-1039`) un-tristates `dvfs_pwm_pbb1` via `dfll_pwm_set_output_enabled(td, true)` (`:1029`). Because `DFLL_OUTPUT_FORCE_ENABLE` is set with `vsel = 16`, **the rail transitions from `1.000 V` (tristate) to `1.0152 V` (forced PWM)**—a +15.2 mV step with zero droop.
     - `dfll_set_mode(td, DFLL_CLOSED_LOOP)` (`:1036`) and `dfll_program_rate(td)` (`:1037` -> `:1074-1114`) write `DFLL_FREQ_REQ` for `1017.6 MHz`, wait for the DVCO frequency counter to lock (`dfll_wait_clk_dvco`), and only then clear `DFLL_OUTPUT_FORCE_ENABLE` (`:1109`), letting the closed-loop integrator ramp `VDD_CPU` smoothly from `1015.2 mV` to `880.8 mV`.
   - **`clk_set_parent(priv->cpu_clk, priv->dfll_clk)` (`tegra124-cpufreq.c:49`):** switches `cclk_g` from `408 MHz` (`pll_p`) onto `dfllCPU_out` (`1017.6 MHz`).

### D. What Makes It Fail Safe vs. Undervolt and Crash?
- **Why it is fail-safe:**
  1. The CPU runs at **408 MHz** on `pll_p_out4` during the entire PWM un-tristate and closed-loop lock sequence (`tegra124-cpufreq.c:41-49`).
  2. `DFLL_OUTPUT_FORCE` holds the PWM output at **`1015.2 mV`** (`vsel = 16`) at the instant `dvfs_pwm_pbb1` un-tristates, releasing to closed-loop only after the DVCO reaches target rate (`clk-dfll.c:764-775, 1098-1109`).
  3. Hardware `DFLL_OUTPUT_LIMITS` (`lut_min`, `lut_max`), `lut_safe` (`900.0 mV`), and `min_millivolts = 870` (`880.8 mV`) prevent the closed loop from driving below `880.8 mV` (`clk-dfll.c:650-678`).
  4. Hardware droop control (`nvidia,droop-ctrl = <0x00000f00>`) halves `dfllCPU_out` frequency within cycles if `VDD_CPU` droops.
- **What would make it undervolt/crash if misconfigured:**
  - Wrong `pwm-min-microvolts` (`708000`), `pwm-voltage-step-microvolts` (`19200`), or `pwm-period-nanoseconds` (`2500`).
  - Leaving a pull-up/pull-down or open-drain enabled on `dvfs_pwm_pbb1` (distorting the tristate 1.0 V bias or PWM duty cycle).
  - Running unconstrained at `2218.5 MHz` (above stock `darcy`'s `2014.5 MHz` ceiling). We can prevent `2218.5 MHz` either via `scaling_max_freq` in userspace or by adding `opp-suspend` / disabling the 2.22 GHz OPP.

### E. Are Downstream-Only `nvidia,idle-override` / `nvidia,one-shot-calibrate` Needed?
**No.** Mainline `vendor/linux/drivers/clk/tegra/clk-dfll.c` does not parse either property (neither string exists anywhere in `vendor/linux/drivers/clk/tegra/`), and mainline Jetson Nano (`tegra210-p3450-0000.dts:594-613`) and Pixel C (`tegra210-smaug.dts:1734-1752`) omit both. Mainline closed-loop DFLL tracks `clk_m` (38.4 MHz) continuously and parks at `lut_min` when disabled.

---

## 4. Thermal Configuration (Passive Trips, `soctherm` `throttle-cfgs`, and `i2c-thermtrip`)

### A. Kernel Config & Driver Bug Note
1. **`CONFIG_TEGRA_SOCTHERM`:** In `vendor/linux/arch/arm64/configs/defconfig:793`, `CONFIG_TEGRA_SOCTHERM=m` (while `CONFIG_CPU_THERMAL=y` at `:772`). Adding `CONFIG_TEGRA_SOCTHERM=y` to `kernel/darcy.config` ensures thermal zones and hardware trips are programmed built-in at boot without depending on module loading.
2. **Fix `soctherm.c:780` (`patches/linux/`):** In `vendor/linux/drivers/thermal/tegra/soctherm.c:780` (and the log message at `:789`), change `temperature` to `hot_trip->temperature` so `throttrip_program()` programs `cpu-heavy` to `98500` mC and `gpu/mem/pllx-heavy` to `100000` mC instead of `102500 / 103000` mC.

### B. Device Tree Snippet (`darcy.dts`) — Following Jetson TX1 / Nano & Smaug
Mainline `tegra210.dtsi:2019-2055` already sets `#cooling-cells = <2>` on `cpu0..cpu3`, and `tegra210.dtsi:2082-2166` already defines `soctherm@700e2000`, `throttle_heavy: heavy`, and the four thermal zones (`cpu-thermal`, `gpu-thermal`, `mem-thermal`, `pllx-thermal`) with `hot` (`<&throttle_heavy 1 1>`) and `critical` trips.

Following Jetson TX1 (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2180.dtsi:342-357`), Pixel C (`tegra210-smaug.dts:1994-2070`), and stock `darcy` (`recovery/9.1.1/blob-parts/13-DTB.dts:168-259, 7654-7667`), add to `kernel/dts/darcy.dts`:

```dts
#include <dt-bindings/thermal/tegra124-soctherm.h>
#include <dt-bindings/thermal/thermal.h>

/* Inside /pinmux@700008d4 (matching tegra210-p3450-0000.dts:117-131): */
dvfs_pwm_active_state: dvfs_pwm_active {
	dvfs_pwm_pbb1 {
		nvidia,pins = "dvfs_pwm_pbb1";
		nvidia,tristate = <TEGRA_PIN_DISABLE>;
	};
};

dvfs_pwm_inactive_state: dvfs_pwm_inactive {
	dvfs_pwm_pbb1 {
		nvidia,pins = "dvfs_pwm_pbb1";
		nvidia,tristate = <TEGRA_PIN_ENABLE>;
	};
};

/* DFLL in PWM mode (matching tegra210-p3450-0000.dts:594-613 & tegra210-p2530-common.dtsi:54-72): */
/ {
	clock@70110000 {
		status = "okay";

		nvidia,pwm-to-pmic;
		nvidia,pwm-tristate-microvolts = <1000000>;
		nvidia,pwm-min-microvolts = <708000>;
		nvidia,pwm-voltage-step-microvolts = <19200>;
		nvidia,pwm-period-nanoseconds = <2500>;

		nvidia,sample-rate = <25000>;
		nvidia,droop-ctrl = <0x00000f00>;
		nvidia,force-mode = <1>;
		nvidia,cf = <6>;
		nvidia,ci = <0>;
		nvidia,cg = <2>;

		pinctrl-names = "dvfs_pwm_enable", "dvfs_pwm_disable";
		pinctrl-0 = <&dvfs_pwm_active_state>;
		pinctrl-1 = <&dvfs_pwm_inactive_state>;
	};

	soctherm@700e2000 {
		nvidia,thermtrips = <TEGRA_SOCTHERM_SENSOR_CPU 102500
				     TEGRA_SOCTHERM_SENSOR_GPU 103000
				     TEGRA_SOCTHERM_SENSOR_MEM 103000
				     TEGRA_SOCTHERM_SENSOR_PLLX 103000>;

		throttle-cfgs {
			/* Matches tegra210-p2180.dtsi:350-355 & stock 13-DTB.dts:7660-7667 */
			heavy {
				nvidia,priority = <100>;
				nvidia,cpu-throt-percent = <85>;
				nvidia,gpu-throt-level = <TEGRA_SOCTHERM_THROT_LEVEL_HIGH>;
			};
		};
	};

	thermal-zones {
		cpu-thermal {
			polling-delay-passive = <500>; /* stock darcy uses 500 ms (13-DTB.dts:170) */

			trips {
				cpu_passive: passive {
					temperature = <82000>;
					hysteresis = <2000>;
					type = "passive";
				};

				/* Lower software critical 1.5 C below hardware thermtrip (102.5 C)
				 * so Linux can sync and poweroff cleanly first: */
				critical {
					temperature = <101000>;
				};
			};

			cooling-maps {
				cpu-passive {
					trip = <&cpu_passive>;
					cooling-device = <&cpu0 THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
				};
			};
		};

		/* MEM hit 93.5 C (hottest zone) during pacman/compile; throttle CPU when MEM is hot too: */
		mem-thermal {
			polling-delay-passive = <1000>;

			trips {
				mem_passive: passive {
					temperature = <85000>;
					hysteresis = <2000>;
					type = "passive";
				};

				critical {
					temperature = <101500>;
				};
			};

			cooling-maps {
				mem-passive {
					trip = <&mem_passive>;
					cooling-device = <&cpu0 THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
				};
			};
		};
	};
};
```
*(Adding `mem_passive` mapped to `&cpu0` is particularly valuable on `darcy` because EMC is fixed at 800 MHz and `mem` was the hottest sensor at `93.5 °C` during the incident; throttling CPU memory traffic cools the memory controller and PoP/adjacent DRAM as well.)*

### C. Should PMC `i2c-thermtrip` Be Configured?
On Jetson TX1 (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2180.dtsi:306-312`), `pmc@7000e400` includes:
```dts
pmc@7000e400 {
	i2c-thermtrip {
		nvidia,i2c-controller-id = <4>;
		nvidia,bus-addr = <0x3c>;
		nvidia,reg-addr = <0x36>;
		nvidia,reg-data = <0x80>;
	};
};
```
- Controller `4` is `i2c@7000d000` (PWR_I2C / I2C5), `0x3c` is the MAX77620 PMIC (`tegra210-p2894.dtsi:1333`), register `0x36` is `MAX77620_REG_CNFGGLBL1`, and `0x80` (`BIT(7)`) is `SFT_RST` (cold reset / power-off).
- In `vendor/linux/drivers/soc/tegra/pmc.c:2000-2074`, `tegra_pmc_init_tsense_reset()` writes `PMC_SENSOR_CTRL` (`0x7000e5b0`), `PMC_SCRATCH54` (`0x7000e658`), `PMC_SCRATCH55` (`0x7000e65c`), and the checksum in `PMC_SCRATCH53` (`0x7000e654`).
- **Recommendation:** Before adding `i2c-thermtrip`, read `0x7000e5b0`, `0x7000e654`, `0x7000e658`, and `0x7000e65c` over SSH on the running system.
  - Stock `darcy` (`recovery/9.1.1/blob-parts/13-DTB.dts:6182, 6345-6389`) marks `nvidia,secure-pmc` and uses `bootrom-commands/power-off-commands` (`0x3b=0x01, 0x42=0x5b, 0x41=0xf8`).
  - If `cboot` already pre-programmed `PMC_SENSOR_CTRL` and `PMC_SCRATCH54/55` (and locked `PMC_SENSOR_CTRL`), we should leave `cboot`'s values intact; if those registers read `0x0` and are NS-writable, adding the `i2c-thermtrip` node above enables hardware PMIC shutdown at `102.5 / 103.0 °C`.

---

## 5. Order of Changes and Safe SSH Testing Discipline

### A. Step-by-Step Order (One Change per Boot, Verified via INA3221 & `soctherm`)

1. **Step 0 — Read-Only Forensics & Baseline (before rebooting):**
   - Check `journalctl -b -1 -n 100` to see whether the previous shutdown logged `critical temperature reached` or died abruptly.
   - Read PMC registers `0x7000e5b0` (`PMC_SENSOR_CTRL`) and `0x7000e654..0x7000e65c` (`PMC_SCRATCH53..55`).
   - Record 5-minute idle baseline from `/sys/bus/i2c/devices/1-0040/hwmon/hwmon*/{in3_input,curr3_input}` (`VDD_SYS` W) and `/sys/class/thermal/thermal_zone{0..3}/temp`.

2. **Step 1 — Drop `cpuidle.off=1` from `darcy-system.dts` (DTS-only):**
   - *Why first:* Zero voltage/clock risk, immediately cuts idle power so the board stops cooking at 83–89 °C while sitting idle, and validates PSCI C7 + `tegra_timer` + GIC wakeups in isolation.
   - *SSH verification:*
     - `cat /sys/devices/system/cpu/cpuidle/current_driver` -> `psci_idle`
     - `grep . /sys/devices/system/cpu/cpu*/cpuidle/state1/{usage,time,rejected}` -> `rejected = 0`, high residency
     - INA3221 `VDD_SYS` drops by `~0.6–1.2 W` at idle (`~5.0–5.5 W`), and `soctherm` idle temps drop accordingly.

3. **Step 2 — Add `soctherm` `nvidia,thermtrips`, `throttle-cfgs/heavy`, `passive` trips + `cooling-maps`, and the 1-line `soctherm.c:780` fix:**
   - *Why second (before enabling DFLL):* Puts the thermal safety net in place *before* unlocking 2.0–2.2 GHz @ 1.25 V on the CPU rail.
   - *SSH verification:*
     - `dmesg | grep soctherm` confirms `thermtrip` at `102500 / 103000 mC` and **`throttrip` (`cpu-heavy`) at `98500 mC` (`gpu/mem/pllx-heavy` at `100000 mC`)**.
     - `/sys/class/thermal/thermal_zone0/trip_point_*_{temp,type}` shows `passive` (`82000`), `hot` (`98500`), `critical` (`101000`).

4. **Step 3 — Enable `clock@70110000` (DFLL in PWM mode) + `dvfs_pwm_pbb1` pinctrl in `darcy.dts`:**
   - *Why third:* With C7 working and `cpu-passive` cooling maps already active, `cpufreq-tegra124` probes `cpufreq-dt`, which immediately binds `thermal-cpufreq-0` to `cpu-thermal` and `mem-thermal`.
   - *Initial frequency cap:* Configure a boot-time rule setting `scaling_max_freq` to `1530000` (1.53 GHz @ 1.03 V) or stock's ceiling `2014500` (2.01 GHz) and `scaling_governor` to `schedutil` or `ondemand`.
   - *SSH verification:*
     - Pinmux `0x70003184` reads `0x01` (CLDVFS, tristate disabled).
     - `scaling_cur_freq` drops to `204000` kHz at idle (`VDD_CPU = 880.8 mV`).
     - INA3221 `VDD_SYS` idle power drops to **`~3.8–4.5 W`**, and idle `soctherm` temperatures settle ~15–20 °C lower than before.
     - Run a bounded load (`stress-ng --cpu 4 --timeout 120s`) while streaming `VDD_SYS`, `scaling_cur_freq`, and `thermal_zone*/temp` every 1 s; verify `thermal-cpufreq-0` throttles `scaling_cur_freq` if `cpu-thermal` reaches `82 °C`.

### B. Safe Test Discipline (Rollback Timer & Temperature Guard)
Because a **power-off** (`SYSTEM_OFF` or PMIC thermtrip) latches the box off until someone physically unplugs the power brick, while a **warm reboot** keeps the box powered on and reachable over SSH:
1. **Hardware watchdog + Automatic Rollback Timer:**
   - Keep `CONFIG_TEGRA_WATCHDOG=y` (`darcy.config:43`) active with `RuntimeWatchdogSec=30s` in `/etc/systemd/system.conf` so any C7 or DFLL hang triggers a warm reset rather than cooking in a wedged state.
   - Before rebooting into a test kernel/DTB, stage the known-good `/boot` files and start a boot-time transient timer (`systemd-run --on-active=180s`) that copies the known-good `/boot` back and runs `systemctl reboot` unless explicitly disarmed over SSH after verification.
2. **Userspace Temperature Guard Daemon:**
   - Run a small root script in the background polling `/sys/class/thermal/thermal_zone{0..3}/temp` every 2 seconds:
     - **If any zone >= 86000 (86 °C):** write `204000` to `/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq` and `pkill -TERM` test workloads (`make`, `stress-ng`).
     - **If any zone >= 92000 (92 °C):** run `sync && systemctl reboot -f` (a warm **reboot**, *never* `poweroff`), resetting clocks to boot defaults while keeping the board alive on SSH.

---

## 6. Everything Else Burning Power at Idle on This Setup

1. **`clk_ignore_unused` / `pd_ignore_unused`: NOT present (already clean).**
   - Neither flag is in `kernel/dts/darcy-system.dts:20` or `kernel/dts/darcy.dts:19` (`NOTES.md:418-420`), so unused clocks and power domains are already gated at `late_initcall`.

2. **The cboot-era leftover HDMI display (`simpledrm` + `dc@54200000` + `sor@54580000` + `pll_d2`): ~0.6–1.0 W.**
   - `darcy.dts:39-45` binds `simpledrm` to the `1920x1080x32` (`8.29 MB`) framebuffer at `0x92cb2000` left active by `cboot`.
   - Because `simpledrm` cannot power down `dc@54200000` or `sor@54580000`, Display Controller A continuously DMAs **498 MB/s** (`1920 * 1080 * 4 * 60 Hz`) from DRAM (`EMC`/`MC`) and drives `sor1` TMDS clocks (`pll_d2`) and HDMI rails (`vdd-hdmi-dp` 1.05 V on `max77620_ldo8`, `vdd_hdmi` 5 V) 24/7—even when only using SSH with the TV off. That continuous 498 MB/s DMA stream also prevents MC/EMC deep idle.

3. **EMC locked at 800 MHz on `pll_m` ("no memory timings for RAM code 1 registered"): ~0.5–1.0 W (and main driver of `mem` = 93.5 °C).**
   - `external-memory-controller@7001b000` (`tegra210.dtsi:1503-1517`) has no `emc-timings-1` table in mainline `tegra210-p2894.dtsi`, so DRAM stays locked at `800 MHz` on `pll_m` with `vdd-core` (`max77620_sd0`) at boot voltage.
   - In stock `darcy` (`recovery/9.1.1/blob-parts/13-DTB.dts:9145-9660` and `tegra210-foster-cpufreq.dtsi:44-54`), `emc-table@1` scales EMC down to **`40.8 / 68 / 102 / 204 MHz`** on `pllp_out0` at idle (gating `pll_m` and lowering `vdd-core` min requirement to `800 mV`), only scaling up to `800–1600 MHz` when CPU frequency exceeds `710 MHz`.

4. **External USB 3.0 SSD + XUSB host (`usb@70090000` / `padctl@7009f000`): ~0.8–1.5 W included in `VDD_SYS`.**
   - INA3221 channel 2 (`VDD_SYS` at 18.9 V, `recovery/9.1.1/blob-parts/13-DTB.dts:6617-6621`) measures total board input power, which includes the `vdd_usb_5v0` rail feeding the external USB root SSD (`darcy-system.dts:20`) plus Tegra's `xusba`/`xusbc` power domains and USB3 UPHY. An idle USB-to-NVMe/SATA bridge alone typically draws `0.8–1.2 W` on 5 V VBUS.

5. **PCIe (`pcie@1003000`) + RTL8168 Gigabit Ethernet (`pci@2,0`) + Always-On PMIC LDOs: ~0.4–0.6 W.**
   - Unused 4-lane `pci@1,0` is already `status = "disabled"` (`darcy.dts:108-115`), so its UPHY lanes are off. Active 1-lane `pci@2,0` (RTL8168 Ethernet) plus `max77620_ldo1` (`vdd-pex` 1.075 V, `regulator-always-on`) and `max77620_ldo3` (`vdd-3v3-eth` 3.3 V, `regulator-always-on` in `tegra210-p2894.dtsi:1479-1510`) draw ~0.4–0.6 W for the active 1000BASE-T link and PEX PLL/UPHY.

6. **Note on `darcy`'s Hardware Cooling Fan (`pwm-fan` on PWM3 / `pe7` + `vdd_fan` on `pe4`):**
   - While the brief treats the unit as passively cooled, note that `kernel/dts/darcy.dts:85-89` explicitly sets `/pwm-fan { status = "disabled"; };` (and `pwm@7000a000` is disabled in `tegra210.dtsi:1264`; see `NOTES.md:65, 406-411, 1250`). Stock `darcy` (`tegra210-p2894.dtsi:1653-1662, 1798-1808` and `vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-pwm-fan.dtsi:1-41`) powers an internal 5 V fan via `vdd_fan` (`TEGRA_GPIO(E, 4)`) and drives its speed via `pwm@7000a000` channel 3 (`pe7`). If the physical fan is still present in the chassis, enabling `pwm@7000a000` and `pwm-fan` (`CONFIG_PWM_TEGRA`, `CONFIG_SENSORS_PWM_FAN`) alongside passive `cpufreq` cooling will prevent heat soak during multi-hour builds.
