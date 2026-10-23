# Brief: the SHIELD overheats and shut itself off; fix its power management

**Analysis only.** Do not change files or touch the device. Repository
`~/projects/nvidia` (`NOTES.md`, `kernel/dts/darcy.dts`,
`kernel/dts/darcy-system.dts`, `kernel/darcy.config`), kernel `vendor/linux`
(7.2.11 plus `patches/linux/`), stock NVIDIA darcy DT in
`vendor/lineage-t210-foster/kernel-dts` and
`vendor/lineage-t210-common/kernel-dts`. Cite `file:line`; say plainly what is
a guess. Verify against the source; earlier rounds had confident claims the
source contradicted.

## What happened

The SHIELD TV 2017 (Tegra210 A02, passive cooling, no fan) runs our mainline
Linux. After about 1.5 h up, with nouveau loaded, a Mesa test, a large pacman
install and a compile starting, the board powered off: TV dark, LEDs off,
and the user found the case "really hot". The last readings, about 2 min
earlier, were cpu 92.5 °C, gpu 88.5 °C, pllx 89 °C, mem 93.5 °C, still
rising. After it was unplugged and plugged back in, it booted normally.

## Measured (all on the SHIELD, read-only)

- **Power:** INA3221 VDD_SYS (the 18.9 V input) reads **6.0–6.35 W idle**:
  no GPU driver, nothing running, 4–5 min after boot.
- **Temperature:** 62–67 °C right after boot, 67–70 °C at 5 min, and 83–89 °C
  after an hour at near-idle, before the load.
- **soctherm** (`journalctl -k`): "missing thermtrips, will use critical
  trips as shut down temp". Thermtrip and throttrip are both at 102.5 °C
  (cpu) and 103 °C (gpu, pll, mem), so hardware throttling starts only at
  the shutdown point.
- **PMC:** "i2c-thermtrip node not found, emergency thermal reset disabled".
- **CPU clock:** `cclk_g` on `pll_x` at **1017.6 MHz** (cboot's), fixed.
  `cpufreq-tegra124 ... probe ... failed with error -2`. The DFLL
  (`clock@70110000`) is `status = "disabled"` (mainline tegra210.dtsi:1424-1441;
  mainline `tegra210-p2894.dtsi` doesn't enable it).
- **CPU rail:** the DFLL's PWM pin `dvfs_pwm_pbb1` (pinmux `0x70003184`)
  reads `0x11`: function CLDVFS, **tristated**. Stock gives
  `nvidia,pwm-tristate-microvolts = <1000000>`, so the CPU rail most likely
  sits at a fixed 1.0 V. That's a guess; no INA3221 channel watches VDD_CPU.
- **Idle:** our command line has `cpuidle.off=1`, added for the first boots
  only (commit 371a6dc; `NOTES.md:415, 610` say it "can go once boots are
  routine"). The boot log shows "failed to register cpuidle driver". PSCI
  v1.1 is present, and mainline's `idle-states/cpu-sleep` is C7
  (`0x40000007`), the state stock Android uses.
- **Memory:** EMC at 800 MHz (`pll_m`), fixed ("no memory timings for RAM
  code 1 registered").
- **GPU** (when nouveau was loaded): `vdd-gpu` stayed enabled at 838 mV, so
  nouveau held the rail. Whether it runtime-suspends on Tegra is unknown.

**Stock darcy's DFLL** (`t210-common-platforms/tegra210-p2530-common.dtsi:54-72`):
- status okay, `nvidia,pwm-to-pmic`, `pwm-tristate-microvolts` 1000000
- `sample-rate` 25000, `droop-ctrl` 0xf00, `force-mode` 1, `cf` 6, `ci` 0,
  `cg` 2
- `idle-override`, `one-shot-calibrate` (downstream only)
- `pwm-period-nanoseconds` 2500, `pwm-min-microvolts` 708000,
  `pwm-voltage-step-microvolts` 19200
- pinctrl `dvfs_pwm_enable` / `dvfs_pwm_disable`

Jetson Nano's mainline DFLL (`tegra210-p3450-0000.dts:594-613`) has the same
values, without the two downstream flags. Its pin states toggle only
`nvidia,tristate` on `dvfs_pwm_pbb1` (lines 117-131).

## Proposed changes (not made)

1. **Drop `cpuidle.off=1`** from `darcy-system.dts` bootargs, so CPUs enter
   C7 when idle.
2. **Enable the DFLL in PWM mode** in `darcy.dts`, as Nano does: the
   `clock@70110000` properties above, plus `dvfs_pwm_active_state` /
   `dvfs_pwm_inactive_state` pin states on `dvfs_pwm_pbb1` (tristate
   disable/enable). This lets cpufreq-tegra124 run the CPU from the DFLL
   with DVFS.
3. **Thermal:** a passive trip (for example 80–85 °C) with CPU cooling via
   cpufreq, and maybe the soctherm throttle-cfgs and thermtrip as Jetson's
   DTs have them.
4. Keep nouveau off by default until GPU idle behaviour is known.

## Questions

1. **What most likely powered the board off:** soctherm's thermtrip at
   102.5/103 °C through the PMC (with "emergency thermal reset disabled"),
   the PMIC's own thermal shutdown, or something else? Does the order of
   events matter for what we configure?
2. **`cpuidle.off=1`:** is removing it safe on this firmware (PSCI v1.1,
   NVIDIA's monitor)? What could go wrong (C7 entry or exit hangs, the GIC,
   timers) and how would we see it? Expected savings at idle?
3. **The DFLL in PWM mode:** is copying Nano's node correct for darcy?
   - Which CVB / speedo tables does `clk-dfll-tegra210` /
     `tegra124-cpufreq` use for this SKU (135, `0x87`, CPU speedo 2)?
   - What does the switch from `pll_x` to the DFLL do to the rail at the
     moment of hand-over?
   - What makes it fail safe vs. undervolt and crash?
   - Are the downstream-only `idle-override` / `one-shot-calibrate` needed?
4. **Thermal configuration:** what should the passive trips and cooling
   maps look like on mainline Tegra210 (soctherm throttle-cfgs, cpufreq
   cooling)? Show it the way Jetson TX1 / Nano do. Should the PMC
   `i2c-thermtrip` be configured (MAX77620 power-off through I2C5), as on
   Jetson?
5. **Order and testing:** what order makes each change testable over SSH
   alone, with the INA3221 (power) and soctherm (temperature) as evidence?
   What's a safe test discipline (rollback timer, a temperature guard)?
6. **Anything else** burning power at idle on this setup: EMC at 800 MHz,
   PCIe, XUSB, clocks left on by `clk_ignore_unused` / `pd_ignore_unused`,
   the HDMI/SOR, the cboot-era leftover display?

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-thermal-<your name>.md`
(`ncodex`, `ngrok` or `antigravity`) and reply with only that path.
