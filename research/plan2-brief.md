# Brief: CPU power management, then the GPU test and the desktop, on darcy

**Analysis only.** Do not change files or touch the device. Repository
`~/projects/nvidia` (`NOTES.md`, `kernel/dts/darcy.dts`,
`kernel/dts/darcy-system.dts`, `kernel/darcy.config`, `patches/linux/`),
kernel `vendor/linux` (7.2.11 with `patches/linux/0001-0002` applied in the
build), stock darcy DT in `vendor/lineage-t210-foster/kernel-dts` and
`vendor/lineage-t210-common/kernel-dts`, the Omarchy port in
`vendor/omarchy-arm` (`docs/arm64-port.md`, `install.sh`, `install/`). Cite
`file:line`. Say plainly what is a guess. Check claims in the source: last
round, several confident claims were wrong. `throttle_heavy` *does* have
`nvidia,cpu-throt-percent` (`tegra210.dtsi:1407`). Tegra210's CPU nodes have
*no* `#cooling-cells`. The command line *does* have `clk_ignore_unused
pd_ignore_unused regulator_ignore_unused`. Mainline has *no* `i2c-thermtrip`
on any Tegra210 board.

## Where things stand (all measured)

**The overheating is understood.** darcy has a fan (AFTVnews' 2017 teardown
shows it), and our Linux never ran it.
- Commit d4cd616 adds `pwm-fan`: PWM3 on `pe7`, `vdd_fan` on GPIO E4, the
  tachometer on G0. The fan's PWM input is inverted (measured), so the
  `cooling-levels` count down, with active trips 45–95 °C on
  `cpu-thermal`.
- Idle: CPU **43 °C**, **5.0 W** (VDD_SYS, INA3221), the fan at level 1
  (25%, ~2375 RPM). Without the fan it was 83–89 °C and 6.0–6.35 W.
- `patches/linux/0002` fixes soctherm programming its hardware throttle at
  the shutdown temperature (regression from commit 5136f99b9a4a). It now
  throttles at 98.5 °C CPU / 100 °C GPU.

**Still true:**
- `cpuidle.off=1` on the command line.
- No DFLL: `cpufreq-tegra124` fails with -2, and `cclk_g` is on `pll_x` at
  1017.6 MHz. The CPU rail is presumably at its 1.0 V tristate level (PWM
  pin `dvfs_pwm_pbb1` reads CLDVFS, tristated).
- EMC fixed at 800 MHz.
- nouveau works when loaded by hand: GM20B, render node, Mesa GL ES 3.2 on
  `NV12B` via surfaceless and GBM. It is blocked at boot.

**Checked this round:**
- All four CPUs' clockevents are `tegra_timer` (always-on block), and the
  broadcast is `bc_hrtimer`.
- PMC `PMC_SENSOR_CTRL` (`0x1b0`) and SCRATCH53–55 (`0x254-0x25c`) read 0
  through the secure monitor. cboot didn't arm a thermal reset.
- The overheating boot's journal ends mid-SSH-session, with no shutdown or
  thermal line; the last minutes weren't flushed.
- `tegra210_cpu_max_freq_table[2]` = 2218500000
  (`clk-tegra124-dfll-fcpu.c:178`). Stock darcy's cpufreq table stops at
  2014.5 MHz.
- Governors: `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y`; performance,
  userspace and ondemand built in; powersave and conservative modules.
  `cpufreq.default_governor=` exists (`drivers/cpufreq/cpufreq.c:52, 1118`).

## Part A: CPU power management, one change per boot

- **A1. Drop `cpuidle.off=1`.** Both of you rated this low-risk last round.
  Running now, measured: `psci_idle`, the `cpu-sleep` counters, no RCU
  stalls, a long idle, power.
- **A2. The DFLL in PWM mode,** copied from Jetson Nano
  (`tegra210-p3450-0000.dts:594-613`): stock darcy's values,
  `dvfs_pwm_active_state` / `dvfs_pwm_inactive_state` on `dvfs_pwm_pbb1`
  (tristate off/on, `nvidia,function = "cldvfs"` explicit since our pinmux
  `boot` state is never applied).
  - **The cap:** a new `patches/linux/0003` setting
    `tegra210_cpu_max_freq_table[2]` to **1036800000** for the first
    validation boot, then a second build at **2014500000** (stock's top).
  - **Alternatively**, boot with `cpufreq.default_governor=userspace` or
    `powersave` and raise by hand.
- **A3. CPU cooling:**
  - `#cooling-cells = <2>` on `cpu@0..3`
  - passive trips mapped to the CPUs: `cpu-thermal` at 82 °C,
    `mem-thermal` at 85 °C
  - the fan trips stay
- **A4. A bring-up temperature guard:** a small systemd service. At 86 °C
  it caps `scaling_max_freq` to the minimum; at 92 °C it does a warm
  `reboot` (not poweroff, which latches the board off until it's
  unplugged).
- **A5. Later:** drop `*_ignore_unused` one at a time; EMC scaling (needs
  the timing tables; stock's `emc-table@1` exists in
  `tegra210-darcy-p2894-emc-a00.dtsi`); `i2c-thermtrip` only with a proven
  MAX77620 command.

**Questions on A:**
1. Is the cap better as a kernel patch (as planned) or a boot-time governor?
   Is anything else needed to keep the DFLL's OPP table at or below the cap
   (the OPPs are built dynamically up to the max)?
2. Is the DFLL node plus pin states complete for mainline? What exactly
   should the dmesg and debugfs (`clk_summary`, `dfll` debugfs) show if it
   works?
3. Thermal: are the trip values and maps right next to the fan's active
   trips? Should `mem-thermal`'s existing EMC maps matter (there's no EMC
   driver)?
4. Is the order A1 → A4 → A2 → A3 right?

## Part B: the GPU test, then the desktop

- **B1. A visible GPU test:** nouveau by hand (rollback timer armed), then
  `glmark2-es2-drm --fullscreen --winsys-options drm-device=/dev/dri/card1`
  (card1 is tegra-drm, card0 nouveau). Last time glmark2 couldn't choose
  between the two cards.
- **B2. nouveau at boot:** drop the modprobe.d block (`install nouveau
  /bin/true`). n-codex found nouveau has no runtime PM on Tegra, so the GPU
  stays powered: at idle nouveau set `vdd-gpu` to 838 mV.
- **B3. Plain Hyprland first** (Arch Linux ARM has hyprland 0.56.2,
  aquamarine 0.15.1, xdg-desktop-portal-hyprland 1.4.1, waybar 0.15.0,
  seatd 0.9.3): a seat (logind or seatd), the KMS device for aquamarine
  (`AQ_DRM_DEVICES=/dev/dri/card1`?), GBM through Mesa's `tegra`
  render-only driver.
- **B4. Then `omarchy-arm`:** `install.sh --dry-run` first. Its platform
  detection knows Apple Silicon, the Pi 5 and VMs (`docs/arm64-port.md:191-236`),
  and its GPU setup is per platform (`install/hardware/arm/vulkan.sh`), so
  Tegra needs an entry (vulkan-nouveau? or none).

**Questions on B:**
5. Is the tegra (KMS) + nouveau (render) split known to work with Hyprland
   and aquamarine on Tegra? What env, permissions, or modifiers trip it up
   (block-linear, explicit modifiers, cursor plane, atomic)?
6. What does `omarchy-arm` need adapting for a Tegra210 board, from its
   code? Point at the files.
7. Anything that could hang or overheat the board in B, and what to watch.

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-plan2-<your name>.md`
(`ncodex` or `antigravity`) and reply with only that path.
