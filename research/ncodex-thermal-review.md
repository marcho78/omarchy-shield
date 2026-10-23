# Thermal/power-management review

## Executive findings

1. **The “passive, no fan” premise conflicts with NVIDIA's exact darcy source.** `tegra210-darcy-p2894-0050-a08-00.dts` includes `tegra210-darcy-p2894-common.dtsi` (`vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-0050-a08-00.dts:20`), and the latter explicitly includes both darcy's PWM-fan and its thermal fan estimator (`.../tegra210-darcy-p2894-common.dtsi:32-35`). The fan is PWM3, period 65,536 ns, with darcy-specific duty tables (`.../foster-platforms/tegra210-darcy-pwm-fan.dtsi:14-38`); its 5 V enable is GPIO E4 (`.../tegra210-darcy-power-tree-p2894-0000-a00.dtsi:218-227`). Mainline P2894 also describes that `vdd-fan` rail (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1789-1798`), but this project deliberately disables it (`kernel/dts/darcy.dts:83-89`) and has no fan consumer. **Whether this particular unit physically populates the fan is UNCERTAIN**, but source-level evidence is strong enough that this is the first thing to establish. If populated, an uncontrolled/stopped fan is probably the dominant reason the enclosure heat-soaked.

2. **The immediate shutdown was most likely a normal thermal-core poweroff at the 102.5/103 °C critical trip, not proof of PMIC self-protection.** The last 93.5 °C sample was two minutes before a compile, making another 9.5 °C plausible. At a critical trip Linux calls `orderly_poweroff(true)` (`vendor/linux/drivers/thermal/thermal_core.c:314-351`; `vendor/linux/kernel/reboot.c:1029-1052`), and PSCI v0.2+ installs `SYSTEM_OFF` as the arm64 poweroff path (`vendor/linux/drivers/firmware/psci/psci.c:332-335,668-685`). That exactly fits “TV dark, LEDs off.”

3. **Do not enable DFLL without first capping speedo 2.** SKU `0x87` selects CPU speedo ID 2 (`vendor/linux/drivers/soc/tegra/fuse/speedo-tegra210.c:68-97`), for which mainline exposes up to **2.2185 GHz** (`vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:175-186`). NVIDIA's darcy cpufreq table stops at **2.0145 GHz** (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-foster-cpufreq.dtsi:19-40`). Merely copying Nano's DFLL node therefore permits a frequency above stock darcy's table.

4. The current tree's new soctherm fix is necessary. Before the fix, `tegra_soctherm_set_hwtrips()` reused the thermtrip/critical temperature for the hardware throttle, ignoring the hot trip. `patches/linux/0002-thermal-drivers-tegra-soctherm-throttle-at-the-hot-trip.patch:7-19,29-39` correctly changes it to `hot_trip->temperature`; keep that patch in the build.

## 1. What probably powered it off

Ranked:

1. **Software critical-trip shutdown through PSCI — most likely.** Base Tegra210 trips are CPU 102.5 °C and GPU/MEM/PLL 103 °C (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:2103-2123,2153-2163,2186-2197,2215-2226`). The thermal core requests an orderly shutdown at critical, and PSCI can physically turn the board off as above.
2. **SOC_THERM thermtrip through PMC state inherited from cboot — plausible but UNCERTAIN.** Soctherm programs autonomous shutdown thresholds (`vendor/linux/drivers/thermal/tegra/soctherm.c:465-499,737-759`). The missing `i2c-thermtrip` node makes the PMC driver return without programming or enabling its emergency I2C reset (`vendor/linux/drivers/soc/tegra/pmc.c:2000-2015,2040-2070`), but it also does **not clear** state cboot may have left enabled. Thus the warning does not prove the hardware path was off.
3. **MAX77620's own die-temperature shutdown — possible, less supported.** Downstream specifies a 110 °C hot-die threshold (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-ers-pmic-e2174-1101-a00.dtsi:69-87`), but **UNCERTAIN:** that property is not proof of the PMIC's autonomous hard-off threshold, nor is PMIC die temperature known.
4. Brownout or another fault is possible but has no positive evidence.

The ordering matters: fan/DVFS are normal cooling, cpufreq and fan maps are controlled mitigation, SOC_THERM pulse skipping is the last active limiter, and critical/PMC shutdown is the final safety net. Do not raise or disable critical trips while diagnosing.

## 2. `cpuidle.off=1`

Removing it is a reasonable, relatively low-risk first power fix. P2894 already enables the common idle state (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1597-1618`). State `0x40000007` is a PSCI context-losing power-down state, with 100/30 us entry/exit latency and 1 ms minimum residency (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:2057-2069`). The PSCI idle driver refuses to expose it unless firmware supplies `CPU_SUSPEND`, validates the parameter, and enters through the generic CPU-suspend path (`vendor/linux/drivers/cpuidle/cpuidle-psci.c:218-246,318-339`; `vendor/linux/drivers/firmware/psci/psci.c:501-526`).

This is not risk-free: bad monitor handling could hang on entry/exit, lose a timer wakeup, or fail CPU/GIC context restoration. Symptoms would be an SSH/ping freeze after an idle interval, RCU/soft-lockup messages, a CPU ceasing to schedule, or a hardware-watchdog reset. A firmware hang need not produce ramoops. The existing watchdog is useful: systemd takes `/dev/watchdog0` at 60 s (`scripts/13-make-rootfs.sh:199-204`), while the kernel DT preserves U-Boot's already-running watchdog until then (`kernel/dts/darcy.dts:491-499`).

Verify all CPUs' `cpu-sleep` `usage` and `time` counters under `/sys/devices/system/cpu/cpu*/cpuidle/`, leave repeated timer/network wakeups running, then allow progressively longer quiet intervals. Note that `cpuidle.off=1` still falls back to architectural WFI (`vendor/linux/kernel/sched/idle.c:108-130`; `vendor/linux/arch/arm64/kernel/idle.c:23-44`), so the gain is leakage/context power-down beyond WFI, not “busy loop versus idle.” Exact saving is **UNCERTAIN**; measure it. At these temperatures it could be material, but no credible watt figure follows from the source.

## 3. DFLL PWM mode

### Electrical description and CVB selection

The Nano node is the right mainline template because every electrical/control value matches NVIDIA's downstream P2530/darcy common node (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:54-72`) and Nano (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts:594-613`). The active/inactive pin states merely un-tristate/tristate PBB1 (`.../tegra210-p3450-0000.dts:117-131`).

For SKU 0x87, speedo ID 2 is selected. CPU process ID is 0 or 1 according to the fused speedo value and the 2119 threshold (`vendor/linux/drivers/soc/tegra/fuse/speedo-tegra210.c:35-38,141-190`). Both speedo-2 CVB variants use the ordinary Tegra210 polynomial with 870–1227 mV limits; only tuning data differs (`vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:515-534`). OPP voltages are computed from the fused speedo, rounded upward to the 708 mV + 19.2 mV PWM grid, then clamped (`vendor/linux/drivers/clk/tegra/cvb.c:13-35,55-79,103-123`).

**Required correction:** cap speedo 2 to the downstream darcy maximum of 2.0145 GHz, and use a lower cap (about the current 1.02 GHz) for the first validation boot. The current driver dynamically creates OPPs from its compiled max table (`clk-tegra124-dfll-fcpu.c:696-707`), so a userspace `scaling_max_freq` written after boot is not as safe as a driver/OPP cap present before the governor starts.

### Handoff

The cpufreq shim requests the current CPU rate from DFLL, reparents CPU to the safe 408 MHz PLLP, enables/locks DFLL, then reparents CPU to DFLL (`vendor/linux/drivers/cpufreq/tegra124-cpufreq.c:31-54`). In PWM mode initialization preloads a forced selector corresponding to the declared 1.0 V tristate voltage (`vendor/linux/drivers/clk/tegra/clk-dfll.c:741-779`). On lock it first selects the active pinctrl state and enables PWM (`clk-dfll.c:571-604,1016-1039`), then closes the loop and removes force. With the declared grid, rounding makes the handoff drive approximately 1.0152 V, not below 1.0 V.

Safety comes from (a) running on PLLP during rail takeover, (b) fuse-derived OPP voltages, (c) CVB min/max clamps, and (d) using board values identical to stock. It is **not electrically fail-safe**: there is no CPU-rail voltage feedback, so wrong polarity, PWM transfer function, or pinmux can undervolt or overvolt. Also, the two `clk_set_parent()` return values in the initial handoff are ignored (`tegra124-cpufreq.c:40-48`), a real robustness defect. A scope or otherwise independent VDD_CPU measurement is the only strong validation; INA3221 VDD_SYS cannot prove rail voltage.

`nvidia,idle-override` and `nvidia,one-shot-calibrate` are downstream-only here: the only occurrences in these source trees are the downstream DTS properties, while mainline Nano omits them. They are not needed by the mainline driver.

## 4. Thermal policy, fan, and PMC emergency shutdown

### Fan first

If the fan is physically present, port it before relying on passive throttling. Mainline's `pwm-fan` binding takes `fan-supply`, `pwms`, `cooling-levels`, and `#cooling-cells` (`vendor/linux/Documentation/devicetree/bindings/hwmon/pwm-fan.yaml:13-24,62-72`). Conveniently, the driver starts at its maximum declared cooling level and enables both PWM and regulator at probe (`vendor/linux/drivers/hwmon/pwm-fan.c:503-536,558-578`). That makes a fan-only first test possible before adding thermal maps. Use darcy's PWM3/polarity/period evidence, not Nano's inverted cooling table. The downstream 16-bit darcy duties must be deliberately normalized to mainline's 0–255 cooling values; do not copy them verbatim.

NVIDIA's downstream “cool” profile begins changing the fan at 50/60/70/80 °C (`.../tegra210-darcy-thermal-fan-est.dtsi:37-50`). Jetson TX1/Nano show the mainline pattern of trips mapped to fixed fan states (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2597.dtsi:1805-1853`; `.../tegra210-p3450-0000.dts:1942-1991`), but their temperatures and PWM polarity are not darcy calibration data.

### CPU cooling and hardware throttle

After DFLL/cpufreq works, CPU0 needs `#cooling-cells = <2>`; cpufreq cooling is only registered when that property exists (`vendor/linux/drivers/thermal/cpufreq_cooling.c:648-668`). An illustrative mainline shape is:

```dts
/* Also include <dt-bindings/thermal/thermal.h>. */
&{/cpus/cpu@0} {
	#cooling-cells = <2>;
};

&{/thermal-zones/cpu-thermal} {
	trips {
		cpu_passive: cpu-passive {
			temperature = <80000>; /* conservative fanless bring-up */
			hysteresis = <2000>;
			type = "passive";
		};
	};
	cooling-maps {
		cpu-dvfs {
			trip = <&cpu_passive>;
			cooling-device = <&{/cpus/cpu@0}
				THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
		};
	};
};
```

The 80 °C value is a conservative bring-up policy, not a characterized darcy target. Once a working fan and DVFS restore stock-like behavior, downstream darcy instead starts CPU balanced throttling at 89 °C, hardware-heavy throttling at 98.5 °C, and shutdown at 102.5 °C (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:231-269`). Keep a distinct hardware-hot tier below critical. The base `throttle_heavy` already implements autonomous CPU pulse skipping and GPU throttling (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:1389-1412`); with the current 0002 fix, its hot trip will finally be programmed rather than the critical temperature. If MEM is to invoke it too, add a MEM-hot cooling map; the base MEM zone has a hot trip but maps only EMC states (`tegra210.dtsi:2133-2176`). GPU and MEM share one hardware thermtrip threshold field, so use the same shutdown threshold for both (`vendor/linux/drivers/thermal/tegra/tegra210-soctherm.c:24-31,66-83,102-118`).

### `i2c-thermtrip`

It is desirable eventually as an independent catastrophic backup, but **do not configure it by guessing a Jetson tuple**. Mainline PMC supports only one raw I2C register/data write (`vendor/linux/drivers/soc/tegra/pmc.c:2017-2068`; binding at `vendor/linux/Documentation/devicetree/bindings/soc/tegra/nvidia,tegra20-pmc.yaml:143-177`). Mainline MAX77620 poweroff performs a read-modify-write of SFT_RST in register 0x41 (`vendor/linux/drivers/mfd/max77620.c:486-494`; bit definition at `vendor/linux/include/linux/mfd/max77620.h:94-95,241-246`). Downstream darcy's boot-ROM poweroff sequence uses **three** writes, ending in register 0x41 data 0xf8 (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:442-459`). Therefore the correct safe single-write payload is **UNCERTAIN**. Verify it against the MAX77620 requirements and the actual PMIC register state before enabling; an incorrect emergency command is itself a power-loss mechanism.

## 5. Recommended order and SSH-only discipline

1. **Stop sustained loads. Establish the fan first.** Confirm the exact unit has a fan (physical evidence or tach), then bring up only PWM3 + `vdd_fan` + `pwm-fan`, initially at full duty. Record temperature slope and VDD_SYS. If no physical fan, mark that conclusively and use the conservative fanless policy.
2. **Install the thermal guardrails before optimization.** Keep the current soctherm hot-trip fix; confirm boot logs now report a throttrip below thermtrip. Add fan maps if applicable. For fanless bring-up, use an approximately 80 °C CPU passive target after cpufreq exists and a separate approximately 90 °C hardware-hot tier; retain critical shutdown near stock until measurements justify anything else.
3. **Remove only `cpuidle.off=1`.** Verify per-state counters, network/timer wakeups, multi-hour idle, watchdog recovery, power, and temperature. Change nothing else in that boot.
4. **Enable DFLL with a kernel-enforced ~1.02 GHz maximum.** Verify parent/rates, every available OPP up to the cap, idle and load stability, then raise in stages. Never expose mainline's 2.2185 GHz speedo-2 maximum; stop at or below downstream's 2.0145 GHz and only after thermal control is working.
5. **Add cpufreq cooling**, then test bounded loads through passive, fan, and hardware-hot thresholds. Confirm temperatures fall or stabilize and that cooling-device state changes.
6. **Remove `clk_ignore_unused`, `pd_ignore_unused`, and `regulator_ignore_unused` one at a time**, with a full peripheral/HDMI/boot test after each. Then address EMC scaling. Configure PMC emergency I2C shutdown only after its raw command is proven.
7. Keep nouveau blacklisted until its runtime power-down is implemented/tested.

For every boot, preserve a known-good FIT and the fastboot recovery route. Arm a userspace timer that requests `reboot bootloader` after a short test window; a kernel hang is covered by the already-proven hardware watchdog. Independently run a 1–2 s temperature guard that requests poweroff at a conservative threshold (for bring-up, about 90 °C), so losing the SSH client does not remove the guard. Log INA power, all four thermal zones, cpufreq policy/current rate, cpuidle counters, and cooling states to persistent storage. Compare power only at similar inlet/case temperatures and with identical HDMI/network/USB state; leakage makes a hot 60-minute sample incomparable to a cold five-minute sample.

## 6. Other idle-power consumers

- **Nouveau definitely does not runtime-suspend this Tegra platform in the current source.** Probe powers GPU, regulator, and clocks up (`vendor/linux/drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:31-76,257-356`), while power-down occurs at destruction (`tegra.c:237-243`) and the platform PM ops contain only system sleep, not runtime PM (`vendor/linux/drivers/gpu/drm/nouveau/nouveau_platform.c:45-57,97-107`). Keeping it unloaded is correct.
- **The three `*_ignore_unused` boot arguments are broad power leaks by design** (`kernel/dts/darcy-system.dts:31`). Remove them individually once all required consumers probe.
- **The SOR power domain is deliberately severed/deleted** (`kernel/dts/darcy.dts:101-145`), although tegra-drm now owns HDMI (`darcy.dts:147-180`). That prevents normal SOR-domain management and should be revisited after the display path is stable. `consoleblank=0` also ensures the display never blanks (`darcy-system.dts:31`). HDMI/DC/SOR power is **UNCERTAIN** until measured with connector on versus off.
- **EMC at 800 MHz is likely significant but unsafe to change without exact tables.** The Tegra210 EMC driver expects bootloader/reserved-memory timing tables and refuses rates lacking a matching entry (`vendor/linux/drivers/memory/tegra/tegra210-emc-core.c:1846-1895`). The downstream A08 table does contain RAM-code 1 data (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-p2894-emc-a00.dtsi:12466`), but conversion/hand-off to mainline's table ABI is real work; never lower EMC by a bare clock write.
- PCIe Ethernet, XUSB, Wi-Fi/SDIO, and HDMI are all enabled consumers. Measure each by controlled disable/runtime-suspend tests after CPU/fan fixes; do not assume any is the dominant 6 W. Current USB host enablement is at `kernel/dts/darcy.dts:285-346`, and PCIe ports at `darcy.dts:470-488`.

Overall: restore the cooling hardware NVIDIA's darcy source says exists, preserve the newly fixed hardware-hot trip, enable C7, then bring up a **frequency-capped** DFLL. That sequence addresses both the likely root cause and the large avoidable idle losses without depending on the final shutdown mechanism.
