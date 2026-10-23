# Review: first tegra-drm HDMI handoff on Darcy

## Verdict

I found no missing DT dependency that blocks a first manual `modprobe tegra_drm`. The no-`pd_sor` design is internally consistent for this boot chain: SOR1 and DPAUX1 use their clocks and resets directly when they have no genpd, while the two display controllers continue to use the separate legacy DIS/DISB powergates. The proposed DDC, HPD, supplies, and clock resources match what this driver actually consumes.

I would make two safety preparations before the test:

1. Arm an independent, delayed reboot-to-bootloader job before `modprobe`; the SOR HDMI enable path contains two waits with no timeout, and a single sleeping `modprobe` task need not stop systemd from feeding the hardware watchdog (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2322-2340`, `scripts/13-make-rootfs.sh:197-202`).
2. Strongly consider temporarily adding `regulator-always-on` to `vdd_hdmi` for bring-up. `regulator-boot-on` prevents a low transition at fixed-regulator probe, but it does not prevent SOR's cleanup or suspend paths from disabling the last consumer and driving CC7 low (`vendor/linux/drivers/regulator/fixed.c:191-192`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:2972-2988`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:4035-4041`). This is not a brick risk; it is a way for a failed probe to remove HDMI 5 V and obscure the original failure.

## Ranked findings

### Medium: the watchdog does not guarantee recovery from the SOR's unbounded waits

`tegra_sor_hdmi_enable()` polls `SOR_LANE_SEQ_CTL_STATE_BUSY` and then `SOR_LANE_SEQ_CTL_TRIGGER` in two `while (true)` loops with sleeps and no deadline (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2322-2340`). If hardware never clears either bit, the task doing the initial fbdev modeset can remain stuck while other tasks, including systemd, continue to run. In that state systemd can continue servicing `/dev/watchdog0`, so the 60-second runtime watchdog is not an independent deadline. The tested watchdog proves recovery from a system-wide freeze, not from one blocked driver thread (`NOTES.md:714-727`, `NOTES.md:969-971`).

Before loading the module, I recommend something equivalent to:

```sh
sudo systemd-run --unit=darcy-hdmi-rollback --on-active=2min \
  /usr/bin/systemctl --reboot-argument=bootloader reboot
sudo modprobe tegra_drm
```

After SSH, DRM state, and the picture are known good:

```sh
sudo systemctl stop darcy-hdmi-rollback.timer
```

Keep a second SSH session open. If the timer's normal reboot itself blocks, ceasing watchdog service should still ultimately reset the board; that last interaction is **UNCERTAIN** because it depends on where a hypothetical driver hang occurs.

### Medium: `vdd_hdmi` can be switched off after a partial SOR probe

The fixed regulator is `regulator-boot-on`, not `regulator-always-on` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1719-1729`). At provider probe, `boot-on` requests the GPIO high (`vendor/linux/drivers/regulator/fixed.c:191-192`, `vendor/linux/drivers/regulator/fixed.c:291-320`), and the Tegra GPIO driver writes the output value before enabling output direction, so the software sequence does not intentionally pulse CC7 low (`vendor/linux/drivers/gpio/gpio-tegra.c:182-192`). An electrical transient below the GPIO block's observable level is **UNCERTAIN**.

The SOR enables all three HDMI rails during probe and installs a devm action that disables each on cleanup (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2972-3027`). The regulator core permits the last consumer to turn off a rail unless its constraint is `always_on` (`vendor/linux/drivers/regulator/core.c:3255-3295`). Thus a failure after `hdmi-supply` was enabled can lower CC7. `regulator_ignore_unused` only suppresses late unused-regulator cleanup; it does not override an explicit consumer disable (`vendor/linux/drivers/regulator/core.c:6850-6875`). A temporary `regulator-always-on` is useful diagnostic containment.

### Low / UNCERTAIN: secure-PMC write failures are incompletely reported

On a TZ-only PMC, reads and writes use SMC, but the write wrapper returns `void`; an SMC error produces only a warning (`vendor/linux/drivers/soc/tegra/pmc.c:530-570`). Powergate transitions subsequently poll state and return a timeout (`vendor/linux/drivers/soc/tegra/pmc.c:655-682`), but clamp removal writes through the same wrapper and unconditionally returns success (`vendor/linux/drivers/soc/tegra/pmc.c:713-747`). Therefore successful XUSB powergating is strong evidence that the generic mechanism works, but it does not prove that the secure monitor accepts the DIS, DISB, and HDMI-DPD offsets. Those offset permissions are **UNCERTAIN** until tested.

### Low: the command-line mode can hide a DDC failure

The mode pin is useful for the first handoff, but if EDID yields no matching 1920x1080 mode the helper synthesizes a user mode (`vendor/linux/drivers/gpu/drm/drm_probe_helper.c:146-178`). With the exact string in this patch and no `M` or named mode, that fallback is GTF, not necessarily the TV's CEA-861 1080p timing (`vendor/linux/drivers/gpu/drm/drm_modes.c:2539-2570`). A returned picture therefore does not by itself prove DDC. Check `edid` and `modes` as planned.

## Answers to the nine questions

### 1. No SOR power domain

Yes, this can bring HDMI up provided cboot has left the shared SOR partition powered, as the live measurements show.

- With no `pm_domain`, DPAUX1 explicitly acquires its own reset, clock, and parent clock; its runtime callbacks deassert/assert that reset and enable/disable those clocks (`vendor/linux/drivers/gpu/drm/tegra/dpaux.c:471-500`, `vendor/linux/drivers/gpu/drm/tegra/dpaux.c:598-655`).
- SOR1 similarly acquires an exclusive released reset when no genpd owns it, obtains all module/output/parent/safe/DP clocks, and registers as a host1x client (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3843-3914`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:3984-3991`). Its host1x suspend/resume path uses only reset, clocks, and runtime PM (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3231-3297`).
- The SOR and DPAUX bindings do not require `power-domains` (`vendor/linux/Documentation/devicetree/bindings/display/tegra/nvidia,tegra124-dpaux.yaml:101-115`, `vendor/linux/Documentation/devicetree/bindings/display/tegra/nvidia,tegra124-sor.yaml:156-165`).
- A search of these display drivers finds legacy PMC powergate calls only in `dc.c`; neither `sor.c` nor `dpaux.c` powers the SOR partition through the legacy API (`vendor/linux/drivers/gpu/drm/tegra/dc.c:2869-2930`).

The cost is that Linux has no recovery path if firmware ever hands it the SOR partition powered off. That is not the measured state, but behavior after a future suspend or different firmware boot is **UNCERTAIN** and outside this first test.

Expect the cboot picture to disappear early even before a successful modeset: SOR probe switches `sor1_out` to the safe parent (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3935-3944`), SOR client initialization deliberately resets the block because firmware handoff is not implemented (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3140-3185`), and DRM removes the conflicting firmware framebuffer before registering its fbdev client (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1250-1275`).

### 2. DC legacy powergates through the TZ-only PMC

The intended path is correct. Tegra210 sets `has_powergate = true`; DC probe selects DIS for head 0 and DISB for head 1, powers it off, and runtime resume calls `tegra_pmc_powergate_sequence_power_up()` (`vendor/linux/drivers/gpu/drm/tegra/dc.c:3034-3055`, `vendor/linux/drivers/gpu/drm/tegra/dc.c:3333-3345`, `vendor/linux/drivers/gpu/drm/tegra/dc.c:2890-2930`). Deleting only `pd_sor` does not reserve DIS/DISB: the PMC initially marks every valid partition available, and only a DT genpd node clears its corresponding legacy-API bit (`vendor/linux/drivers/soc/tegra/pmc.c:2961-2967`, `vendor/linux/drivers/soc/tegra/pmc.c:1316-1345`). The Tegra210 DT has a SOR genpd but no DIS/DISB genpd nodes (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:921-1000`).

All powergate state, toggle, and clamp accesses in that sequence pass through `tegra_pmc_readl()`/`tegra_pmc_writel()`, which select SMC when `tz_only` is true (`vendor/linux/drivers/soc/tegra/pmc.c:530-570`, `vendor/linux/drivers/soc/tegra/pmc.c:590-710`, `vendor/linux/drivers/soc/tegra/pmc.c:829-892`). Tegra210 is marked `maybe_tz_only` and uses the bounded Tegra114 powergate implementation (`vendor/linux/drivers/soc/tegra/pmc.c:3864-3885`).

The HDMI I/O-pad DPD path also uses the PMC wrappers and a bounded 250-microsecond status poll (`vendor/linux/drivers/soc/tegra/pmc.c:1680-1715`); Tegra210 maps HDMI to bit 28 at request/status offsets `0x1b8/0x1bc` (`vendor/linux/drivers/soc/tegra/pmc.c:3754-3793`). SOR logs an I/O-pad-enable failure but continues programming the link (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2283-2287`). Since cboot has the pad working already, an SMC refusal may still leave it usable, but this is **UNCERTAIN**.

### 3. I2C4 and the modular DPAUX1 pin controller

The expected boot sequence is safe:

1. I2C4 names `state_dpaux1_i2c` as its default pinctrl state (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:750-765`). Device core binds default pinctrl before calling the I2C driver's probe and propagates `-EPROBE_DEFER` (`vendor/linux/drivers/base/pinctrl.c:20-64`, `vendor/linux/drivers/base/pinctrl.c:98-106`). With modules enabled, an unavailable DT pinctrl provider continues to return `-EPROBE_DEFER` (`vendor/linux/drivers/pinctrl/devicetree.c:126-140`, `build/linux/.config:925`).
2. The configured 10-second deferred-probe timeout triggers another pass and reports remaining devices; it does not delete them from the pending list (`build/linux/.config:1858`, `vendor/linux/drivers/base/dd.c:301-317`). A successful later driver bind triggers reprobe of pending devices (`vendor/linux/drivers/base/dd.c:159-197`).
3. `tegra_drm` registers the DPAUX platform driver before the SOR driver (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1413-1448`). DPAUX1 configures its pad for I2C and registers the pinctrl provider during probe (`vendor/linux/drivers/gpu/drm/tegra/dpaux.c:530-555`). That permits I2C4 to bind and publish the DDC adapter.
4. If SOR1 races ahead of I2C4's deferred reprobe, `tegra_output_probe()` fails with `-EPROBE_DEFER` when the phandled adapter is absent; I2C4's later successful bind triggers another deferred-probe pass (`vendor/linux/drivers/gpu/drm/tegra/output.c:127-135`, `vendor/linux/drivers/base/dd.c:159-197`).

The precise extra ordering imposed by `fw_devlink` for a pinctrl subnode supplied by a module is **UNCERTAIN**, but neither outcome bypasses the explicit pinctrl and DDC deferrals above.

### 4. HDMI 5 V

There is no intentional probe glitch: `boot-on` maps to `GPIOD_OUT_HIGH`, and Tegra writes the output value before output-enable (`vendor/linux/drivers/regulator/fixed.c:191-192`, `vendor/linux/drivers/regulator/fixed.c:291-320`, `vendor/linux/drivers/gpio/gpio-tegra.c:182-192`). The proposed SOR supply reference is correct (`kernel/dts/darcy.dts:155-161`).

The real caveat is explicit disable, not unused-regulator cleanup. SOR probe-failure cleanup, module removal, and system suspend can disable it (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2972-3027`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:4024-4067`). For the first experiment, `regulator-always-on` is a sensible guard. Reboot will reprobe the fixed regulator high even without that guard.

### 5. Drive current

At a 148.5 MHz pixel clock, mainline selects the first table entry whose frequency is at least the requested frequency: the 150 MHz entry (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2127-2136`). That entry programs `{0x33, 0x3a, 0x3a, 0x3a}` (`vendor/linux/drivers/gpu/drm/tegra/sor.c:92-105`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:2489-2530`), while stock Darcy uses `0x2d303030` throughout 75-300 MHz (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-prods.dtsi:58-75`).

**UNCERTAIN:** numeric code ordering alone is not enough to quantify physical lane current or certify the signal-integrity/EMI margin. I do not see evidence of a destructive risk from one 1080p test: these are mainline's Tegra210 settings, and all the other live PLL/termination/TX-PU values match. I would not block the first test on a global `sor.c` patch. If there is no link, sparkle, or instability, retry with Darcy's exact stock drive values as the first PHY change. A later board-specific mechanism is preferable to silently changing the Tegra210-wide table.

### 6. `video=HDMI-A-1:1920x1080@60`

The name is right for this DT. SOR1's HDMI path creates an `HDMI-A` connector (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3082-3087`); connector type IDs start at 1 and produce `HDMI-A-1` (`vendor/linux/drivers/gpu/drm/drm_connector.c:93-115`, `vendor/linux/drivers/gpu/drm/drm_connector.c:259-269`). This assumes no other HDMI-A connector is registered first; with only SOR1 enabled, that assumption is sound.

The syntax is accepted (`vendor/linux/drivers/gpu/drm/drm_modes.c:2337-2363`). DRM parses the option against the connector's exact name during connector initialization (`vendor/linux/drivers/gpu/drm/drm_connector.c:148-175`, `vendor/linux/drivers/gpu/drm/drm_connector.c:259-295`). The fbdev client prefers the command-line mode before preferred and first modes (`vendor/linux/drivers/gpu/drm/drm_client_modeset.c:173-227`, `vendor/linux/drivers/gpu/drm/drm_client_modeset.c:473-487`), and this build selects the fbdev DRM client (`build/linux/.config:5084-5088`, `vendor/linux/drivers/gpu/drm/clients/drm_client_setup.c:35-50`). A 59.94 Hz EDID mode matches `@60` because DRM rounds vrefresh to the nearest integer (`vendor/linux/drivers/gpu/drm/drm_modes.c:1280-1308`).

Keeping the pin is reasonable for a repeatable first handoff at cboot's known pixel clock. Do not append `e` yet: the current string still requires HPD, so it tests the active-low CC1 description. The GPIO consumer sees the DT inversion and treats logical high as connected (`vendor/linux/drivers/gpu/drm/tegra/output.c:52-73`, `kernel/dts/darcy.dts:155-161`). Remember the synthesized-GTF caveat above.

### 7. `modprobe.d` blacklist

Confirmed. In kmod semantics, `blacklist tegra_drm` suppresses alias-based loading; `modprobe -b`/`--use-blacklist`, as used by udev, applies it during automatic probing. A direct `modprobe tegra_drm` without `-b` is an explicit module-name request and still loads. See `modprobe.d(5)` under **COMMANDS / blacklist** and `modprobe(8)` under **--use-blacklist**. Hyphens and underscores are normalized by kmod.

This also covers host1x's post-soft-dependency on `tegra-drm` when the initiating automatic request applies the blacklist (`vendor/linux/drivers/gpu/host1x/dev.c:827`). The current system has already empirically logged that its device-manager attempts are refused by the blacklist (`NOTES.md:1013-1017`). Removing the stronger kernel `module_blacklist=tegra_drm` is necessary because that mechanism would also reject the explicit manual load; the proposed bootargs do remove it (`kernel/dts/darcy-system.dts:20-33`).

### 8. Recovery without a TV

I found no persistent write in the reviewed display paths; the dangerous effects are loss of the current scanout, a disabled HDMI rail, or a live driver wait. Reboot re-establishes the cboot state and fixed-regulator probe state. The screen can legitimately stay black after a partial failure because the Tegra DRM master removes simpledrm before registering the new device/fbdev client (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1250-1275`).

The unbounded SOR waits are the main watchdog blind spot, so use the pre-armed timer above. Preserve the existing `panic=10`, runtime watchdog, ramoops, and U-Boot watchdog-reason fallback (`kernel/dts/darcy-system.dts:33-39`, `scripts/13-make-rootfs.sh:197-202`, `NOTES.md:714-727`). If the whole kernel or SoC wedges, the already-proven hardware watchdog is the recovery path. A bus-level MMIO stall that also prevents the watchdog hardware from progressing is **UNCERTAIN**, but no source path can rule that out.

### 9. Missing Tegra210 pieces

I found none required for first SOR1 HDMI scanout:

- The base SoC DT already gives both DC heads their clocks, resets, SMMU clients, `nvidia,outputs` including SOR1, and `nvidia,head = <0/1>` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:192-220`). The driver consumes `nvidia,head` and uses `nvidia,outputs` to determine possible CRTCs (`vendor/linux/drivers/gpu/drm/tegra/dc.c:194-206`, `vendor/linux/drivers/gpu/drm/tegra/dc.c:3187-3221`).
- SOR1 already has all five Tegra210 clocks, including PLL_D2_OUT0 as parent and SOR_SAFE, plus its reset (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:336-353`). The SOR driver changes its parents and rate during HDMI enable (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2410-2434`), so an `assigned-clocks` property is not missing.
- The proposed DT adds the three supplies, DDC, HPD, DPAUX1, and I2C4 that the driver/board wiring needs (`kernel/dts/darcy.dts:151-169`). Jetson TX1 uses the same basic SOR1 recipe without assigned clocks or an XBAR override (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2597.dtsi:15-40`).
- Omitting `nvidia,xbar-cfg` selects Tegra210's `{2,1,0,3,4}` default (`vendor/linux/drivers/gpu/drm/tegra/sor.c:3498-3500`, `vendor/linux/drivers/gpu/drm/tegra/sor.c:3524-3541`), which matches the measured cboot value and is rewritten during HDMI enable (`vendor/linux/drivers/gpu/drm/tegra/sor.c:2387-2393`).
- VIC is a host1x DRM subdevice, but it is not a display timing/output block (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1359-1411`). Its firmware being present avoids an unrelated component failure; it does not replace any missing SOR/DC property. The previous tegra-drm registration already exercises the host1x/SMMU baseline.

The first useful failure split is therefore: (a) no connector/DDC adapter or deferred probe, (b) HPD/EDID failure, (c) DC DIS power-up failure, (d) HDMI DPD/PHY sequence failure, or (e) fbdev modeset failure. The requested dmesg, connector `status/modes/edid`, and SOR register dump distinguish those without further DT guessing.
