# Follow-up: the DFLL runs on darcy; one reading to check, and A3

**Analysis only.** Do not change files or touch the device. Repository
`~/projects/nvidia`, kernel `vendor/linux` (7.2.11 plus
`patches/linux/0001-0003`). Your plan review
(`research/ncodex-plan2-review.md`) was followed: A1, then A4, then A2 at
the low cap. Commits 7a322c8, 9736e5b, 5fc27a7. `NOTES.md`'s section "CPU
power management (2026-10-23)" has the measurements. Cite `file:line`, and
say plainly what is a guess.

## What runs now (measured)

- `cpufreq-dt`, one policy for CPUs 0–3, schedutil, rates 204–1020 MHz.
  `cclk_g` comes from `dfllCPU_out`. The DFLL debugfs reads enabled 1,
  locked 1. `dvfs_pwm_pbb1` is no longer tristated.
- Chip: speedo revision 4, CPU speedo value 2041 (`FUSE_CPU_SPEEDO_0` =
  `0x7f9`), CPU process 0, speedo ID 2. The table is
  `clk-tegra124-dfll-fcpu.c:515-524`: 870–1227 mV,
  `tune0_low = 0xffead0ff`, `tune1 = 0x20091d9`, no `tune0_high`.
- My OPPs from `cvb.c`'s arithmetic (708 mV + n × 19.2 mV):
  - 204–918 MHz: 880 mV (the floor)
  - 1020 MHz: 919 mV
  - 1912.5–2218.5 MHz: 1226 mV (the ceiling)
- **The DFLL's monitor (`tegra_dfll_fcpu/rate`):**
  - **1020 MHz requested:** 1058–1135 MHz measured, the same at idle and under 4-core load.
  - **714 MHz requested:** 822 MHz after the scaler. With `scale_bits` 198, that means a DVCO at about 1058 MHz.
- **Registers:**
  - `DFLL_FREQ_REQ` = `0x1040ffa8`: mult 40, scale 0xff, force value 64, force enable.
  - `DFLL_OUTPUT_CFG` = `0x0a0b0944`: min 9, max 11, safe 10, PWM enabled, div 4.
  - `DFLL_OUTPUT_FORCE` = `0x10`.
  - `DFLL_MONITOR_DATA` = `0x00010053`.
  - `DFLL_INTR_STS` = 3, both MIN and MAX. They are sticky since `dfll_init_out_if()` cleared them.
- **Power and heat:**
  - **4-core load:** 6.2–7.0 W, 45–46 °C.
  - **Idle:** 4.5–4.8 W. With pll_x at 1.0 V it was about 5.1 W.

## Question 1: is this reading right, and does it matter?

My reading:
- The output sits at index 9 (880.8 mV).
- There, this chip's DVCO runs at about 1058 MHz, above the `dvco_rate_min`
  the driver derives from the OPPs (918 MHz, `get_dvco_rate_below()`,
  `clk-dfll.c:504-526`).
- So requests below about 1058 MHz come out up to 15% fast. The scaler is
  computed against 918 MHz (`clk-dfll.c:833-852`).
- The driver itself says the minimum rate "should be calibrated at runtime"
  (`:833-838`). Stock darcy sets `nvidia,one-shot-calibrate`.

My claim of safety:
- The CPU clock is the DVCO, on the CPU rail.
- The low-voltage tuning "must be characterized to keep the downstream
  device stable at any DVCO input voltage" (`:987-991`).
- So running fast at the floor is a power cost, not a timing risk.

Please check:
- (a) Is that right, or is there another explanation for the measured
  rate: the monitor mode, what `DFLL_MONITOR_DATA` counts, pre- or
  post-scaler, `REF_CLK_CYC_PER_DVCO_SAMPLE`?
- (b) Is there a safe, read-only way to see the live output index in PWM
  mode on mainline? I don't want to change `DFLL_MONITOR_CTRL` blind.
- (c) Is anything needed before raising the cap to 2014.5 MHz? At the top,
  the request is above what 1226 mV gives, so I expect the output at max
  and the DVCO at whatever it reaches there.
- (d) Is mainline missing anything for Tegra210 at high rates that stock
  has, for example the high-voltage tuning (`tune0_high`) or thermal floors
  and caps? Does it matter for speedo 2, whose table has no `tune0_high`?

## Question 2: A3 as I'd write it (your CPU0-only advice)

`darcy.dts` gets `#include <dt-bindings/thermal/thermal.h>` and:

```dts
&{/cpus/cpu@0} {
	#cooling-cells = <2>;
};

&{/thermal-zones/cpu-thermal} {
	trips {
		cpu_passive: cpu-passive {
			temperature = <82000>;
			hysteresis = <2000>;
			type = "passive";
		};
	};

	cooling-maps {
		cpu-passive {
			trip = <&cpu_passive>;
			cooling-device = <&{/cpus/cpu@0} THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
		};
	};
};

&{/thermal-zones/mem-thermal} {
	polling-delay-passive = <1000>;

	trips {
		mem_passive: mem-passive-cpu {
			temperature = <85000>;
			hysteresis = <2000>;
			type = "passive";
		};
	};

	cooling-maps {
		mem-passive-cpu {
			trip = <&mem_passive>;
			cooling-device = <&{/cpus/cpu@0} THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
		};
	};
};
```

Notes:
- `mem-thermal` already has a passive trip at 50 °C (`dram_nominal`,
  mapped to `&emc`, dormant without the EMC driver). With passive polling
  on, it will poll every second above 50 °C. Is that harmless?
- The test, without heating the board: `CONFIG_THERMAL_EMULATION=y`, so
  `emul_temp` at 84000 on cpu-thermal, and 85500 on mem-thermal. Expect
  the cpufreq cooling state to climb and `scaling_max_freq` to fall. Then
  `emul_temp` 0.
- The thermal guard reads each zone's `temp`, which returns the emulated
  value: at 86 °C it caps, at 92 °C it reboots. So the test stays below
  86 °C.
- Is emulation safe here? It does not touch the soctherm hardware
  throttle (98.5 °C). Could anything in the soctherm driver react to an
  emulated temperature, through `set_trips` or interrupts?

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-dfll-followup-ncodex.md`
and reply with only that path.
