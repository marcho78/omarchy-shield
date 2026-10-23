# Plan 2 review: CPU power management, GPU test, and desktop

## Bottom line

The overall direction is sound, but I would change two parts before implementation:

1. **Do not make all four CPU nodes cooling devices.** Tegra210 has one shared cpufreq policy. The cpufreq core registers one cooling device from `policy->cpu`—CPU0—not one per logical CPU (`drivers/cpufreq/cpufreq.c:1621-1623`, `drivers/thermal/cpufreq_cooling.c:648-668`). Put `#cooling-cells = <2>` on `cpu@0` only and reference that one phandle from both thermal zones.
2. **Do not raise the DFLL cap to 2.0145 GHz before kernel thermal cooling exists.** The safer sequence is A1 → A4 → A2 at the low cap → A3 → extended load/thermal validation → raise the cap.

For the desktop, the underlying Tegra-KMS/nouveau-render design is supported by Mesa. The most likely bring-up problem is **Aquamarine opening the wrong primary DRM node, or receiving `AQ_DRM_DEVICES` too late**, not a fundamental inability to share buffers.

## Ranked findings

### High — A3 describes the wrong CPU cooling topology

`cpufreq-dt` marks itself as a cooling driver (`drivers/cpufreq/cpufreq-dt.c:140-153`), but the cpufreq core registers cooling once per *policy* (`drivers/cpufreq/cpufreq.c:1621-1623`). `of_cpufreq_cooling_register()` looks only at `of_get_cpu_node(policy->cpu)` (`drivers/thermal/cpufreq_cooling.c:648-662`). With Tegra's shared policy, that is CPU0.

Use one provider and one map entry per trip, for example conceptually:

```dts
&{/cpus/cpu@0} {
        #cooling-cells = <2>;
};

cooling-device = <&{/cpus/cpu@0} THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
```

Adding `#cooling-cells` to CPU1–3 does not create three additional cpufreq cooling devices; maps to those phandles will remain unbound. The one CPU0 cooling device caps the policy shared by CPUs 0–3.

### High — `mem-thermal` needs passive polling for step-wise CPU cooling

`mem-thermal` currently has `polling-delay-passive = <0>` (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:2133-2135`). The step-wise governor changes a cooling target one step per zone update (`drivers/thermal/gov_step_wise.c:79-143`), and the thermal core schedules passive polling only when `passive_delay_jiffies` is nonzero (`drivers/thermal/thermal_core.c:291-294`). An interrupt at 85 °C may therefore apply one step and then not progress while temperature stays above the trip.

If CPU cooling is mapped from `mem-thermal`, override `polling-delay-passive = <1000>` there. CPU thermal already uses 1000 ms (`tegra210.dtsi:2103-2106`).

### High — real Omarchy install currently misclassifies darcy

Darcy falls through to `generic-aarch64` because `omarchy-hw-platform` recognizes only Apple and Raspberry Pi compatibles (`vendor/omarchy-arm/bin/omarchy-hw-platform:18-57`). That causes the ARM Vulkan leaf to offer `vulkan-virtio` and `vulkan-swrast` (`install/hardware/arm/vulkan.sh:9-21`). This is wrong for Tegra, even if it is not itself destructive. Add the Tegra platform before a real install; use the dry run to verify the package plan.

### Medium — B2 should follow, not precede, a manual Hyprland proof

Keep nouveau blocked at boot while doing B1 and the first plain Hyprland launch: load it manually with the rollback/reboot protection already used successfully. Only remove `install nouveau /bin/true` after Hyprland has produced stable frames. This retains a known-good text/SSH boot if compositor startup triggers a GPU or buffer-sharing fault.

### Medium — never persist `/dev/dri/card1`

DRM minors are probe-order dependent and may change when nouveau is enabled at boot. Use `card1` only for the immediate measured test. Persist a verified `/dev/dri/by-path/...-card` path, or create a no-colon udev symlink such as `/dev/dri/tegra-kms`. **UNCERTAIN:** the exact by-path name on this DT; inspect it on the board.

Aquamarine 0.15.1 splits `AQ_DRM_DEVICES` on `:` before canonicalizing paths (`src/backend/drm/DRM.cpp:184-221`), so a platform symlink containing a colon is unsuitable. A custom no-colon symlink avoids that parser ambiguity.

## Part A

### A1: cpuidle

Removing `cpuidle.off=1` remains low-risk. The DT enables `cpu-sleep` for P2894 (`tegra210-p2894.dtsi:1614-1617`), and the state is PSCI state `0x40000007` with finite latency/residency (`tegra210.dtsi:2057-2069`). The measured always-on Tegra timer clockevents and broadcast timer remove the main timer concern. Validate all four CPUs accumulate `cpu-sleep` residency, then idle and load/idle cycles, warm reboot, and absence of RCU stalls.

### A2.1: hard cap versus governor

The kernel-table cap is the right first-boot safety control. The DFLL probe copies `tegra210_cpu_max_freq_table[speedo_id]` into `soc->max_freq` and passes it to the dynamic OPP builder (`drivers/clk/tegra/clk-tegra124-dfll-fcpu.c:696-701`). The builder stops at the first entry above that maximum (`drivers/clk/tegra/cvb.c:55-79`). Nothing else is needed to exclude higher OPPs.

One correction: a cap of 1,036,800,000 Hz produces a highest OPP of **1,020,000,000 Hz**, because the mainline CVB table jumps from 1.020 GHz to 1.122 GHz (`clk-tegra124-dfll-fcpu.c:193-203`). I would patch the value to 1,020,000,000 explicitly so logs and expectations match. The later 2,014,500,000 entry exists exactly (`clk-tegra124-dfll-fcpu.c:209-213`).

A governor is useful as an additional bring-up choice, not as the safety boundary. It does not remove high OPPs, and the Tegra wrapper switches the CPU clock to the DFLL before registering `cpufreq-dt` (`drivers/cpufreq/tegra124-cpufreq.c:31-49,97-105`). `powersave` is also a module in this configuration, whereas userspace is built in (`arch/arm64/configs/defconfig:96-101`).

The speedo-table edit affects every speedo-ID-2 Tegra210 built from this kernel. That is acceptable for a private bring-up kernel; a board-specific maximum is cleaner long-term.

### A2.2: DFLL node completeness

The proposed node is complete for mainline if it contains all Nano properties at `tegra210-p3450-0000.dts:594-613`. The base node already supplies registers, interrupt, clocks, resets, `#clock-cells`, and `clock-output-names` (`tegra210.dtsi:1424-1441`). The PWM voltage parameters match stock darcy exactly; the two extra downstream flags are not mainline bindings (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-p2530-common.dtsi:54-72`). Do not copy `nvidia,idle-override` or `nvidia,one-shot-calibrate` into mainline.

Because P2894 names its controller state `boot`, not `default` (`tegra210-p2894.dtsi:24-29`), explicitly set the active and inactive subnodes to function `cldvfs`. I would copy the complete known PBB1 electrical tuple from the P2894 boot state—function, no pull, input disabled, open-drain disabled—and vary only tristate (`tegra210-p2894.dtsi:1110-1117`). Relying on cboot's residual mux state is unnecessary.

Success checks:

- The former `cpufreq-tegra124` `-2` failure disappears. Successful DFLL/cpufreq probing may otherwise be quiet; do not require an invented success string.
- `/sys/devices/system/cpu/cpufreq/policy0/` exists; `scaling_driver` is `cpufreq-dt`; `affected_cpus`/`related_cpus` cover 0–3; available frequencies end at 1.020 GHz for the validation kernel.
- `clk_summary` shows `cclk_g` parented to `dfllCPU_out`, not `pll_x` or the temporary PLLP parent. This matters because both `clk_set_parent()` return values in the initial switch are ignored (`tegra124-cpufreq.c:40-48`).
- With debugfs mounted, `/sys/kernel/debug/tegra_dfll_fcpu/enable`, `lock`, and `rate` exist (`drivers/clk/tegra/clk-dfll.c:1363-1377`). After cpufreq is active, expect `enable=1`, `lock=1`, and a nonzero monitored rate that changes with requested frequency (`clk-dfll.c:1274-1322`).
- The active PBB1 state is no longer tristated. **UNCERTAIN:** Linux has no direct measurement of the CPU rail here; a correct clock tree does not prove the external PWM voltage. The measured pad/register state or an electrical measurement is the proof.

### A3: trip and map details

CPU passive at 82 °C, guard cap at 86 °C, and warm reboot at 92 °C form sensible layers. At 85 °C the existing fan map already selects state 5, approximately 94%, while state 6/full is at 95 °C (`kernel/dts/darcy.dts:278-320`, cooling levels at `:235-243`). Thus rebooting at 92 °C does not deprive the board of much fan capacity.

Use 2–3 °C hysteresis for the new passive trips and unrestricted cooling bounds so step-wise can traverse the whole OPP table. One CPU0 cooling map may be referenced by both CPU and memory zones.

The existing EMC maps do not interfere. They bind only if the EMC driver reaches cooling-device registration (`drivers/memory/tegra/tegra210-emc-core.c:1966-1974`). It currently fails earlier without the nominal reserved-memory timing table (`tegra210-emc-core.c:1849-1854`), so those maps are dormant. They will become relevant automatically when EMC support is completed.

### A4 and final order

Install the guard before enabling DFLL, but make it tolerate absent `policy*` directories so it still monitors temperatures when cpufreq has not probed. Monitor the maximum of CPU, GPU, and memory zones by their `type`, not by unstable thermal-zone numbers. At 86 °C, write each existing policy's `cpuinfo_min_freq` to `scaling_max_freq` and latch that cap until reboot. At 92 °C, request a systemd reboot. The guard should run as root, restart on failure, and log every transition.

Recommended order:

1. A1; validate idle and warm reboot.
2. A4; deliberately test its parsing/cap path at harmless temporary thresholds.
3. A2 at a 1.020 GHz hard maximum; verify clock parent, debugfs lock/rate, OPPs, load/idle, and reboot.
4. A3 with CPU0-only cooling plus a 1000 ms memory passive delay; verify cooling state and `scaling_max_freq` under controlled heating.
5. Only then raise the hard maximum to 2.0145 GHz and repeat thermal/load validation.

The userspace guard cannot protect a hang before PID 1, which is why the low kernel cap and existing hardware throttle remain necessary.

## Part B

### B1/B3: whether the KMS/render split should work

The architecture is legitimate:

- Tegra DRM exposes modeset, atomic, render, PRIME import, and syncobj support (`drivers/gpu/drm/tegra/drm.c:882-900`). Tegra210 planes advertise linear and NVIDIA block-linear modifiers (`drivers/gpu/drm/tegra/dc.c:706-714,3034-3050`), and it has an atomic cursor plane (`dc.c:957-1000,1203-1255`).
- Mesa's Tegra Gallium driver is specifically a wrapper: when opened on the Tegra DRM fd it opens a platform `nouveau` render node and constructs the nouveau screen ([Mesa 26.2.5 `tegra_screen.c:522-550`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/tegra/tegra_screen.c#L522-550)). For scanout it exports the nouveau allocation and imports it into Tegra DRM (`tegra_screen.c:131-164,167-205`). This is exactly the desired split.
- Aquamarine 0.15.1 enumerates KMS primary nodes and resolves the render node with the same udev parent ([`DRM.cpp:113-232`](https://github.com/hyprwm/aquamarine/blob/v0.15.1/src/backend/drm/DRM.cpp#L113-L232), [`Session.cpp:163-265`](https://github.com/hyprwm/aquamarine/blob/v0.15.1/src/backend/Session.cpp#L163-L265)). **UNCERTAIN:** the observed Tegra card/render-node udev parent relationship has not yet been recorded, although normal DRM registration should give them the same parent.

Therefore start with only the Tegra KMS card in the process environment:

```text
AQ_DRM_DEVICES=/dev/dri/tegra-kms
```

Do **not** add the nouveau card to that list and do not set `DRI_PRIME`, `GBM_BACKEND`, or `MESA_LOADER_DRIVER_OVERRIDE`. Mesa's Tegra driver must perform the render-node selection internally. `AQ_DRM_DEVICES` is a list of KMS devices, first one primary; it is not a way to name a separate render-only GPU ([Aquamarine `docs/env.md:4-9`](https://github.com/hyprwm/aquamarine/blob/v0.15.1/docs/env.md#L4-L9)).

For B1, the proposed glmark winsys option selecting the measured Tegra card is the right discriminator. Require both a visible animation and `GL_RENDERER` identifying NV12B/nouveau. Run it from the active local VT (or otherwise through a valid logind/seatd seat); an SSH process may lack DRM-master access even if it can open the render node.

**UNCERTAIN:** I found no source proving Hyprland 0.56.2 plus Aquamarine 0.15.1 has been exercised specifically on Tegra210. The kernel/Mesa path is purpose-built for it, but the compositor result still needs B1 and a plain-session proof.

### Modifiers, explicit sync, cursor, and atomic

Start with defaults. The Tegra wrapper deliberately chooses linear scanout when an application does not negotiate modifiers (`Mesa tegra_screen.c:180-205`), while both kernel sides advertise compatible NVIDIA block-linear layouts. If logs show GBM allocation, PRIME import, or `ADDFB2` failures, try `AQ_NO_MODIFIERS=1` as a single diagnostic change; do not make it permanent without evidence.

`AQ_MGPU_NO_EXPLICIT=1` is only a later diagnostic for explicit-sync failures. Aquamarine should see one KMS backend here, while Mesa hides the render split internally, so its multi-GPU path ideally is not involved.

Keep atomic enabled. Tegra explicitly advertises it. `AQ_NO_ATOMIC=1` would be a fallback only after an atomic-commit error, and it may hide the real plane/buffer issue.

Keep hardware cursors initially. Tegra210 supports them, but only linear square buffers of 32/64/128/256 pixels (`drivers/gpu/drm/tegra/dc.c:957-1000,1203-1248`). If the desktop appears but the pointer is absent/corrupt or logs cursor-blit failures, use Hyprland's `cursor:no_hardware_cursors = true`; this is a compositor option, not an `AQ_*` variable.

Use either logind (preferred with SDDM) or seatd, not both. An active logind session receives device ACLs; static `video`/`render` membership is mainly needed for non-seat tests. Verify the user can open both the Tegra card and nouveau render node before interpreting an EGL failure as a driver failure.

### Corrected B order

1. B1: manual nouveau load, stable Tegra KMS path, visible glmark test, rollback/watchdog armed.
2. B3: the same manual module state, plain Hyprland from an active VT with `AQ_DRM_DEVICES` exported **before process startup**. Capture Aquamarine/Hyprland logs over SSH.
3. B2: only after a repeatable plain desktop, remove the boot block and reboot-test.
4. B4: adapt platform detection, inspect `install.sh --dry-run`, then install Omarchy and enable SDDM last.

### Omarchy files that need Tegra work

- `bin/omarchy-hw-platform:18-57`: recognize root compatible `nvidia,darcy` (and optionally the precise P2894 compatible) before generic fallback.
- `install.sh:61-63,185-209`: add the new profile to help and accepted platform cases.
- `test/shell.d/arm64-platform-test.sh:12-53`: add a NUL-separated darcy compatible fixture and expected result.
- `install/hardware/arm/vulkan.sh:9-21`: add the Tegra case. Select **none initially**. Hyprland requires GLES, not Vulkan. Mesa documents NVK support for Kepler and later, but **UNCERTAIN:** GM20B/Tegra's NVK path on this exact kernel/userspace is not yet validated. Add `vulkan-nouveau` only after `vulkaninfo` succeeds independently.
- Add an `install/hardware/arm/tegra.sh` leaf and wire it beside the other ARM leaves in `install/hardware/all.sh:18-23`; extend `test/shell.d/arm64-gating-test.sh:41-46`. It can install the stable DRM symlink/environment and platform state, but should not edit this project's kernel, initramfs, bootloader, or nouveau rollback policy.
- `default/hypr/platform.lua:15-20` plus a new Tegra profile: use the Pi-style low-cost defaults (animations, blur, shadow off) for 3 GB RAM/limited bandwidth. Add the corresponding assertion near `test/shell.d/arm64-gating-test.sh:156-169`.
- Put `AQ_DRM_DEVICES` in UWSM's pre-launch environment, not merely a late Hyprland config (`default/uwsm/env.d/10-omarchy:1-19`). SDDM's greeter is a separate Hyprland process (`etc/sddm.conf.d/10-wayland.conf:1-5`) and also needs the selection before launch. A Tegra-only SDDM drop-in or wrapper is safer than a global setting. **UNCERTAIN:** whether this SDDM build imports a proposed environment.d value before starting its Wayland compositor; verify its process environment rather than assume.
- Update `docs/arm64-port.md:224-236` and platform tests. `install/arm/settings.sh` already deliberately avoids ARM boot-chain files (`install/arm/settings.sh:11-21`) and does not need Tegra boot logic.

One dry-run caveat: the script promises no changes, but when no AUR helper exists it still creates and removes a temporary directory outside `run()` (`install.sh:100-113`), because required AUR packages invoke that helper even in a default dry run (`install.sh:299-312`). It makes no persistent system change, but the claim at `install.sh:211` is not literally true.

### Hang and thermal watch list

Do all B steps only after Part A's CPU cooling and guard are validated. Nouveau has no Tegra runtime-PM path here, so its 838 mV rail and added idle power persist. The fan now makes that manageable, but a compositor plus Quickshell is a continuous GPU workload.

During B1/B3, watch and persist:

- CPU, GPU, and memory temperature; fan state/RPM; VDD_SYS power.
- `nouveau` FIFO faults, GR traps, timeouts, and recovery messages.
- SMMU/IOMMU faults and Tegra DRM `failed to map plane`, framebuffer-import, atomic-check/commit, or page-flip errors.
- Hyprland/Aquamarine renderer choice, GBM device, modifier, cursor-blit, explicit-sync, and repeated frame/commit errors. Use `AQ_TRACE=1` only for a short reproduction because it is intentionally very verbose.
- RSS and log growth if an error repeats per frame.

Keep SSH, the hardware/system watchdog, ramoops, and a timed warm reboot available. Do not rely on the userspace thermal guard during a kernel bus lockup. If glmark or Hyprland hangs the GPU but SSH remains alive, collect logs before reboot; if the whole SoC stalls, the watchdog/ramoops path is the evidence source.
