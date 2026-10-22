# Review: HDMI goes black about 1.8 s into Linux

Analysis only. The device was not touched and no repo file was edited. The boot log shows Linux still alive after the TV goes black (4 CPUs, eMMC, darcy-init for 60 s), and HDMI works again once cboot and U-Boot run. That is a supply or a PLL/PHY that nobody restarts, not a CPU hang.

`kernel/dts/darcy.dts` already contains the two overrides in the brief (`73–81`). This review is of that change. The black boot is the image whose DTB still had mainline's SD2 floor and GPIO1 FPS source.

## 1. The PMIC is the right window

simpledrm had the console at 1.405–1.475, and the user saw that text. Tegra pinmux, the MC, and the SMMU probe well before that. They did not kill this scanout. The next PMIC evidence is `regulator-max77620-gpio7` at 1.842. The black screen sits on that probe.

Inside the probe, two writes differ from stock. Do both. GPIO1 is the one that can hold the picture off for the rest of the boot. The SD2 step is real and worth removing, and stock's own ceiling says 3.0 V is a legal SD2 voltage, so it is not an N-LDO absolute-max violation.

### What registration actually writes

`of_get_regulation_constraints()` sets `apply_uV` whenever both min and max are non-zero (`drivers/regulator/of_regulator.c:109–111`). It does not care that they are equal.

`machine_constraints_voltage()` then reads the hardware voltage and writes only when that reading is outside `[min, max]` (`drivers/regulator/core.c:1315–1367`). A hit logs `Bringing %duV into %d-%duV` at info level (`1357`). darcy-init's "fail" filter does not keep that line. Search the ramoops you already have for `Bringing` and `vdd-pre-reg` before flashing again.

Mainline SD2 is min = max = 3,000,000 µV (`tegra210-p2894.dtsi:1443–1447`). Stock is 1,350,000–3,000,000 (`13-DTB.dts:6941–6944`, `0x149970` and `0x2dc6c0`). If cboot left the usual 1.35 V, 1.35 V is below mainline's floor, so the core slews SD2 to 3.0 V. The DT ramp is 27,500 µV/µs (`1448`), so 1.35 V to 3.0 V is about 60 µs. If cboot had already left 3.0 V, even mainline would not write. The log line is the proof.

`set_voltage_sel` is `regulator_set_voltage_sel_regmap` (`max77620-regulator.c:651`). It writes the VOUT register directly. FPS sequencing does not gate that write. SD2's FPS source is already FPS1 on both DTs (`p2894.dtsi:1452`, stock `6947`), so the FPS source write is not a change.

### N-type LDOs, and what 3.0 V does to them

The driver tags LDO0, LDO1, LDO7, and LDO8 as N-type (`max77620-regulator.c:732–740`):

| Rail | Type | Output range in the driver | Setpoint | Fed by |
|---|---|---|---|---|
| ldo0 `avdd-sys` | N | 0.80–2.375 V | 1.20 V | SD2 (`1417`) |
| ldo1 `vdd-pex` | N | 0.80–2.375 V | 1.075 V | SD2 |
| ldo7 `vdd-gen-pll-edp` | N | 0.80–3.95 V | 1.05 V | SD2 (`1418`, `1545–1556`) |
| ldo8 `vdd-hdmi-dp` | N | 0.80–3.95 V | 1.05 V | SD2 (`1558–1568`) |

LDO2–LDO6 are P-type and are not on this supply. The N/P flag is not consulted for a MAX77620 voltage decision (it only affects MAX20024 power-ok). The ranges are the useful part.

Stock's SD2 maximum is already 3.0 V, and Jetson names the same rail `VDD_PRE_REG_1V35` at a fixed 1.35 V (`tegra210-p2180.dtsi:217–220`). A board file that allows 3.0 V is not describing an input the N-LDOs must reject. LDO7 and LDO8 can be programmed up to 3.95 V, so their input has to be allowed above 3 V. Treat "3.0 V trips an input overvoltage and LDO8 shuts off" as UNCERTAIN, and the weaker reading.

What is solid: LDO7 and LDO8 are already at 1.05 V (stock uses the same setpoint, `0x100590`). That value is inside `[min, max]`, so the core does not rewrite their VOUT (`core.c:1356`). The input steps under them while they are on and loaded. Dropout is not the problem at 3.0 V. A 60 µs input step can still kick the LDO loop and dip the 1.05 V rail. Nothing in this image re-locks a display PLL or retrains HDMI after that dip: `CONFIG_DRM_TEGRA` and host1x are modules, and `clk_ignore_unused` only keeps gates from being turned off. A PLL that drops out of lock stays down for the rest of the boot. The CPU does not care, because SD0 (`vdd-core`) and SD1 (`vddio-ddr`) are not behind SD2. That matches a black TV and a 60 s userspace.

LDO0 and LDO1 see the same input step. Their output ceiling in the driver is 2.375 V. The machine survived, so `avdd-sys` did not collapse the SoC. They are not the HDMI path.

### GPIO1

Stock GPIO1 is `fps-out`, push-pull, power-up slot 7, power-down slot 0, `maxim,active-fps-source = <0x03>` (`13-DTB.dts:6821–6827`). `0x03` is `MAX77620_FPS_SRC_NONE` (`include/linux/mfd/max77620.h:313–317`). Mainline is the same pinmux except the source is `MAX77620_FPS_SRC_0` (`tegra210-p2894.dtsi:1381–1387`).

GPIO1 enables `vdd-sys-boost` (`p2894.dtsi:1707–1716`), the 5 V boost ahead of HDMI 5 V. Tegra GPIO CC7 (`vdd-hdmi`) is `status = "disabled"` in `darcy.dts`, so Linux leaves cboot's HDMI-5 V switch alone. The boost enable is the remaining switch.

On probe the pinctrl default state runs. `max77620_pinctrl_enable()` sets the alternate-mode bit for `fps-out` (`pinctrl-max77620.c:244–254`, register `AME_GPIO`). `max77620_pinconf_set()` then writes the FPS source with `regmap_update_bits` on `MAX77620_REG_FPS_GPIO1` (`0x54`, `pinctrl-max77620.c:346–384`). NONE to FPS0 is a real bit change. The driver does not read-modify-skip when the value already matches, but a same-value update does not change the pin. This one changes it.

FPS0's event source is EN0 on both DTs (`p2894.dtsi:1351–1354`, stock `6877–6880`). EN0 is asserted while the PMIC is up, so FPS0 has already finished its slots. With source NONE, the pad follows the GPIO output bit (`CNFG_GPIO` bit 3, `max77620.h:218`). With source FPS0, the pad follows the sequencer. Inactive is low. Slot 7 / slot 0 means "last to rise, first to fall."

UNCERTAIN whether assigning the pin to an already-on FPS0 leaves it high immediately, pulses it low for one slot, or leaves it low until the next off-to-on edge. The driver just writes the field. A pulse that returns high can still leave the TV black, because nothing re-trains the link. A pin that stays low keeps the boost off for the whole boot, which also matches, and cboot restores it on the way back. Either way this write is the one to stop.

The MFD FPS init rewrites a config register only for properties that exist (`max77620.c:346–391`). Mainline fps0 sets the event source and not a period, and that source is already EN0, so this is not a second sequencer reset. fps1's `device-state-on-disabled-event` is recorded in software there (`378–387`) and is not an immediate rail write. GPIO1 is on FPS0, not FPS1.

`regulator-fixed` for `vdd-sys-boost` can request PMIC GPIO1 and drive it. In `fps-out` mode the GPIO data bit does not own the pad, so that "drive high" does not repair an FPS-held pin. `darcy.dts` adding `regulator-boot-on` (`55–57`) matters only after the source is NONE and the data bit is in control. The 1.842 line is GPIO7 (the hog plus `regulator-max77620-gpio7`), which is a different pin and is already high.

## 2. The GPIO1 change, short form

A GPIO in `fps-out` with source NONE is a normal GPIO output. Changing the source to FPS0 while EN0 is already high hands the pad to the sequencer. The inactive level is low, and the power-down slot is 0. The driver writes that with no "already in this state" guard (`pinctrl-max77620.c:384`). It can glitch low. Whether it stays low is UNCERTAIN and is not answered by the driver. Stock never makes this change.

## 3. The other lines in that window

None of these blank HDMI on this boot:

- `cpufreq-tegra124` at 1.713, error `-2` (`-ENOENT`). The probe failed and did not move a voltage. The DFLL node is disabled. Not a brownout.
- `failed to register cpuidle driver` at 1.723 is `cpuidle.off=1`. The idle driver is absent. The CPU then ran for 60 s.
- `IRQ74: trimming hierarchy from :pmc@7000e400` at 1.871 is irq-parent cleanup on a PMC wake, not a display-controller reset.
- `sync_state() pending` at 12 s for actmon / host1x / mipi means the MC and PMC did **not** power those off. host1x is a module, so the consumer never arrives. Pending is the safe outcome.
- `Not disabling unused regulators` at 33.81 is `regulator_ignore_unused`. The 30 s cleanup did not run. The TV was already black.
- `vdd-hdmi` is disabled, so the CC7 fixed regulator never probes and cannot drive HDMI 5 V off.
- Clock and power-domain ignore flags were already on. No unused-clock line is in the recovered lines. The text on screen at 1.45 s is the evidence those flags held the inherited scanout until the PMIC probe.

## 4. The planned fix

Safe, and it is the right next image. Do not disable the PMIC node instead.

```dts
&max77620_sd2 { regulator-min-microvolt = <1350000>; };
&max77620_default { gpio1 { maxim,active-fps-source = <MAX77620_FPS_SRC_NONE>; }; };
```

SD2's max stays 3,000,000 from the dtsi, so the constraint becomes stock's 1.35–3.0 V range. `apply_uV` stays true, and the core writes nothing if cboot's voltage is inside that range (`core.c:1346–1356`). It does not force 1.35 V. Forcing min = max = 1,350,000, as p2180 does, would slew downward if cboot had left something higher. Leave the range alone for this boot.

GPIO1 source NONE is stock's `0x03`. If cboot already programmed NONE, the `update_bits` writes the same value. The pad stays on the GPIO output bit, and `vdd-sys-boost`'s `regulator-boot-on` can then drive it high. That is the order you want: pinctrl default state runs as a child of the MFD, then the fixed regulator.

Leave the PMIC enabled. This boot already proved the rest of the probe (SD0, SD1, SD3, the FPS sources that match stock) does not reset the CPU. Disabling `pmic@3c` would also avoid both writes, and it would hide which one mattered. Use that only if the corrected image is still black.

On that fallback image, set `pmic@3c` to `status = "disabled"` so cboot's PMIC image is untouched. Keep `vdd-hdmi` disabled and the ignore flags.

The regulator print in darcy-init is the right check. Read three lines:

- `vdd-pre-reg`: microvolts. 1,350,000 or anything under 3,000,000 means the floor fix held. 3,000,000 means cboot itself left the top of the range and SD2 was not a forced step.
- `vdd-hdmi-dp` and `vdd-gen-pll-edp`: still 1,050,000 and enabled.
- `vdd-sys-boost`: enabled. If the picture is back and the boost is enabled, GPIO1 is no longer holding it down.

Also grep the current ramoops for `Bringing`. If `vdd-pre-reg` was brought up to 3,000,000, the SD2 write on the black boot is confirmed.
