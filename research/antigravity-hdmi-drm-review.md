# Review: HDMI (SOR1) through `tegra-drm` on `darcy` (SHIELD TV 2017)

## Summary Verdict

The proposed diff (`hdmi-drm.diff`) and test plan are **safe to run** and will **not** risk an unrecoverable hang or loss of SSH. All 9 questions have been checked against `vendor/linux` (Linux 7.2.11) and the `darcy` device tree.

There is **one real timing catch** found in Question 4 that is worth fixing in `darcy.dts` before flashing (or working around during the test):
- **`vdd_hdmi` has `regulator-boot-on` but not `regulator-always-on`** (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1810-1820`). Because `tegra_drm` is blacklisted at boot (`use_count == 0`) and `bootargs` does not have `regulator_ignore_unused`, the regulator core's 30-second `regulator_init_complete_work` (`drivers/regulator/core.c:6806-6848, 6903-6905`) will log `VDD_HDMI_5V0: disabling` and **drive GPIO CC7 low 30 seconds after boot** if `modprobe tegra_drm` has not run yet. Adding `regulator-always-on;` (and `startup-delay-us = <5000>;` from stock `tegra210-ers-fixed-e2174-1101-a00.dtsi:111`) to `&vdd_hdmi` in `kernel/dts/darcy.dts` prevents the 30-second 5V drop completely.

---

## 1. No SOR power domain (`pd_sor` deleted)

With `/delete-node/ &pd_sor;` and `/delete-property/ power-domains;` on `sor0`, `sor1`, `dpaux`, `dpaux1`, `dsia`, `dsib`, `csi`, and `hda` (`kernel/dts/darcy.dts:101-137`), **`dpaux.c`, `sor.c`, and `dc.c` all bring HDMI up cleanly without `pd_sor`**:

- **Nothing calls the legacy powergate API for `TEGRA_POWERGATE_SOR`:**
  - Across the entire kernel tree, `TEGRA_POWERGATE_SOR` (ID 17) is referenced only in `drivers/soc/tegra/pmc.c:3584, 3732` (DT powergate name tables) and `drivers/clk/tegra/clk-tegra210.c:2672` (`tegra210_pg_mbist_war[TEGRA_POWERGATE_SOR]`, invoked only from `tegra_powergate_power_up()` at `pmc.c:869`).
  - No driver ever calls `tegra_powergate_power_off(TEGRA_POWERGATE_SOR)` or `tegra_pmc_powergate_power_off(..., TEGRA_POWERGATE_SOR)`. The SOR partition stays powered on continuously as cboot left it (`PWRGATE_STATUS` bit 17 = 1).

- **`dpaux.c` without `pm_domain`:**
  - `tegra_dpaux_probe()` (`drivers/gpu/drm/tegra/dpaux.c:471-479`) explicitly handles `pdev->dev.pm_domain == NULL` by acquiring `dpaux->rst = devm_reset_control_get(&pdev->dev, "dpaux")` (`<&tegra_car 207>`, `tegra210.dtsi:227-228`).
  - `pm_runtime_enable()` + `pm_runtime_get_sync()` (`dpaux.c:511-513`) with `dev->pm_domain == NULL` invokes the driver's own runtime PM callback `tegra_dpaux_resume()` (`dpaux.c:619-655, 658`), which enables `dpaux->clk_parent` (`pll_dp`), `dpaux->clk` (`dpaux1`), and deasserts `dpaux->rst`.

- **`sor.c` without `pm_domain`:**
  - `tegra_sor_probe()` (`drivers/gpu/drm/tegra/sor.c:3843-3860`) calls `devm_reset_control_get_exclusive_released(&pdev->dev, "sor")`. Because `pd_sor` was deleted and never claimed reset 183 (`<&tegra_car 183>`, `tegra210.dtsi:346`), this succeeds and `sor->rst` is non-NULL.
  - Both `tegra_sor_init()` (`sor.c:3144-3185`) and `tegra_sor_runtime_resume()` / `tegra_sor_runtime_suspend()` (`sor.c:3231-3298`) check `if (sor->rst)` and manage `sor->rst` (acquire/assert/deassert/release) and `sor->clk` directly.
  - When `tegra_sor_hdmi_enable()` calls `host1x_client_resume(&sor->client)` (`sor.c:2268` -> `drivers/gpu/host1x/bus.c:770-793`), `pm_runtime_resume_and_get(dev)` runs `tegra_sor_runtime_resume()` with `dev->pm_domain == NULL`.

- **`dc.c` without `pd_sor`:**
  - `dc@54200000` and `dc@54240000` (`tegra210.dtsi:192-220`) never used `pd_sor` or `power-domains`.
  - On Tegra210, `tegra210_dc_soc_info.has_powergate = true` (`drivers/gpu/drm/tegra/dc.c:3042`), so DC uses the legacy powergate API (`TEGRA_POWERGATE_DIS` / `TEGRA_POWERGATE_DISB`) in `tegra_dc_probe()` (`dc.c:3333-3345`), `tegra_dc_runtime_resume()` (`dc.c:2902-2910`), and `tegra_dc_runtime_suspend()` (`dc.c:2881-2882`).
  - The only `genpd` call in `dc.c` is `dev_pm_genpd_set_performance_state()` (`dc.c:1986, 2251`), which is guarded by `if (dc->has_opp_table)`. On Tegra210, `tegra_dc_init_opp_table()` (`dc.c:3258-3273`) calls `devm_tegra_core_dev_init_opp_table()` (`drivers/soc/tegra/common.c:106-144`), which only matches Tegra20/30/114 (`common.c:110-139`) and returns `-ENODEV`, setting `dc->has_opp_table = false`.

---

## 2. The DC's legacy powergate and IO pad DPD on a TZ-only PMC

- **Legacy powergate API for `DIS` (18) and `DISB` (19):**
  - In `tegra_pmc_init_common()` (`drivers/soc/tegra/pmc.c:2965-2967`), all non-NULL entries in `tegra210_powergates[]` (`pmc.c:3566-3591`) are set in `pmc->powergates_available`. Because `tegra210.dtsi:921-1000` has no `dis` or `disb` child nodes under `powergates`, `tegra_powergate_add()` (`pmc.c:1338`) never clears bits 18 or 19 from `pmc->powergates_available`, so `tegra_powergate_is_available()` (`pmc.c:663-666`) returns `true`.
  - `tegra_pmc_powergate_power_off()` (`dc.c:3344, 2882` -> `pmc.c:1075-1081`) and `tegra_pmc_powergate_sequence_power_up()` (`dc.c:2903-2905` -> `pmc.c:1120-1155` -> `tegra_powergate_power_up()` at `pmc.c:829-893`) call `tegra114_powergate_set()` (`pmc.c:775-819`, registers `PWRGATE_STATUS` `0x38` and `PWRGATE_TOGGLE` `0x30`) and `__tegra_powergate_remove_clamping()` (`pmc.c:821-827`, register `REMOVE_CLAMPING` `0x34`).
  - Those are the **exact same helper functions and PMC registers** used by `tegra_genpd_power_on()` / `tegra_genpd_power_off()` (`pmc.c:1164-1197`), and all of them route through `tegra_pmc_readl()` / `tegra_pmc_writel()` (`pmc.c:530-571`), which issue `arm_smccc_smc(TEGRA_SMC_PMC, ...)` (`0xc2fffe00`) when `pmc->tz_only` is `true` (`pmc.c:2902-2928`). Those SMC calls were already exercised and verified on darcy in Runs 4 and 5 (`NOTES.md:489, 558-561, 710`).
  - Note: during `tegra_powergate_power_up()` (`pmc.c:868-869`), `pmc->soc->handle_mbist_war` (`tegra210_clk_handle_mbist_war()`, `drivers/clk/tegra/clk-tegra210.c:2679-2690, 2743-2773`) also runs for `DIS` and `DISB`. It touches CAR (`0x60006000` + `LVL2_CLK_GATE_OVRB`/`OVRE`) and `disp_slcg_clkids` (`TEGRA210_CLK_LA`, `TEGRA210_CLK_HOST1X`), not PMC.

- **IO pad DPD (`TEGRA_IO_PAD_HDMI`, `sor.c:2283` and `sor.c:2243`):**
  - `tegra_pmc_io_pad_power_enable()` and `tegra_pmc_io_pad_power_disable()` (`pmc.c:1680-1758`) look up `TEGRA_IO_PAD_HDMI` in `tegra210_io_pads[]` (`pmc.c:3775`, bit 28 in `IO_DPD_REQ` `0x1b8` / `IO_DPD_STATUS` `0x1bc`) and access `DPD_SAMPLE` (`0x20`), `SEL_DPD_TIM` (`0x1c8`), `IO_DPD_REQ` (`0x1b8`), and `IO_DPD_STATUS` (`0x1bc`) exclusively through `tegra_pmc_readl()` / `tegra_pmc_writel()` (SMC `0xc2fffe00`).
  - Moreover, `pcie@1003000` (`tegra210.dtsi:55-57, 880-883`) **already exercised this exact function (`tegra_pmc_io_pad_power_enable` via `tegra_io_pad_pinconf_set` at `pmc.c:2175`) and the `0x1b8`/`0x1bc` register pair through the secure monitor** during PCIe probe on darcy (`pex-bias`, `pex-clk1`, `pex-clk2`).
  - Nothing else on the `tegra-drm` probe or modeset path accesses PMC registers.

---

## 3. I2C4 (`i2c@7000c700`) pinmux in DPAUX1 (`state_dpaux1_i2c`), deferred probe, and probe order

- **At boot (while `tegra_drm` is blacklisted in `modprobe.d`):**
  1. `fw_devlink` (`drivers/of/property.c:1421-1431, 1556`) parses `pinctrl-0 = <&state_dpaux1_i2c>` on `i2c@7000c700` (`tegra210.dtsi:1251-1252`) and creates a device link from supplier `54040000.dpaux` to consumer `7000c700.i2c`.
  2. Before the 10-second deferred probe timeout (`CONFIG_DRIVER_DEFERRED_PROBE_TIMEOUT=10`, `build/linux/.config:1858`, `drivers/base/dd.c:260, 361-364`), `device_links_check_suppliers()` (`drivers/base/core.c:1150-1163`) defers `7000c700.i2c` with `-EPROBE_DEFER`.
  3. At `t = 10 s`, `deferred_probe_timeout_work_func()` (`dd.c:301-317`) calls `fw_devlink_drivers_done()` (`core.c:1823-1840`). Because `54040000.dpaux` has no matching driver registered yet (`!dev_can_match(dev)`), `fw_devlink_relax_Cycle()` relaxes the link to `DL_FLAG_SYNC_STATE_ONLY` (`core.c:1809-1821`) and triggers a deferred-probe retry.
  4. On that retry, `really_probe()` calls `pinctrl_bind_pins()` (`dd.c:684`) -> `devm_pinctrl_get()` -> `create_pinctrl()` -> `dt_to_map_one_config()` (`drivers/pinctrl/devicetree.c:112-145`). Because the pinctrl supplier `54040000.dpaux` is still unregistered (`ret = -ENODEV`), line 139 checks:
     ```c
     if (IS_ENABLED(CONFIG_MODULES) && !allow_default && ret < 0)
         ret = -EPROBE_DEFER;
     ```
     Unlike regulator/clock helpers that call `driver_deferred_probe_check_state()`, `pinctrl` unconditionally returns `-EPROBE_DEFER` when `CONFIG_MODULES=y`. Therefore, `7000c700.i2c` **does not fail with `-ETIMEDOUT`** after 10 seconds; it stays on `deferred_probe_pending_list` until `tegra_drm` is loaded.

- **When `modprobe tegra_drm` runs:**
  1. `host1x_drm_init()` (`drivers/gpu/drm/tegra/drm.c:1427-1447`) registers `host1x_drm_driver` on the `host1x` bus and then calls `platform_register_drivers(drivers, ARRAY_SIZE(drivers))` (`drm.c:1435`).
  2. In `drivers[]` (`drm.c:1413-1425`), `tegra_dpaux_driver` (`drivers[4]`, line 1418) is registered **before** `tegra_sor_driver` (`drivers[5]`, line 1419).
  3. `tegra_dpaux_probe()` (`dpaux.c:538-555`) registers the `54040000.dpaux` pinctrl device (`devm_pinctrl_register()`). When `54040000.dpaux` finishes binding, `driver_bound()` (`dd.c:1164`) calls `driver_deferred_probe_trigger()`, queueing `deferred_probe_work` to probe `7000c700.i2c` (which applies `state_dpaux1_i2c` via `tegra_dpaux_pinctrl_set_mux()` at `dpaux.c:411-434` and registers the I2C adapter).
  4. Even if `tegra_sor_driver` (`drivers[5]`) runs `tegra_sor_probe()` (`sor.c:3809`) on the `modprobe` CPU before `deferred_probe_work` finishes probing `7000c700.i2c`, `tegra_output_probe()` (`drivers/gpu/drm/tegra/output.c:127-135`) sees `of_get_i2c_adapter_by_node(ddc) == NULL` and returns `-EPROBE_DEFER`, placing `54580000.sor` on `deferred_probe_pending_list`.
  5. As soon as `7000c700.i2c` finishes binding, its `driver_bound()` calls `driver_deferred_probe_trigger()` again, which re-probes `54580000.sor`. `tegra_output_probe()` gets the I2C4 DDC adapter, `tegra_sor_probe()` calls `host1x_client_register(&sor->client)` (`sor.c:3989`), and `host1x_subdev_register()` (`drivers/gpu/host1x/bus.c:267-291`) sees the `subdevs` list empty (`dc@54200000`, `dc@54240000`, `vic@54340000`, `nvjpg@54380000`, `nvdec@54480000`, `sor@54580000` all registered) and calls `device_add(&device->dev)` -> `host1x_drm_probe()`. The probe order is completely safe.

---

## 4. `vdd_hdmi`: probe glitch on CC7 or unexpected disable?

- **Probe does NOT glitch CC7:**
  - `vdd_hdmi` (`tegra210-p2894.dtsi:1810-1820`) has `regulator-boot-on;`.
  - In `reg_fixed_voltage_probe()` (`drivers/regulator/fixed.c:191-192, 295-298, 317`), `init_data->constraints.boot_on` sets `config->enabled_at_boot = true`, so it requests CC7 with `gflags = GPIOD_OUT_HIGH | GPIOD_FLAGS_BIT_NONEXCLUSIVE`.
  - `tegra_gpio_direction_output()` (`drivers/gpio/gpio-tegra.c:182-193`) calls `tegra_gpio_set(chip, offset, 1)` (`GPIO_MSK_OUT`) **before** setting `GPIO_MSK_OE` and `GPIO_MSK_CNF`, and CC7 is already output high (`OUT = 0x90`, `OE = 0xb0`, `CNF = 0xb2`).

- **No other consumer references `vdd_hdmi`, BUT `regulator_late_cleanup()` WILL turn `vdd_hdmi` OFF 30 seconds after boot if `tegra_drm` is still unloaded:**
  - `vdd_hdmi` in `tegra210-p2894.dtsi:1810-1820` has `regulator-boot-on;`, **not** `regulator-always-on;`.
  - In `of_get_regulation_constraints()` (`drivers/regulator/of_regulator.c:131-134`), `!constraints->always_on` sets `constraints->valid_ops_mask |= REGULATOR_CHANGE_STATUS`.
  - In `set_machine_constraints()` (`drivers/regulator/core.c:1665-1698`), `boot_on` enables `rdev` (`rdev->ena_gpio_state = 1`), but only `always_on` increments `rdev->use_count` (`if (rdev->constraints->always_on) rdev->use_count++;` at `core.c:1696-1697`). Thus `vdd_hdmi` sits at `use_count == 0` while `tegra_drm` is blacklisted.
  - `regulator_init_complete()` (`core.c:6881-6909`) sets `has_full_constraints = true` and queues `regulator_init_complete_work` for **30,000 ms (30 s)** after `late_initcall_sync` (unless `regulator_ignore_unused` is on the kernel command line; `darcy-system.dts:26` only has `clk_ignore_unused`).
  - At `t = 30 s`, `regulator_late_cleanup()` (`core.c:6806-6848`) sees `!c->always_on`, `REGULATOR_CHANGE_STATUS`, `rdev->use_count == 0`, and `_regulator_is_enabled(rdev) == 1` (`core.c:3476-3480`), logs `VDD_HDMI_5V0: disabling`, and calls `_regulator_do_disable(rdev)` (`core.c:6832` -> `3226-3238` -> `2944-2950`), **driving GPIO CC7 LOW**.
  - **Impact:**
    1. At `t = 30 s` (before `modprobe tegra_drm`), dropping +5V on the HDMI connector deasserts HPD (which the sink pulls up from +5V) and may cause the TV to drop the `simpledrm` picture.
    2. When `modprobe tegra_drm` runs after `t = 30 s`, `tegra_sor_hdmi_probe()` (`sor.c:3023`) calls `tegra_sor_enable_regulator(sor, sor->hdmi_supply)`, driving CC7 high again — **with `startup-delay-us = 0`** (`tegra210-p2894.dtsi:1810-1820` lacks the `startup-delay-us = <5000>;` present in stock `tegra210-ers-fixed-e2174-1101-a00.dtsi:111`). If the TV takes several milliseconds after +5V rises to assert HPD (CC1), `tegra_output_connector_detect()` (`output.c:41-52`) during `drm_client_setup()` could briefly see `connector_status_disconnected` until the HPD interrupt fires.
  - **Recommendation:** Add `regulator-always-on;` (and `startup-delay-us = <5000>;`) to `vdd_hdmi` in `kernel/dts/darcy.dts`.

---

## 5. Drive current (`SOR_LANE_DRIVE_CURRENT0`)

- Comparing `tegra210_sor_hdmi_defaults[]` (`drivers/gpu/drm/tegra/sor.c:92-105`, `#if 1` branch, `frequency = 150000000`) with cboot's live registers and stock `vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-prods.dtsi:58-66` (`prod_c_hdmi_75m_150m`):
  - Every PLL and pad calibration field (`vcocap = 0x3`, `filter = 0x0`, `ichpmp = 0x1`, `loadadj = 0x3`, `tmds_termadj = 0x9`, `tx_pu_value = 0x66`, `bg_temp_coef = 0x3`, `bg_vref_level = 0x8`, `avdd10_level = 0x4`, `avdd14_level = 0x4`, `sparepll = 0x0`, `preemphasis = {0, 0, 0, 0}`) is **bit-for-bit identical**.
  - Only `drive_current` (`SOR_LANE_DRIVE_CURRENT0`, written at `sor.c:2526-2530`) differs: mainline writes `{0x33, 0x3a, 0x3a, 0x3a}` (`0x3a3a3a33`: lane 0 = 51, lanes 1–3 = 58), whereas cboot/darcy uses `{0x30, 0x30, 0x30, 0x2d}` (`0x2d303030`: lanes 0–2 = 48, lane 3 = 45).
  - Note that darcy's own base `prod` node in `tegra210-darcy-prods.dtsi:33` specifies `0x3c3c3c3c` (60 per lane), so `0x33`/`0x3a` is well within safe hardware limits.
  - **Assessment (physical-layer judgment):** At 1080p60 (`148.5 MHz` TMDS clock, 1.485 Gbps/lane, zero pre-emphasis), the ~15–20% higher drive current is not a meaningful risk to getting a first picture and does **not** need to be patched into `sor.c` before the first test.

---

## 6. `video=HDMI-A-1:1920x1080@60`: connector name, fbdev handling, and pinning 1080p

- **Connector name is `HDMI-A-1`:**
  - In `tegra_sor_init()` (`drivers/gpu/drm/tegra/sor.c:3097-3115`), `sor->soc->supports_hdmi` (`tegra210_sor1`, `sor.c:3526`) selects `DRM_MODE_CONNECTOR_HDMIA`.
  - `tegra_output_init()` (`drivers/gpu/drm/tegra/output.c:195-199`) -> `drm_connector_init_only()` (`drivers/gpu/drm/drm_connector.c:260-270`) names the connector `"%s-%d"` using `drm_connector_enum_list[DRM_MODE_CONNECTOR_HDMIA].name` (`"HDMI-A"`, `drm_connector.c:93`) and per-type `connector_ida` starting at `1`. (`simpledrm` uses `DRM_MODE_CONNECTOR_Unknown` `"Unknown-1"`, which uses a separate IDA at `drm_connector.c:89`, and is removed before `tegra_sor_init()` runs anyway.)

- **fbdev honours `video=HDMI-A-1:1920x1080@60`:**
  - `drm_connector_init_only()` calls `drm_connector_get_cmdline_mode(connector)` (`drm_connector.c:295` -> `drivers/gpu/drm/drm_client_modeset.c:109-148`), which calls `fb_get_options("HDMI-A-1", &option)` and parses `1920x1080@60` into `connector->cmdline_mode`.
  - In `host1x_drm_probe()` (`drivers/gpu/drm/tegra/drm.c:1256, 1275`), `drm_mode_config_reset(drm)` clears initial CRTC routing, and `drm_client_setup(drm, NULL)` runs `drm_client_modeset_probe()` (`drm_client_modeset.c:817-944`).
  - `drm_client_firmware_config()` returns `false` (`drm_client_modeset.c:694, 791-795`), and `drm_client_target_preferred()` (`drm_client_modeset.c:473-481`) calls `drm_connector_pick_cmdline_mode(connector)` **before** `drm_connector_preferred_mode()`, selecting the EDID's `1920x1080@60` mode (`drm_client_modeset.c:201-220`).

- **Pinning 1080p for the first test is wise:**
  1. On a 4K60 TV, the EDID preferred mode is `3840x2160@60` (`594 MHz`). At `mode->clock >= 340000`, `tegra_sor_hdmi_enable()` (`sor.c:2346-2352, 2429-2430, 2658` -> `tegra_sor_hdmi_scdc_start()` at `sor.c:2195-2207`) switches to HDMI 2.0 5.4 GHz link speed, divides the clock by 2, and initiates SCDC scrambling over I2C4 (`drm_scdc_set_high_tmds_clock_ratio`, `drm_scdc_set_scrambling`). Pinning 1080p60 (`148.5 MHz`) avoids HDMI 2.0 SCDC and 6 Gbps PHY variables on the first test.
  2. It uses the exact same `150 MHz` entry in `tegra210_sor_hdmi_defaults` (`sor.c:92-105`) as cboot's `1080p59.94` (`148.35 MHz`), making the debugfs register comparison direct.
  3. It keeps display memory read bandwidth low (~500 MB/s vs ~2 GB/s at 4K60) while EMC scaling is not yet active.

---

## 7. `modprobe.d` `blacklist tegra_drm`

- **Confirmed:**
  - In `libkmod`, `blacklist <modulename>` in `/etc/modprobe.d/*.conf` only suppresses a module when resolving **aliases** (`KMOD_PROBE_APPLY_BLACKLIST`).
  - `systemd-udevd`'s builtin `kmod` loader passes `KMOD_PROBE_APPLY_BLACKLIST` when loading `MODALIAS` matches (`of:NdcT...Cnvidia,tegra210-dc`, `of:NsorT...Cnvidia,tegra210-sor1`, `of:NdpauxT...Cnvidia,tegra210-dpaux`), so udev will not load `tegra_drm` at boot.
  - Running `modprobe tegra_drm` by module name (without `-b`) ignores `blacklist` for the explicitly named module (whereas kernel command-line `module_blacklist=tegra_drm` enforces a kernel-side check in `kernel/module/main.c` that rejects `finit_module` even for manual `modprobe`).
  - No other module depends on symbols exported by `tegra_drm`.

---

## 8. Anything that can make this test unrecoverable without the TV?

**No.** Every potential failure mode either leaves SSH alive or triggers an automatic reset (`panic=10` or `tegra_wdt` at 60 s) back to U-Boot:

- **No unclocked or reset-asserted MMIO accesses (which would cause an SError/bus abort):**
  - `tegra_dpaux_probe()` (`dpaux.c:513`) calls `pm_runtime_get_sync()` (enabling `pll_dp` and `dpaux1` and deasserting `dpaux` reset) before its first MMIO read/write (`dpaux.c:519`).
  - `tegra_dc_probe()` (`dc.c:3275-3404`) does not touch DC registers; `tegra_dc_init()` (`dc.c:2743`) and `tegra_crtc_atomic_enable()` (`dc.c:2185`) call `pm_runtime_resume_and_get()` -> `tegra_dc_runtime_resume()` (`dc.c:2890-2924`, powering up `DIS`/`DISB`, enabling `dc->clk`, and deasserting `dc->rst`) before touching DC registers.
  - `tegra_sor_probe()` (`sor.c:3744-4003`) and `tegra_sor_init()` (`sor.c:3097-3220`) do not touch SOR registers; `tegra_sor_hdmi_enable()` (`sor.c:2268`) calls `host1x_client_resume(&sor->client)` -> `tegra_sor_runtime_resume()` (`sor.c:3264-3298`, enabling `sor->clk` and deasserting `sor->rst`) before touching SOR registers.
  - `vic_probe()` / `vic_init()` (`vic.c:118-164, 448-540`), `nvdec_probe()` / `nvdec_init()` (`nvdec.c:152-198, 422-543`), and `nvjpg_probe()` / `nvjpg_init()` (`nvjpg.c:97-125, 233-303`) do not touch hardware registers at probe/init time.
  - Even if an unexpected SError or kernel panic occurred, `panic=10` (`darcy-system.dts:26`) and `tegra_wdt` (60 s hardware watchdog) reset the SoC into U-Boot.

- **Unbounded polling loops in `sor.c` sleep (`usleep_range`), so they cannot lock out SSH or `systemd`:**
  - `tegra_sor_hdmi_enable()` has two `while (true)` loops polling `SOR_LANE_SEQ_CTL` (`sor.c:2322-2340`). Both call `usleep_range(250, 1000)` on every iteration. All other wait loops (`tegra_sor_power_up()` at `sor.c:1053-1072`, `tegra_sor_attach()` at `sor.c:1003-1031`, `tegra_sor_wakeup()` at `sor.c:1033-1051`, `tegra_sor_detach()` at `sor.c:1378-1425`) have a 250 ms `jiffies` timeout. Even if `SOR_LANE_SEQ_CTL` never cleared, only the `modprobe` task would sleep while SSH and `systemd` remain completely responsive.

- **No shared resources with Wi-Fi (PCIe) or rootfs (USB SSD):**
  - `dc`, `sor1`, `dpaux1`, and `i2c4` do not share clocks, resets, or regulators (`ldo8`, `sd3`, `vdd_hdmi`) with `pcie@1003000` or `usb@70090000`.

---

## 9. Anything missing in `darcy.dts` compared to Jetson TX1 / Nano?

Checking each item in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi` and the Jetson DTs (`tegra210-p2597.dtsi`, `tegra210-p3450-0000.dts`):

| Item | Status in `tegra210.dtsi` + `darcy.dts` (`hdmi-drm.diff`) | Needed for HDMI on SOR1? |
|---|---|---|
| **SOR1 `clocks` / `clock-names`** | Inherited from `tegra210.dtsi:340-345`: `"sor"` (`SOR1`), `"out"` (`SOR1_OUT`), `"parent"` (`PLL_D2_OUT0`), `"dp"` (`PLL_DP`), `"safe"` (`SOR_SAFE`). Matches `tegra_sor_probe()` (`sor.c:3862-3915`). | **Present & complete.** (`"pad"` is optional on T210; `sor.c:3920-3933, 3960-3975` registers `"sor1_pad_clkout"` internally.) |
| **`assigned-clocks`** | Neither Jetson TX1 (`tegra210-p2597.dtsi`) nor Nano (`tegra210-p3450-0000.dts`) sets `assigned-clocks` on `sor1` or `dc`. `tegra_sor_probe()` (`sor.c:3940`) reparents `sor1_out` to `sor_safe`, and `tegra_sor_hdmi_enable()` (`sor.c:2275, 2411, 2419`) programs `sor_safe` -> `sor1_pad_clkout` -> `pll_d2_out0` at modeset time. | **Not needed.** |
| **DC `nvidia,head` & `nvidia,outputs`** | Inherited from `tegra210.dtsi:203-204, 218-219`: `dc@54200000` has `nvidia,head = <0>` and `nvidia,outputs = <&dsia &dsib &sor0 &sor1>`; `dc@54240000` has `nvidia,head = <1>` and the same `nvidia,outputs`. | **Present & complete.** |
| **`nvidia,xbar-cfg`** | Omitted in `darcy.dts`, so `tegra_sor_parse_dt()` (`sor.c:3701-3705`) falls back to `tegra210_sor_xbar_cfg` = `{2, 1, 0, 3, 4}` (`sor.c:3498-3500`), which matches cboot's `SOR_XBAR_CTRL = 0x8d111828`. | **Present & matches cboot.** |
| **VIC (`vic@54340000`), NVJPG, NVDEC** | Enabled by default in `tegra210.dtsi:240-293` with `power-domains = <&pd_vic>`, `<&pd_nvjpg>`, `<&pd_nvdec>` (which `darcy.dts` kept). All three probed and registered with `host1x` on First Boot (`NOTES.md:721`), and `/lib/firmware/nvidia/tegra210/vic04_ucode.bin` is present. | **Present & complete.** |
| **SMMU (`iommus`)** | Inherited from `tegra210.dtsi:179, 201, 216, 249, 261, 291`: `host1x`, `dc@54200000` (`TEGRA_SWGROUP_DC`), `dc@54240000` (`TEGRA_SWGROUP_DCB`), `vic`, `nvjpg`, and `nvdec` all have `iommus = <&mc ...>`. `host1x_drm_probe()` (`drm.c:1185-1208`) attaches all clients to a shared IOMMU group/domain and allocates fbdev BOs via `tegra_bo_alloc()` (`drm.c:1244`). | **Present & complete.** |
| **`vdd_hdmi` `regulator-always-on` & `startup-delay-us`** | `tegra210-p2894.dtsi:1810-1820` has `regulator-boot-on` (no `regulator-always-on`, no `startup-delay-us`). Stock `tegra210-ers-fixed-e2174-1101-a00.dtsi:111` has `startup-delay-us = <5000>;`. | **Add `regulator-always-on;` and `startup-delay-us = <5000>;` to `&vdd_hdmi` in `darcy.dts` (see Question 4).** |
