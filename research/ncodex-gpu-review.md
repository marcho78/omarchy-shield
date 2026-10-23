# GM20B / nouveau review

## Bottom line

I see no hard blocker to a guarded first load. The DT is, electrically and
structurally, the upstream Jetson TX1 GPU supply transplanted onto a darcy board
whose downstream DT describes the same circuit. The two items worth resolving
before the test are:

1. **Medium: nouveau initially runs below its own SKU-specific `vmin`.** The
   PWM regulator starts at nominal 710 mV. For SKU 135 (`0x87`), mainline derives
   GPU speedo ID 1, whose nouveau floor is 840 mV
   (`drivers/soc/tegra/fuse/speedo-tegra210.c:89-97`;
   `drivers/gpu/drm/nouveau/nvkm/subdev/volt/gm20b.c:61-92`). The first register
   accesses are at 710 mV and the external `pll_ref` clock, and the initial
   76.8 MHz pstate can remain physically at 710 mV because nouveau rounds the
   reported 710 mV up to VID 0/840 mV. This is also the upstream TX1 software
   path, so it is probably intentional/safe at the lowest rate, but that last
   conclusion is **UNCERTAIN**.
2. **Medium operational hazard: quote the sysrq timer exactly.** An unquoted
   `>` is processed immediately by the SSH shell; passing `echo b > ...` as
   ordinary `systemd-run` arguments does not arrange a later redirection. Use
   the exact command under section 9.

One low-risk DT improvement is to add
`nvidia,open-drain = <TEGRA_PIN_DISABLE>` to the new PWM pin group. The current
live register is zero and the downstream darcy state omits the property, so its
absence is not a blocker, but mainline's existing p2894 `boot` state explicitly
disables open drain (`arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:881-888`).

## 1. Rail and PWM semantics

The proposed circuit is the right one with high confidence:

- Downstream darcy uses PWM channel 1, 8 us, 710000--1320000 uV, PMIC GPIO 6,
  and the same enable/settling delays
  (`vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`).
- Upstream P2180 uses the proposed node verbatim, including active-high PMIC
  GPIO 6 and ramp delay
  (`arch/arm64/boot/dts/nvidia/tegra210-p2180.dtsi:426-436`).
- Mainline continuous mode defaults to duty range `<0 100>` when no range is
  supplied (`Documentation/devicetree/bindings/regulator/pwm-regulator.yaml:26-36,60-81`),
  and the driver maps minimum voltage to 0% and maximum to 100%
  (`drivers/regulator/pwm-regulator.c:298-321,190-235`). The same-family CPU OVR
  table independently confirms increasing duty means increasing voltage: duty
  0 is 708 mV and duty 32 is 1322.4 mV
  (`.../tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:86-107`).
- GPIO flag 0 in the stock node and `GPIO_ACTIVE_HIGH` in the proposed node are
  equivalent. Mainline initially requests that GPIO output-low because the
  regulator is neither boot-on nor always-on
  (`drivers/regulator/pwm-regulator.c:392-401`).

Do **not** copy downstream `regulator-n-voltages` or
`regulator-init-microvolt`: neither is part of the mainline PWM-regulator
binding, and mainline selects table mode only from `voltage-table`; otherwise
it uses continuous mode (`pwm-regulator.yaml:34-36,83-87`;
`drivers/regulator/pwm-regulator.c:350-375`). `regulator_ignore_unused` really
is present in the current bootargs (`kernel/dts/darcy.dts:13-26`), but it does
not change the provider's deliberate GPIO-low initialization.

**UNCERTAIN:** there is no direct rail measurement, so absolute polarity still
rests on the two DTs and the CPU table rather than a scope reading. Those three
independent pieces make an inversion unlikely.

## 2. PWM pin and mux transition

Putting the state on the PWM controller as its `default` state is correct. The
device core selects `default` before the driver's probe when there is no `init`
state (`drivers/base/pinctrl.c:41-59`). `pwm-tegra` reselects it on runtime
resume and asks for `sleep` on suspend (`drivers/pwm/pwm-tegra.c:362-395`); a
missing sleep state is legal and becomes a no-op
(`drivers/pinctrl/core.c:1653-1665,1710-1716`), so the pin remains PWM1 while
the controller is clock-gated.

At the initial DISPLAYB-to-PWM1 transition, PMIC GPIO 6 is still low/off and
channel 1 CSR is zero. A disabled Tegra PWM is documented to drive its inactive
level (`drivers/pwm/pwm-tegra.c:27-34`), and the driver accepts only normal
polarity (`drivers/pwm/pwm-tegra.c:240-263`). Thus the intended transition is
off rail + low/minimum OVR input, not a high-voltage pulse. **UNCERTAIN:** the
pad's sub-cycle electrical level while the mux bits change cannot be proved
from software. Keeping the enable GPIO low makes such a transient harmless.

## 3. `GPU_RG_CNTRL` and the secure monitor

This risk is now substantially closed: the information in the brief is stale
relative to `NOTES.md`. The read-only probe has already returned SMC status 0
and value 1 (clamped) for `0x2d4` (`NOTES.md:1261-1269`); the probe issues the
same PMC-read SMC as Linux and performs no write
(`tools/pmc-read/pmc-read.c:25-42`).

The closest available T210 monitor source applies one shared offset blacklist
before both PMC reads and writes, and `0x2d4` is not blacklisted
([Lineage T210 TF-A `plat_sip_calls.c`:52-86](https://github.com/LineageOS/android_hardware_nvidia_arm-trusted-firmware/blob/lineage-24.0-t210/plat/nvidia/tegra/soc/t210/plat_sip_calls.c#L52-L86)).
Therefore the write is very likely accepted. **UNCERTAIN:** NVIDIA's stock
monitor is not byte-for-byte available, so a successful read does not formally
prove write permission.

If it refuses, Linux logs the SMC failure but `tegra_pmc_writel()` returns no
status and clamp removal still returns 0 (`drivers/soc/tegra/pmc.c:530-571,713-747`).
Nouveau then deasserts reset (`nvkm/engine/device/tegra.c:53-65`) and its first
GPU MMIO is the endianness read of register `0x4`
(`nvkm/engine/device/base.c:3110-3138`). **UNCERTAIN:** a still-clamped T210 GPU
may return zero/bogus data and fail softly as an unknown chipset, raise an
external-abort/SError, or stall the interconnect; the driver has no clamp
readback or timeout around that first read.

## 4. First voltage and clock

The precise sequence is:

1. Provider probe caches an 8 us, 0%-duty, disabled state. A disabled
   normal-polarity PWM is interpreted as 0%, hence 710 mV
   (`drivers/regulator/pwm-regulator.c:145-188`; `drivers/pwm/core.c:853-875`).
2. `regulator_enable()` drives GPIO 6 high, then enables PWM channel 1
   (`drivers/regulator/pwm-regulator.c:115-122`), and the regulator core waits
   the specified 2000 us before returning
   (`drivers/regulator/of_regulator.c:177-179`;
   `drivers/regulator/core.c:2985-3066`).
3. Nouveau enables `gpu`, `ref`, and `pwr`; only `pwr` is explicitly changed to
   204 MHz (`nvkm/engine/device/tegra.c:35-65`). The external `gpu` clock is a
   gate whose parent is `pll_ref` (`drivers/clk/tegra/clk-tegra-periph.c:772-807`),
   so the first access is at the live `pll_ref` rate, not 204 MHz. On T210 the
   supported oscillator inputs are 12 or 38.4 MHz
   (`drivers/clk/tegra/clk-tegra210.c:316-320`); check the pre-load
   `clk_summary` rather than assuming which one.
4. Later, GM20B clock init programs the lowest 76.8 MHz pstate
   (`nvkm/subdev/clk/gm20b.c:638-645,812-877`).

The subtlety is that `gk20a_volt_vid_get()` maps any actual voltage below VID 0
to VID 0 (`nvkm/subdev/volt/gk20a.c:93-104`), and `nvkm_volt_get()` then returns
that VID's table voltage (`nvkm/subdev/volt/base.c:31-47`). For this SKU, that
means physical 710 mV is reported internally as 840 mV; initial clock setup can
therefore leave pstate 0 at physical 710 mV. P2180 has the same regulator node
and driver sequence, though its individual speedo ID need not equal darcy's.

For a maximally conservative darcy-specific DT, one could represent the same
physical line only over the usable 840--1320 mV range with
`regulator-min-microvolt = <840000>`, `pwm-dutycycle-unit = <10000>`, and
`pwm-dutycycle-range = <2131 10000>`. The driver would cache ~21.31% duty before
enable, corresponding to `(840-710)/(1320-710)`, while preserving the physical
slope. That is logically sound from the mainline mapping code, but it departs
from the proven upstream TX1 DT and the exact analogue transfer remains
**UNCERTAIN** without measurement. I would not make it mandatory for the first
guarded test.

## 5. Speedo, voltage and clock tables

No additional DT OPP or speedo property is needed. T210 initializes GPU speedo
value from the fuse data and selects the ID from revision/SKU
(`drivers/soc/tegra/fuse/speedo-tegra210.c:128-193`); the existing SoC DTS
already supplies the T210 efuse device (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:1003-1010`).
Nouveau copies those values into its Tegra device before constructing GM20B
subdevices (`nvkm/engine/device/tegra.c:324-334`). The voltage constructor uses
only those values and `vdd` (`nvkm/subdev/volt/gk20a.c:146-171`). For noise-aware
PLL calibration it reads `FUSE_RESERVED_CALIB0`, and if calibration data is
absent it falls back to live calibration (`nvkm/subdev/clk/gm20b.c:933-977,743-805`).

## 6. Shared PWM clock and the LED

The clock gate affects the whole four-channel PWM block, not only channel 0.
However, in the measured state only channel 0 is enabled, so only the lightbar
has an active output to freeze. Runtime suspend merely gates the common clock
and selects sleep; it neither clears CSRs nor asserts reset
(`drivers/pwm/pwm-tegra.c:341-377`). Because the driver exposes no
`.get_state`, Linux also never imports cboot's channel-0 enabled state
(`drivers/pwm/pwm-tegra.c:266-268`; `drivers/pwm/core.c:986-1002`).

When GPU PWM1 is enabled, its runtime-PM reference brings the shared clock back
and PWM0 should resume; when PWM1 is disabled, the clock can stop again
(`drivers/pwm/pwm-tegra.c:211-238`). Channel 1 is safe while enabled because its
own reference holds the clock, and its separate enable GPIO turns the rail off
when disabled. **UNCERTAIN:** whether a clock-stopped PWM0 pad holds its last
counter level or is forced to another level is not specified by this driver;
that affects LED appearance, not GPU voltage.

## 7. WPR and other bootloader state

I found no additional darcy DT property consumed by the GM20B path. The
platform driver asks for the standard MMIO, clocks, reset, `vdd`, PMC and IOMMU
resources (`nvkm/engine/device/tegra.c:263-324`), all supplied by the existing
SoC node (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:440-456`).

The bootloader-specific prerequisite is the WPR bounds. Nouveau writes selector
2/3 and reads them from GPU register `0x100cd4`
(`nvkm/subdev/acr/gm200.c:52-62`), checks that the region is large enough, and
otherwise fails with `-ENOSPC` (`nvkm/subdev/acr/gm20b.c:32-46`). Tegra then
allocates the ucode blob from ordinary instance/system memory; with an IOMMU,
the instmem code allocates pages and maps them into GPU address space
(`nvkm/subdev/instmem/gk20a.c:421-495,591-604`). GM20B's FB path has no VPR
scrubber or VRAM allocator (`nvkm/subdev/fb/gm20b.c:25-40`). Thus I see no
nouveau requirement for a DT MC carveout beyond preserving cboot's global
reserved-memory map, which this boot chain already does.

The observed programmed WPR register plus the complete `acr`, `pmu`, and `gr`
firmware set are the expected prerequisites. **UNCERTAIN:** only an ACR boot can
prove that stock cboot's bounds and permissions are acceptable to mainline;
malformed/missing bounds should produce an ACR error, not persistent damage.

## 8. Mesa and first visible test

Yes. Mesa 26.2.5's Tegra Gallium screen is explicitly render-only: it opens a
platform render node whose DRM driver name is `nouveau`, creates the nouveau
GPU screen on it, and wraps it for the Tegra display fd
([`tegra_screen.c`:523-545](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/tegra/tegra_screen.c#L523-L545)).
Scanout resources are exported from nouveau and PRIME-imported into tegra-drm
([`tegra_screen.c`:131-164,191-205](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/tegra/tegra_screen.c#L131-L205)).
The loader specifically requires a platform `nouveau` render node
([Mesa `loader.c`:240-299](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/loader/loader.c#L240-L299)).

The ALARM package is currently Mesa 26.2.5 aarch64
([package page](https://archlinuxarm.org/packages/aarch64/mesa)), and the actual
downloaded package was checked to contain `tegra_dri.so`, `nouveau_dri.so`, and
GBM (`NOTES.md:1214-1222`). `glmark2-es2-drm` is built in ALARM's aarch64
package; its build log lists the `drm-glesv2` flavor
([ALARM build log](https://archlinuxarm.org/builder/in-log/glmark2-2023.01-2-armv8.log.html.gz)).

So `eglinfo -p gbm` followed by `glmark2-es2-drm --fullscreen` is a sound
sequence. Verify that the renderer is nouveau/GM20B rather than llvmpipe and
that a new nouveau render node exists. Run glmark2 with no compositor holding
DRM master; it is a direct KMS test on the tegra-drm card, not something to run
under Hyprland first.

## 9. Recovery and test discipline

There is no persistent GPU-specific write here: the nouveau path manipulates
volatile regulator, clock, reset, PMC, IOMMU and GPU state, and its probe-error
path powers the rail/clocks back down (`nvkm/engine/device/tegra.c:326-347`). A
power cycle clears the rail/PWM/PMC/GPU state. The main failure mode is a live
kernel/interconnect hang, not a brick.

Before `modprobe`, run `sync`, then arm exactly:

```sh
systemd-run --unit=darcy-gpu-rollback --on-active=180s -- \
  /bin/sh -c 'echo b > /proc/sysrq-trigger'
```

Cancel only after the module and tests have remained healthy:

```sh
systemctl stop darcy-gpu-rollback.timer
```

The scheduled sysrq covers a stuck modprobe thread while userspace can still
run. It does not cover a fully wedged memory fabric, but systemd is already
feeding the Tegra hardware watchdog every 60 s
(`scripts/13-make-rootfs.sh:200-203`), and `panic=10` is on the system kernel
command line (`kernel/dts/darcy-system.dts:31`). `echo b` deliberately skips
sync, so the pre-test `sync` matters for the USB SSD.

Keep the nouveau blacklist/install override in place, retain a second SSH
session streaming `dmesg`, and reboot after the first successful trial rather
than testing module unload. A panic, SError, or watchdog reset may lose the
latest volatile logs, but ramoops plus U-Boot's recovery log remain the intended
postmortem path. I see no new way for this step alone to make the device
unrecoverable without the TV.
