# DFLL follow-up review

## Bottom line

The frequency interpretation is substantially right. `0x53` is 83 DVCO cycles in four 51 MHz reference-clock cycles, hence **1058.25 MHz before the scaler**. With `scale_bits = 198`, the hardware factor is `(198 + 1) / 256`, giving **822.62 MHz**, which explains the 714 MHz experiment almost exactly. This is strong evidence that mainline's computed 918 MHz DVCO floor is too low for this chip.

Two qualifications matter:

1. **The live output being index 9 is very likely, but not proved by these registers.** `OUTPUT_CFG` gives limits, `INTR_STS` is historical, and `OUTPUT_FORCE = 0x10` is not the live output.
2. **“Only a power cost, not a timing risk” is too categorical.** The architecture and downstream driver's treatment make catastrophic risk look unlikely, and the load test is useful empirical evidence, but the cited low-tuning comment is not an OPP timing guarantee.

A3's DTS design is sound. The proposed emulation test needs one correction: a fixed emulated temperature takes `step_wise` from cooling state 0 to 1, then remains stable; it does not climb to maximum by itself.

## 1. DFLL reading and the 2.0145 GHz cap

### (a) Monitor decoding and the floor hypothesis

Mainline programs monitor source 6 (`FREQ`) during initialization (`vendor/linux/drivers/clk/tegra/clk-dfll.c:1396-1414`). The counter integrates over four reference cycles, with the supported reference fixed at 51 MHz (`clk-dfll.c:190-203`). The debugfs conversion is:

```text
pre_scaler = monitor_value * 51 MHz / 4
post_scaler = pre_scaler * (scale_bits + 1) / 256
```

That is exactly what `dfll_read_monitor_rate()` implements (`clk-dfll.c:1228-1271`):

- `MONITOR_DATA = 0x00010053`: `NEW=1`, value `0x53=83`; `83 * 12.75 = 1058.25 MHz`.
- At scale 255, post-scaler is also 1058.25 MHz.
- At scale 198, `1058.25 * 199/256 = 822.62 MHz`.

Thus this is not a pre-/post-scaler misunderstanding. The 714 MHz result independently corroborates an approximately 1058 MHz DVCO floor and the scaler error caused by deriving `dvco_rate_min=918 MHz` from OPP voltage (`clk-dfll.c:504-526,833-865`). Stock's one-shot calibration is aimed at precisely this class of error: NVIDIA's downstream driver forces a floor voltage, averages monitor samples, and replaces the estimated floor (`drivers/clk/tegra/clk-dfll.c:1445-1609` in [LineageOS's downstream 4.9 tree](https://github.com/LineageOS/android_kernel_nvidia_kernel/blob/lineage-22.2_4.9/drivers/clk/tegra/clk-dfll.c#L1445-L1609)).

There is nevertheless a measurement caveat. Mainline reads `MONITOR_DATA` once and does not synchronize on `NEW`; downstream explicitly warns that concurrent update can yield an intermediate value, waits for `NEW`, and compares consecutive samples within two counts ([downstream `clk-dfll.c:1182-1217`](https://github.com/LineageOS/android_kernel_nvidia_kernel/blob/lineage-22.2_4.9/drivers/clk/tegra/clk-dfll.c#L1182-L1217)). One count is 12.75 MHz, and 1135 MHz is exactly 89 counts (1134.75 MHz). Therefore:

- A repeatedly stable count of 83 at a fixed request is strong evidence for a 1058 MHz floor.
- The 83-to-89 spread is an instantaneous, very short-window observation; it does **not** prove a sustained 1135 MHz CPU clock. It could be real loop variation or an unsynchronized sample. **UNCERTAIN:** the existing data cannot distinguish those.

Index 9 is the control-theory-consistent result: a target below the minimum achievable DVCO rate should drive voltage to the configured minimum. But neither `OUTPUT_CFG` nor sticky `INTR_STS` proves the current index. Also, `OUTPUT_FORCE=0x10` has enable bit 6 clear, so 16 is only the retained forced value. Mainline initializes a forced PWM voltage and disables forcing after entering closed loop (`clk-dfll.c:759-775,1016-1039`). It is not a live-output register. **UNCERTAIN:** the live output may sit at 9 or dither above it.

The safety claim should be softened. `dfll_tune_low()` says the oscillator and CPU clock-shaper tuning is valid, though non-optimal, at any voltage (`clk-dfll.c:443-459`); the open-loop transition repeats that requirement (`clk-dfll.c:982-1005`). That supports the DFLL design, but it does not explicitly guarantee CPU logic timing for every observed frequency/voltage pair. NVIDIA's downstream comments acknowledge that a misestimated minimum makes low requested frequencies run high at Vmin ([downstream `clk-dfll.c:1385-1403`](https://github.com/LineageOS/android_kernel_nvidia_kernel/blob/lineage-22.2_4.9/drivers/clk/tegra/clk-dfll.c#L1385-L1403)), so this is a known operating case. Still, the defensible conclusion is: **primarily a frequency-accounting/power defect, with timing safety plausible but not proved**. The successful four-core load at 880.8 mV/approximately 1058 MHz establishes useful device-specific margin, not a general guarantee.

### (b) Read-only live PWM output

There is no known read-only software path in this mainline driver. The register dump is genuinely read-only (`clk-dfll.c:1324-1377`), but while monitor source 6 is selected it exposes frequency, not output index. `OUTPUT_FORCE` is stale whenever forcing is disabled, and `INTR_STS` only says a limit has been hit sometime since clearing.

The hardware does have monitor source 5 (`OUTPUT_VALUE`). NVIDIA's downstream driver switches `MONITOR_CTRL` to 5, waits for consistent data, reads the output, then later restores frequency mode ([downstream `clk-dfll.c:455-458,3259-3283`](https://github.com/LineageOS/android_kernel_nvidia_kernel/blob/lineage-22.2_4.9/drivers/clk/tegra/clk-dfll.c#L3259-L3283)). That confirms a possible implementation, but it is a register write and should be ported with locking, `NEW` synchronization, validation, and restoration—not performed blind with `devmem`. A non-invasive oscilloscope/logic-analyzer duty-cycle measurement on PBB1 or the CPU rail is the only strictly read-only alternative I know; pad accessibility is **UNCERTAIN**.

### (c) Before lifting the cap

Do A3 and verify it first. Then lift the hard build-time ceiling in stages—preferably 1.9125 GHz, then 2.0145 GHz—rather than exposing the final OPP before the thermal path has been exercised. Keep the final speedo-2 cap at 2.0145 GHz; do not restore upstream's 2.2185 GHz value (`patches/linux/0003-clk-tegra-dfll-hold-cpu-speedo-2-for-the-shield-tv.patch:20-28`).

The PWM limit will not remain 11. `dfll_build_lut()` derives `v_max` from the highest installed OPP, and the PWM LUT includes steps through that voltage (`clk-dfll.c:1637-1684,1765-1782`). With a 2.0145 GHz highest OPP at 1226 mV, the expected limits are approximately min 9, max 27, safe 10: index 27 is 1226.4 mV before millivolt truncation.

Do not assume the live output must saturate at 27. The CVB table deliberately assigns both 2.0145 and 2.2185 GHz the 1227 mV ceiling (`vendor/linux/drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:193-217`), and voltage is rounded and clamped when OPPs are built (`vendor/linux/drivers/clk/tegra/cvb.c:55-79`). At 2.0145 GHz the request is exactly 79 × 25.5 MHz. The loop may settle below max on a fast sample, or hit max and deliver less than requested on a slow one. Monitor rate under sustained load is the useful observation; sticky `MAX` alone is not.

At each stage, check sustained all-core load, rapid load/idle transitions, monitor count consistency, temperature, wall power, kernel errors/pstore, and warm reboot. One-shot calibration is desirable for low-rate accuracy, but not a prerequisite for testing high-rate closed-loop regulation.

### (d) Downstream features missing from mainline

- **One-shot floor calibration:** real and relevant to the current low-rate error. Stock enables it at `vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:54-71`; mainline has no implementation/property. It is a quality/power fix, not specifically a high-rate prerequisite.
- **High-voltage tuning:** not relevant for this speedo/process bin. Speedo 2/process 0 omits `tune0_high` and the threshold (`clk-tegra124-dfll-fcpu.c:519-527`). Downstream has the same omission, and its tuning initializer disables the high range when the zero threshold is below the 870 mV minimum ([downstream `clk-dfll.c:2766-2797`](https://github.com/LineageOS/android_kernel_nvidia_kernel/blob/lineage-22.2_4.9/drivers/clk/tegra/clk-dfll.c#L2766-L2797)). Mainline remaining on low tuning is therefore intentional for this bin.
- **Temperature-dependent DFLL voltage floors/caps:** downstream is richer. Its Tegra210 data includes a cold floor and generic voltage caps; Darcy maps a DFLL floor at 15 °C to state 1 (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-dvfs-p2894-0050-a08.dtsi:56-76`). I found no Darcy cooling-map reference to `dfll_cap` in the checked-in downstream DTS, only the cdev declaration (`tegra210-darcy-p2894-common.dtsi:665-677`). The absent cold floor may matter in a genuinely cold environment; at the measured 45–46 °C it does not. A3 plus the 86 °C guard and 98.5 °C hardware throttle provide the important hot-side frequency protection.
- **Idle override:** stock also requests `nvidia,idle-override` (`tegra210-p2530-common.dtsi:54-71`). Mainline lacks that downstream CC4/HVC path. Since core C7 plus DFLL already survived load/idle cycles and mainline has no cluster idle state (`NOTES.md:1470-1507`), it is not presently shown to be required. Retesting rapid high-rate-to-idle transitions is prudent. **UNCERTAIN:** source inspection alone cannot prove it irrelevant at the final cap.

## 2. A3 DTS and emulation test

### DTS review

The proposed structure is correct:

- The thermal constants header is included (`kernel/dts/darcy.dts:10-11`).
- CPU0 is the right OF cooling-device node for the single shared CPU0–3 policy; cpufreq cooling registers against the policy CPU's node when it has `#cooling-cells` (`vendor/linux/drivers/thermal/cpufreq_cooling.c:630-672`).
- Two cells and `THERMAL_NO_LIMIT` for both bounds are correct (`vendor/linux/include/dt-bindings/thermal/thermal.h:9-15`).
- The 82 °C/2 °C and 85 °C/2 °C passive trips and maps are internally consistent (`kernel/dts/darcy.dts:334-372`). The deepest request wins when both thermal zones target the same cdev (`vendor/linux/drivers/thermal/thermal_helpers.c:166-179`).
- `CPU_FREQ_THERMAL` defaults on under the enabled `CPU_THERMAL`, and step-wise is the default governor (`vendor/linux/drivers/thermal/Kconfig:95-107,177-196`).

The 1 Hz memory polling is functionally safe but not literally free. Crossing any passive trip increments `tz->passive`, irrespective of whether its cooling device bound (`vendor/linux/drivers/thermal/thermal_core.c:410-434`), and a positive passive delay then schedules polling (`thermal_core.c:289-295`). Therefore the existing 50 °C `dram_nominal` trip (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:2133-2176`) will cause one temperature read/wakeup per second whenever memory is above roughly 50 °C. At the measured 45 °C idle it does nothing; above 50 °C the overhead should be negligible and is a reasonable safety tradeoff.

### Correct emulation expectations

Writing 84000 to CPU or 85500 to memory should bind the cpufreq cdev, move it from state 0 to **state 1**, and reduce `scaling_max_freq` by one OPP. At the current nine-OPP/1.020 GHz cap that should be 1020 → 918 MHz. It should **not continue climbing while the emulated value is constant**: the governor increments only while the trend is `RAISING`; equal current and previous temperatures are `STABLE`, which preserves the target (`vendor/linux/drivers/thermal/thermal_helpers.c:25-39`; `gov_step_wise.c:32-76`). Clearing emulation to 0 produces a dropping trend and removes the target once below hysteresis.

A safe discriminating test is:

1. Identify zones and cdev by their `type`, not thermal-zone numbering; record cdev `cur_state/max_state`, policy max, and real temperatures.
2. Test CPU at 84000, verify state 1 and the one-OPP cap, then clear it to 0 and verify state 0/restored max.
3. Separately test memory at 85500, verify the same, then clear it. Do not leave both zones emulated.
4. Only if full depth is worth testing, raise emulation monotonically in several small steps while remaining below 86000. Each rising write causes another state increment. At the current cap, eight rising updates above the trip can reach max state 8; query `max_state` rather than assuming it. Use cleanup that writes 0 even if the test exits early.

Emulation is safe with an important nuance. Soctherm provides no `set_emul_temp` callback (`vendor/linux/drivers/thermal/tegra/soctherm.c:686-690`), so the thermal core substitutes the emulated value only after reading the physical sensor, and refuses to hide a real critical condition (`thermal_helpers.c:82-109`). Writing emulation also performs an immediate zone update (`thermal_sysfs.c:225-250`).

It **does** call `set_trips`, so it reprograms soctherm's level-0 software interrupt window (`thermal_core.c:551-598`; `soctherm.c:661-683`). It does **not** rewrite the independent heavy-throttle or thermtrip thresholds: those are programmed from hot/critical trips at probe/resume or by `set_trip_temp`, not by `set_trips` (`soctherm.c:592-634,713-790,2190-2223`). Thus the 98.5 °C hardware throttle and critical thermtrip remain physical-sensor protections.

**UNCERTAIN:** because the physical temperature is far below the emulated low boundary, reprogramming the level-0 window may generate a down interrupt; the driver/core caching should prevent a storm, but it may leave that software threshold source masked until clearing emulation causes a new window to be installed (`thermal_trip.c:54-80`; `soctherm.c:800-898`). This does not disable hardware heavy throttle or thermtrip. Keep the test brief, remain below the 86 °C userspace threshold, clear emulation immediately afterward, and confirm normal physical temperatures and interrupts afterward.

## Recommendation

Accept A3 as written, but document that a single fixed emulated temperature validates only state 1. Then stage the cap through 1.9125 GHz and 2.0145 GHz. Track one-shot floor calibration as a later correctness/power improvement, and revise `NOTES.md`'s absolute “not a timing risk” wording to the qualified conclusion above.
