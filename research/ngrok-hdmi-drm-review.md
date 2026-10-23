# Review: HDMI through tegra-drm (ngrok)

The diff is a sound first test **if** `/etc/modprobe.d/20-darcy-tegra-drm.conf` is already on the running SSD before the FIT that drops `module_blacklist=tegra_drm` is flashed. Do not patch lane current into `sor.c` first. Do not copy Nano's SOR1 `nvidia,xbar-cfg` or `nvidia,dpaux`.

`modprobe tegra_drm` will blank the TV even when the secure-monitor powergate write fails. The picture comes back only if that write then succeeds for the DIS partition and `tegra_sor_hdmi_enable()` finishes. A failed write leaves a live kernel and a dark TV. SSH is the way back. A normal reboot does not enter fastboot.

The comment at `kernel/dts/darcy.dts:148-149` ("until it loads none of this touches the picture") is wrong for `vdd_hdmi`. That regulator is built in and probes at boot. SOR1, DPAUX1 and the DC drivers are inside `tegra-drm.ko` (`drivers/gpu/drm/tegra/Makefile:4-35`), so their resets and clock reparent wait for the module.

## 1. No SOR power domain

SOR1, DPAUX1 and the two DCs still probe. Nothing on this path calls the SOR powergate.

`tegra210.dtsi` `powergates` has `pd_sor` and has no `dis` or `disb` node (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:921-1000`). Deleting `&pd_sor` (`kernel/dts/darcy.dts:137`) means `tegra_powergate_add()` never runs for SOR, so it never powers that partition down (`drivers/soc/tegra/pmc.c:1361-1379`) and never clears SOR's legacy bit (`pmc.c:1334-1338`). `tegra_pmc_init_common()` still sets every named gate available, including `"sor"`, `"dis"` and `"disb"` (`pmc.c:2964-2967`, `pmc.c:3720-3734`). No driver calls `TEGRA_POWERGATE_SOR`. The only hits are the name table and the MBIST table (`drivers/clk/tegra/clk-tegra210.c:2672`).

With `power-domains` deleted, `pdev->dev.pm_domain` is NULL:

- DPAUX takes its own reset (`drivers/gpu/drm/tegra/dpaux.c:471-478`).
- SOR's exclusive reset is not `-EBUSY`, so `sor->rst` stays set (`sor.c:3843-3859`). The genpd branch that leaves `sor->rst` NULL is the other one.
- The DC has no `power-domains` in the SoC dtsi (`tegra210.dtsi:192-220`). `tegra210_dc_soc_info.has_powergate` is true (`dc.c:3034-3042`). Probe uses the legacy ids `TEGRA_POWERGATE_DIS` / `DISB` (`dc.c:3333-3344`). That call does not need `pd_sor`.

What does kill cboot's link, at `modprobe` time, all inside `tegra-drm.ko`:

1. Each DC probe enables its clock, asserts its reset, then drops the clock (`dc.c:3316-3331`), then calls `tegra_pmc_powergate_power_off()` and ignores the return (`dc.c:3344`). Head 0 is cboot's head (`STATE1` owner 0 in the brief). Head 1 does the same to DISB.
2. SOR probe switches `clk_out` onto `sor_safe` (`sor.c:3935-3944`).
3. Because `sor->rst` is set, client init asserts then deasserts the SOR reset (`sor.c:3140-3184`). The comment there says this stays until a firmware hand-over exists.

The DRM device is not created until every available host1x subdev has registered (`drivers/gpu/host1x/bus.c:125-130`). `aperture_remove_all_conflicting_devices` runs only after that, and only if `num_crtc > 0` (`drm.c:1259-1260`). simpledrm is removed after the resets above, not before.

Coming back is `tegra_dc_runtime_resume()` → `tegra_pmc_powergate_sequence_power_up(DIS)` (`dc.c:2902-2908`) and then `tegra_sor_hdmi_enable()`. `sequence_power_up` asserts the DC reset first and, if `tegra_powergate_set(..., true)` fails, returns before deasserting it (`pmc.c:829-842`). The screen stays dark. Runtime PM without a genpd does not power the SOR partition; SOR is reprogrammed in the HDMI enable path, not by genpd.

`nvdec`, `nvjpg`, `vic` and both DCs are available subdevs (no `status = "disabled"` in `tegra210.dtsi`). The composite device waits for all of them. Tegra210 NVDEC's probe does not load firmware (`nvdec.c:384-388`, `504-527`). A probe failure of one of those engines would leave the DRM device unregistered after the DC reset had already fired. That is a dark TV with the kernel still up, and it is the same SoC dtsi Jetson uses.

## 2. Legacy DIS/DISB and the IO pad, through the monitor

On Tegra210 the calls are SMC writes, not MMIO. Whether this board's monitor accepts the write is **not shown**. Earlier runs read PMC through the same SMC. A write has not been observed.

`tegra210_pmc_soc.maybe_tz_only` is true (`pmc.c:3874`), so `tegra_pmc_detect_tz_only()` runs (`pmc.c:2961-2962`, `2931-2954`). `tegra_pmc_writel()` then uses `TEGRA_SMC_PMC` / `TEGRA_SMC_PMC_WRITE` (`pmc.c:552-567`). A nonzero `res.a0` is a warning. The write is not retried.

`powergate_set` is `tegra114_powergate_set` (`pmc.c:3884`). It writes `PWRGATE_TOGGLE_START | id` and polls with `read_poll_timeout` / `readx_poll_timeout` for up to 100 ms (`pmc.c:655-680`). Those sleeps. `tegra_powergate_set()` no-ops when the status bit is already in the requested state (`pmc.c:701-704`). `tegra_pmc_powergate_power_off()` and `tegra_pmc_powergate_sequence_power_up()` both go through that (`pmc.c:1075-1080`, `1120-1146`). `sequence_power_up` then removes the clamp, deasserts the reset, and on Tegra210 runs the MBIST workaround (`pmc.c:856-869`, `needs_mbist_war` at `pmc.c:3872`). The DIS workaround's clocks are filled at clock init (`clk-tegra210.c:2679-2682`, `3697-3724`). If `clks` were NULL the workaround returns `-ENODEV` (`clk-tegra210.c:2757-2758`) and `sequence_power_up` powers the partition back off (`pmc.c:889-890`).

The other PMC write on the HDMI modeset path is the HDMI IO pad, not the SOR powergate. With no `nvidia,dpaux` phandle the driver sets `ops` to the HDMI ops and `pad` to `TEGRA_IO_PAD_HDMI` (`sor.c:3782-3785`). Adding `nvidia,dpaux` would select the DP ops and `TEGRA_IO_PAD_LVDS` (`sor.c:3793-3802`). The proposed fragment does not add that phandle.

`tegra_sor_hdmi_enable()` calls `tegra_pmc_io_pad_power_enable(sor->pmc, sor->pad)` and logs the error without returning (`sor.c:2283-2285`). That writes `IO_DPD_REQ_CODE_OFF | mask` through `tegra_pmc_writel` and polls up to 250 ms with `usleep_range` (`pmc.c:1680-1703`, `1649-1664`). The Tegra210 HDMI pad is bit 28 of `0x1b8`/`0x1bc` (`pmc.c:3775`). `has_io_pad_wren` (`pmc.c:3873`) is used for pad voltage in `PMC_PWR_DET` (`pmc.c:1796-1800`), not for this DPD request. The disable path calls `tegra_pmc_io_pad_power_disable` the same way (`sor.c:2243`).

A rejected SMC is a logged timeout and a dark screen. It is not a panic and it is not an irq-off spin. Do not treat a dark screen as proof the write was refused until dmesg shows the timeout.

## 3. I2C4 pinmux versus the module

The order is safe. I2C4 defers from boot until DPAUX1's pinctrl device exists, and the DRM device waits until SOR has its adapter.

`i2c@7000c700` already has `pinctrl-0 = <&state_dpaux1_i2c>` and `pinctrl-names = "default", "idle"` (`tegra210.dtsi:750-765`). `state_dpaux1_i2c` is a child of `dpaux1` (`tegra210.dtsi:125-128`). The overlay in `darcy.dts:164-168` only sets `status` and `clock-frequency`. `i2c-tegra` is built in. Before its probe, `pinctrl_bind_pins()` looks up the default state (`drivers/base/pinctrl.c:23-56`). The pinctrl device is registered in `tegra_dpaux_probe()` after the pads are forced to I2C (`dpaux.c:530-555`). Until then `dt_to_map_one_config()` walks parents, finds no controller, and because modules are enabled returns `-EPROBE_DEFER` (`drivers/pinctrl/devicetree.c:126-139`). `pinctrl_bind_pins()` passes that deferral back (`pinctrl.c:99-100`).

`fw_devlink` also links `pinctrl-N` (`drivers/of/property.c:1421-1430`). The deferred-probe timeout defaults to 10 s when modules are on (`drivers/base/Kconfig:76-79`, `dd.c:260`). When it fires, `fw_devlink_drivers_done()` relaxes a link only if the supplier cannot match a driver (`drivers/base/core.c:1824-1838`). `dpaux1` matches `tegra_dpaux_of_match` inside the module, so the i2c device stays deferred. It is not abandoned. `driver_bound()` retriggers deferred probes (`dd.c:461-466`).

SOR asks for the adapter in `tegra_output_probe()` and returns `-EPROBE_DEFER` if `of_get_i2c_adapter_by_node()` is NULL (`output.c:127-134`). Platform drivers are registered dpaux then sor (`drm.c:1418-1419`). The i2c reprobe is asynchronous, so SOR can defer once. `host1x` adds the logical DRM device only when no subdev is still waiting (`bus.c:125-130`), and `sor1` is one of those subdevs (`drm.c:1382`). `aperture_remove` and fbdev therefore run after the DDC adapter exists, or not at all.

DPAUX probe also sets its parent clock to 270 MHz (`dpaux.c:495-500`). That is `pll_dp`, which is off today. It happens at modprobe, with the rest of the module.

If DDC then fails, `tegra_output_connector_get_modes()` still returns and fbdev can use the `video=` mode (`output.c:39-46`, question 6). HPD is GPIO CC1, requested as an input at SOR probe (`output.c:141-145`), which is a different pin from CC7.

## 4. vdd_hdmi and CC7

Probe drives CC7 high. Nothing else in this DT turns it off. A low glitch is not in the Tegra GPIO sequence for a pin that is already high.

`vdd_hdmi` is a fixed 5 V regulator, `regulator-boot-on`, GPIO CC7 active high, from `vdd_sys_boost` which is `regulator-always-on` (`tegra210-p2894.dtsi:1707-1729`). The diff stops disabling it (`kernel/dts/darcy.dts:83-91`). `boot_on` sets `enabled_at_boot`, and the probe requests the GPIO as `GPIOD_OUT_HIGH` (`drivers/regulator/fixed.c:191-192`, `295-317`). `fixed_voltage_ops` is empty (`fixed.c:203-204`); the core owns the enable GPIO.

`set_machine_constraints()` calls `_regulator_do_enable()` for `boot_on`, and increments `use_count` only for `always_on` (`drivers/regulator/core.c:1662-1697`). `regulator_ignore_unused` is on the system command line (`kernel/dts/darcy-system.dts:27`) and makes the late unused-regulator pass return immediately (`core.c:6850-6866`).

The only `hdmi-supply` consumer is SOR. `tegra_sor_hdmi_probe()` enables it at modprobe and disables it from a devm action when the driver detaches (`sor.c:2972-2987`, `3018-3027`). A failed modeset does not drop that reference. No other `vdd_hdmi` consumer is in `darcy.dts`.

`tegra_gpio_direction_output()` writes the output value, then sets OE, then sets CNF (`drivers/gpio/gpio-tegra.c:182-191`, `149-156`). The live pin is already output high (brief: OE `0xb0`, OUT `0x90`, CNF `0xb2`). Writing 1 again does not clear the bit. `GPIO_ACTIVE_HIGH` means `GPIOD_OUT_HIGH` is a physical high. **Guess, narrow:** a glitch would have to come from a layer below this write sequence. I did not find one.

`max77620_ldo8` appears only as the new SOR `avdd-io-hdmi-dp-supply` (`darcy.dts:156`). It is enabled at the same modprobe, not at boot. `max77620_sd3` is already the USB, PCIe and sdmmc supply (`darcy.dts:180`, `183`, `229`, `244`, `356`, `358`), so SOR's enable of it is another consumer of a rail those drivers already use.

## 5. Drive current

Use mainline's table for the first picture. Patch darcy's `0x2d303030` only if that picture is unstable.

`tegra_sor_hdmi_find_settings()` returns the first row whose frequency is greater than or equal to the pixel clock (`sor.c:2128-2135`). 148.5 MHz and cboot's 148.35 MHz both land on the 150 MHz row under `#if 1` (`sor.c:59-105`): `drive_current = { 0x33, 0x3a, 0x3a, 0x3a }`, preemphasis 0, `tx_pu_value` `0x66`. The write packs lane 3 in the top byte (`sor.c:2526-2536`), so the register value is `0x3a3a3a33` at `SOR_LANE_DRIVE_CURRENT0`, index `0x4e` (`sor.h:238`).

Stock darcy's 54–75, 75–150 and 150–300 MHz HDMI prods all write `0x2d303030` at byte offset `0x138`, which is that same index (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-prods.dtsi:48-76`). Mainline does not read those prods. The 300 MHz mainline row goes up to `0x3f` with preemphasis (`sor.c:107-120`); 1080p does not select it.

`0x3a` is the value mainline ships for this SoC at this rate. This source does not show it damaging the PHY. It is hotter than the darcy prod. That is a link-quality risk, **uncertain** as a hardware-damage risk. PLL0/PLL1/PLL3 and TX_PU in that same 150 MHz row match the live cboot values in the brief. The crossbar does not need an override: a missing `nvidia,xbar-cfg` copies `tegra210_sor_xbar_cfg` `{2, 1, 0, 3, 4}` (`sor.c:3498-3500`, `3701-3705`), and `SOR_XBAR_CTRL_LINK0_XSEL` / `LINK1_XSEL` (`sor.h:222-223`) pack that to `0x8d111828`, which is the live register. `tegra_sor_hdmi_enable()` writes it (`sor.c:2387-2393`).

## 6. `video=HDMI-A-1:1920x1080@60`

The name is right, fbdev honours it, and pinning 1080p is the right first test.

SOR sets `DRM_MODE_CONNECTOR_HDMIA` (`sor.c:3082-3084`). The core names that type `"HDMI-A"` and formats `"%s-%d"` with an id starting at 1 (`drivers/gpu/drm/drm_connector.c:105`, `260-269`). One HDMI connector is `HDMI-A-1`. `drm_connector_get_cmdline_mode()` parses `video=` for that name (`drm_connector.c:158-167`). simpledrm's connector type is `DRM_MODE_CONNECTOR_Unknown` (`drivers/gpu/drm/sysfb/simpledrm.c:842-843`), whose name is `"Unknown"` (`drm_connector.c:94`), so this parameter does not move the console while simpledrm owns it.

Fbdev setup goes through `drm_client_setup()` (`drm.c:1275`). The client picker tries the cmdline mode before the EDID preferred mode (`drivers/gpu/drm/drm_client_modeset.c:473-480` and `722-729`). If a probed mode is 1920x1080 and `drm_mode_vrefresh()` is 60, that mode is marked `DRM_MODE_TYPE_USERDEF` and no extra mode is added (`drm_probe_helper.c:155-169`). A 1080p60 EDID mode would then be the CEA timing the sink listed (148.5 MHz, 2200x1125), which is the same settings row as cboot's 148.35 MHz.

If DDC fails there is no probed match, and `drm_mode_create_from_cmdline_mode()` builds a GTF mode because the string has no `M` (`drm_modes.c:2550-2561`). GTF 1920x1080@60 is not the CEA 2200x1125 timing. I am not stating its pixel clock; I did not execute the GTF function. Pinning 1080p still avoids a 4K preferred mode. Keep `@60`.

## 7. modprobe.d blacklist

`blacklist tegra_drm` stops the udev alias load. `modprobe tegra_drm` by that name still inserts the module. The file has to be on the SSD before this FIT is flashed.

The module is built as `tegra-drm.o` (`Makefile:35`). `KBUILD_MODNAME` turns `-` into `_` (`scripts/Makefile.lib:19-23`), which is why the kernel parameter is `tegra_drm`. That parameter rejects the load itself (`kernel/module/main.c:3406-3408`). The diff removes it for that reason (`kernel/dts/darcy-system.dts:27`).

`modprobe.d(5)` says `blacklist modulename` makes modprobe ignore that module's internal aliases, and that `-` and `_` are interchangeable in module names. It does not block a request that names the module. `libkmod.h` separates `KMOD_PROBE_APPLY_BLACKLIST` from `KMOD_PROBE_APPLY_BLACKLIST_ALIAS_ONLY` (`/usr/include/libkmod.h:744-751`). The aliases exist: `MODULE_DEVICE_TABLE(of, ...)` on the DC, SOR, DPAUX, VIC and NVDEC tables (`dc.c:3185`, `sor.c:3672`, `dpaux.c:686`, `vic.c:446`, `nvdec.c:420`) is what makes udev load `tegra-drm.ko` when those nodes are okay. host1x is a different module and is not in this blacklist. It does not call `aperture_remove`.

`scripts/13-make-rootfs.sh:191-194` writes the conf into a rootfs that script builds. It does not edit the SSD that is already mounted on the SHIELD. Flash the new FIT only after that one file is on the SSD. If it is missing, udev loads `tegra_drm` during boot, the DC reset and the SOR reparent run with nobody at the SSH prompt yet, and the "boot as today, then modprobe" step is gone.

## 8. Recovery without the TV

A modeset that returns, and an oops that stays in that process, leave Wi-Fi and SSH up. `reboot` over SSH is the way back. `reboot` of a system payload does not enter fastboot. `reboot bootloader` does: the restart notifier writes `PMC_SCRATCH0_MODE_BOOTLOADER` for the command `bootloader` (`pmc.c:1170-1171`, `1180-1186`).

The waits on this path sleep: powergate polls (`pmc.c:662-678`), IO-pad poll (`pmc.c:1656-1661`), SOR lane sequence (`sor.c:2322-2339`). They take the powergate mutex. A refused SMC is a timeout of 100 ms or 250 ms, then an error return. systemd's `RuntimeWatchdogSec=60s` (`scripts/13-make-rootfs.sh:201`) fires if userspace stops petting `tegra_wdt`. A panic still has `panic=10` on the command line and the ramoops `max-reason` already reviewed; that path can divert to fastboot. I am not repeating it.

What that machinery does not cover: SSH is dead, systemd is still petting the watchdog, and the box sits there until a power pull. A power pull does not enter fastboot. **Guess:** I did not find a spin with interrupts off on the HDMI probe path. An MMIO read that hung the bus would be outside the watchdog only if the hang still let systemd run, which a wedged CPU does not. I have no evidence the SOR registers hang when the partition cboot left on is still on.

Put the modprobe.d file in place, boot, confirm the console is still simpledrm and `tegra_drm` is not loaded, then modprobe once.

## 9. What Jetson has that this fragment does not repeat

The clocks, resets, safe clock, `pll_d2` parent, `nvidia,head` and `nvidia,outputs` are already on the SoC nodes. The fragment is right to add only status, the three supplies, DDC and HPD.

| Piece | Where it already is |
|---|---|
| DC head, `nvidia,outputs` including `&sor1`, `iommus` | `tegra210.dtsi:192-220` |
| SOR1 clocks `sor`, `out`, `parent` = `pll_d2_out0`, `dp`, `safe`; reset `sor` | `tegra210.dtsi:336-353` |
| DPAUX1 clocks, reset, pinmux states | `tegra210.dtsi:108-138` |
| I2C4 default pinctrl | `tegra210.dtsi:762-764` |
| VIC node, `pd_vic` (not deleted) | `tegra210.dtsi:240-251` |

TX1 (`tegra210-p2597.dtsi:16-40`, `1407-1411`) enables DPAUX1 and SOR1 with the same three supply properties, DDC and HPD, and does not set `nvidia,xbar-cfg` or `nvidia,dpaux`. That is the fragment.

Nano's HDMI SOR is `sor@54580000` and sets `nvidia,xbar-cfg = <0 1 2 3 4>` (`tegra210-p3450-0000.dts:90-101`). That is not `{2, 1, 0, 3, 4}` and would not write cboot's `0x8d111828`. Nano's `nvidia,dpaux` is on `sor@54540000` (`p3450-0000.dts:80-88`), the eDP SOR. Copying it onto darcy SOR1 selects DP and the LVDS pad (`sor.c:3793-3802`).

No `assigned-clocks` on the TX1 SOR node either. The driver does the parent switch itself (`sor.c:3940`, `2411-2423`). VIC firmware is loaded from runtime resume (`vic.c:306-328`), not from probe (`vic.c:448-527`), so the first fbdev modeset does not need `vic04_ucode.bin`. The SMMU is on (`TEGRA_IOMMU_SMMU=y` in the brief) and the DC attaches during client init; a real attach error fails that init (`dc.c:2748-2751`) and fails the DRM probe after the DC reset. That is the Jetson path too, not a missing property.

`pll_dp` being off until DPAUX probe is expected (`dpaux.c:495`). It is not a DT hole.
