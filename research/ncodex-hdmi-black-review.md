# Review: HDMI goes black during MAX77620 bring-up

## Conclusion

The PMIC is now the most likely cause by a substantial margin. The kernel keeps running, simpledrm successfully scans out for several hundred milliseconds, and the loss coincides with MAX77620 children and dependent fixed regulators probing around 1.8 s. Of the two identified DT mismatches, **GPIO1's FPS reassignment is the stronger direct explanation**; the SD2 voltage transition is a credible second mechanism.

The proposed overrides are stock-faithful, narrow, and safe. I would test them together because each manual iteration is expensive. If HDMI still dies, one temporary boot with the whole PMIC node disabled is a useful A/B test, but I would not make that the first or permanent fix.

## 1. Ranked causes

### 1. GPIO1 changes ownership of the live 5 V boost — high confidence

GPIO1 enables `vdd-sys-boost`, which is the upstream 5 V source for HDMI (`arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1707-1729`). Stock assigns GPIO1 `MAX77620_FPS_SRC_NONE` (`recovery/9.1.1/blob-parts/13-DTB.dts:6817-6825`), while mainline assigns FPS0 (`tegra210-p2894.dtsi:1365-1373`). The binding says `SRC_NONE` means the GPIO is controlled by register access, whereas SRC0/1/2 makes it an FPS slave (`Documentation/devicetree/bindings/pinctrl/maxim,max77620-pinctrl.yaml:40-58`).

This setting is actively applied, not merely descriptive:

- The MFD creates the pinctrl child first (`drivers/mfd/max77620.c:68-89`).
- The pinctrl child reuses the PMIC OF node and registers itself (`drivers/pinctrl/pinctrl-max77620.c:551-590`). Pinctrl registration claims its default state (`drivers/pinctrl/core.c:2210-2258`).
- Applying `maxim,active-fps-source` directly updates bits 7:6 of `FPS_GPIO1` with `regmap_update_bits()` (`pinctrl-max77620.c:335-388`). There is no output-state preservation, staging, or glitch check.

When mainline switches GPIO1 from `NONE` to `SRC_0` while EN0/FPS0 is already active, the exact silicon behavior is **UNCERTAIN** without a public MAX77620 programming specification. In particular, source code alone cannot establish whether the pin remains high, goes low until slot 7, or waits for a new EN0 edge. What is certain is that the driver provides no glitch-free handoff guarantee.

The later fixed-regulator probe does not make the FPS transition safe. `vdd-sys-boost` is now `boot-on`, so regulator-fixed requests GPIO1 high (`drivers/regulator/fixed.c:191-192, 291-318`), and the GPIO driver writes the output latch before direction (`drivers/gpio/gpio-max77620.c:185-208`). But GPIO1 is still muxed as `fps-out`; under SRC0, FPS rather than register access owns its effective state. The regulator framework can therefore believe the rail is enabled while the external pin follows the sequencer.

The proposed `MAX77620_FPS_SRC_NONE` override removes the source transition and returns effective control to register access. With `regulator-boot-on` already present on `vdd_sys_boost`, the subsequent request is high rather than low. This combination is internally consistent.

### 2. SD2 is forced from cboot's value to 3.0 V — medium/high confidence as a disturbance, electrical-failure theory UNCERTAIN

DT voltage ranges set `apply_uV` (`drivers/regulator/of_regulator.c:99-111`). During registration, the core reads the current selector and moves it to the nearest bound if it is outside the declared range (`drivers/regulator/core.c:1315-1367`). Thus mainline's fixed `3000000/3000000` constraint really does program SD2 to 3.0 V if cboot left it lower; the MAX77620 driver exposes ordinary regmap voltage-selector operations (`drivers/regulator/max77620-regulator.c:644-657`) and registers SD2 before any LDO (`max77620-regulator.c:726-740, 822-850`).

SD2 feeds LDO0/1 and LDO7/8 (`tegra210-p2894.dtsi:1417-1418`). LDO7 and LDO8 remain independently programmed to 1.05 V and remain FPS1/always-on (`tegra210-p2894.dtsi:1535-1568`). Neither the regulator core nor this driver intentionally disables them when the upstream voltage changes. If the hardware behaves normally, their outputs should remain regulated at 1.05 V, with a line transient and increased dissipation rather than tracking SD2 to 3.0 V.

The stronger claim that 3.0 V violates an N-type LDO input maximum is **UNCERTAIN**. The in-tree driver labels LDO0/1/7/8 as N-type but publishes output-selector ranges up to 2.375 V or 3.95 V (`max77620-regulator.c:726-740`); that is not an input absolute-maximum specification. No authoritative MAX77620 electrical table is present in the tree. Therefore I would not claim proven overvoltage or deterministic shutdown of LDO7/8.

Nevertheless, the 1.35–3.0 V override is well justified: it exactly matches stock darcy (`13-DTB.dts:6941-6956`) and lets the core preserve any cboot voltage already inside the range. NVIDIA's downstream common PMIC description fixes this pre-regulator at 1.35 V (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-ers-pmic-e2174-1101-a00.dtsi:191-198`), as do the other T210 boards cited in the brief. This avoids an unnecessary live upstream transition. Do **not** force 1.35 V until the recovered regulator report confirms cboot's actual value; allowing the stock range is safer.

### 3. Other MAX77620 writes — low probability

The parent MFD rewrites FPS0/1/2 master-source fields during probe (`drivers/mfd/max77620.c:307-458`), but those event sources match stock. The regulator driver also reads current power modes, writes explicitly supplied FPS sources, and applies supplied slot values (`drivers/regulator/max77620-regulator.c:386-439`). With the brief's comparison showing the remaining active settings match, no other HDMI-specific difference stands out.

The `regulator-max77620-gpio7` nonexclusive warning at 1.842 s is expected from GPIO7 being both hogged high and used by an always-on/boot-on fixed regulator (`tegra210-p2894.dtsi:1360-1364, 1660-1672`). It is not GPIO1, CC7, LDO7, or LDO8 and is unlikely to explain HDMI loss.

### 4. Non-PMIC candidates — now low probability

- simpledrm is demonstrably operating at 1.405–1.475 s. Its driver does not own DC, SOR, clocks, regulators, or HPD; it only maps and updates the inherited buffer.
- Native host1x/Tegra DRM is absent, so no display driver retrains or shuts down the link.
- The clock controller, MC, and SMMU initialized before simpledrm became visible. A delayed side effect is **UNCERTAIN**, but the timing is substantially worse than the PMIC match.
- The cpufreq `-2`, `cpuidle.off=1` message, restricted-PMC notice, and IRQ hierarchy trimming do not touch the HDMI path.
- The 12 s `sync_state()` lines are pending dependencies, not a 1.8 s shutdown. Unused-regulator cleanup is explicitly suppressed and occurs much later at 33.8 s.
- `vdd_hdmi` is disabled in `kernel/dts/darcy.dts:88-90`, so Linux does not request Tegra GPIO CC7. The added `boot-on` properties keep the three still-probed fixed rails high (`darcy.dts:46-61`).

## 2. Is the planned fix safe and enough?

Yes, for the two concrete mismatches:

```dts
&max77620_sd2 {
        regulator-min-microvolt = <1350000>;
};

&max77620_default {
        gpio1 {
                maxim,active-fps-source = <MAX77620_FPS_SRC_NONE>;
        };
};
```

The child-node override merges with the existing `gpio1` node, preserving `fps-out`, push-pull, and its slot fields while replacing only the source. The SD2 override inherits the 3.0 V maximum, producing stock's 1.35–3.0 V range. Both changes match the shipping DT and reduce writes rather than introducing new electrical states.

The new `/sys/class/regulator` report is useful. If it reports SD2 at 1.35 V after the fix, that confirms the former DT would have raised it to 3.0 V. It cannot prove which of GPIO1 or SD2 caused the blanking, but a visible boot is the more valuable result.

Two cautions:

1. The GPIO1 source property is applied before the fixed regulator necessarily reasserts its output latch. On a normal cold boot, cboot has already configured the stock `NONE` state and high output, so the override should be a no-op. On an unusual warm entry where the latch is low, changing to NONE could expose that low state; this is **UNCERTAIN**, but it is not the described cboot-to-Linux path.
2. A successful boot supports the combined PMIC hypothesis but does not isolate which override fixed it. Isolating them would require two additional costly boots and has little practical value unless the upstream patch must be minimal.

## 3. Should the PMIC be disabled for one boot?

Use that as the next diagnostic only if the two stock overrides do not restore HDMI. Temporarily setting the PMIC node disabled would prevent the parent FPS writes, GPIO1 reassignment, SD2 voltage programming, and all child probes. For a short, idle, cboot-initialized initramfs run with cpufreq disabled, this is probably electrically conservative.

It is not a good permanent configuration: fixed regulators whose enables use PMIC GPIOs will defer, regulator topology and RTC disappear, and the new regulator report cannot reveal SD2's state. It also tests “no PMIC management at all,” not whether the corrected mainline description works. The narrow stock-value overrides therefore give a better first test.

If HDMI remains black even with the entire PMIC disabled, return to the earlier **UNCERTAIN** SMMU/clock hypotheses and distinguish “black pixels” from “HDMI no signal/HPD loss”; the latter would still point much more strongly to power or PHY supplies.
