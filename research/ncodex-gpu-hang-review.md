# GM20B first-register hang: review

## Bottom line

The **fuse clock is by far the leading cause**. This is no longer merely an
inference from NVIDIA's downstream sequence: a very recent upstream v2 series
reports the same GM20B failure signatures on Jetson TX1—garbage `BOOT_0`, PRI
timeouts, and first-register reads that stall until an SError—and fixes the
primary failure by keeping the fuse clock on for the whole GPU-powered interval.
One TX1 that failed on every boot succeeded on 38/40 boots after that change;
across eight TX1s, failures fell from 27/109 to 11/291, and none of the remaining
failures had garbage `BOOT_0`. See the [v2 driver patch](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg644766.html)
and [Tegra210 DT patch](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg644768.html).

That does not prove the cause on this individual darcy until a fuse-clock-only
probe returns from `readl()`, so the device-specific conclusion is formally
**UNCERTAIN**, but confidence is high. The measured state matches exactly: the
rail, clock/reset and clamps are good while the fuse clock is gated
(`gpu-hang-brief.md:18-33`). Voltage is ruled out by the repeat at 1.0 V
(`gpu-hang-brief.md:19-25`).

## 1. Ranking the three differences

### 1 — Fuse clock on: very high confidence

Mainline powers the rail and enables only `gpu`, `ref`, and `pwr`, then performs
the reset/clamp sequence (`drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:31-65`).
Its Tegra device object has no fuse-clock member
(`drivers/gpu/drm/nouveau/include/nvkm/core/tegra.h:14-21`), and probe acquires
only those three clocks (`drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:275-309`).
The test module duplicates that omission: its three clock handles are declared at
`tools/gpu-power-probe/gpu-power-probe.c:58-64`, enabled at lines 173-185, and
the fatal first read is at line 226.

NVIDIA instead lists `fuse` as clock index 3
(`platform_gk20a_tegra.c:457-465`) and enables it before releasing reset
(`platform_gk20a_tegra.c:396-420`). The new upstream patch independently reaches
the same conclusion and enables `clk_fuse` **before the regulator**, unwinding it
only after the rail is off. Its failure modes are unusually close to darcy's,
including a first MMIO read stall.

### 2 — Release reset while `gpu_gate` is off: plausible, but second

The downstream `gpu_gate` is mainline's `gpu` clock: mainline registers it as a
gate on CAR reset/clock ID 184 (`drivers/clk/tegra/clk-tegra-periph.c:772-807`).
NVIDIA disables that gate, deasserts reset, then re-enables it
(`platform_gk20a_tegra.c:423-436`). This may be a Tegra210 reset sequencing
requirement not reflected by the CAR reset bit; **UNCERTAIN**.

It ranks below the fuse clock because the recent TX1 fix changes neither reset
ordering nor MC state yet largely cures the same early probe failures. Mainline's
current always-clocked deassert sequence is visible at
`drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:41-64`. If fuse-on alone does
not make darcy's `BOOT_1` read return, this is the next isolated experiment.

### 3 — MC flush / flush_done: least likely for the first CPU PRI read

The downstream operation sets the GPU bit in `MC_CLIENT_HOTRESET_CTRL_1`, waits
for the corresponding status bit, then clears the control bit; NVIDIA calls it
after reset release (`platform_gk20a_tegra.c:438-445`). Mainline already exposes
the equivalent GPU MC reset at control/status `0x970/0x974`, bit 2
(`drivers/memory/tegra/tegra210.c:1234-1270`), implemented as block-DMA, wait for
idle, and unblock (`drivers/memory/tegra/mc.c:160-208,228-324`).

That sequence governs the GPU's outbound memory client, whereas the failing
transaction is a CPU MMIO read of GPU BAR0; it therefore has a weaker direct
mechanism for this exact stall. The observed MC status changing from 1 to 0 as
the GPU comes up also shows the interface is alive (`gpu-hang-brief.md:26-33`).
NVIDIA's explicit “after boot/railgate/SC7” comment means it should not be
dismissed for later DMA correctness, but its necessity before the first PRI read
is **UNCERTAIN**.

### Other downstream operations

- `tegra_soctherm_gpu_tsens_invalidate(0)` changes GPU temperature-sensor
  validity (`platform_gk20a_tegra.c:382-386`); there is no credible dependency
  from that bookkeeping to BAR0 response. **UNCERTAIN at the undocumented
  hardware level**, but it is not a leading candidate.
- BWMGR raises an EMC bandwidth floor at lines 382-384. It matters once the GPU
  generates memory traffic, not for a CPU PRI read. More tellingly, although
  `emc` is clock index 2 in the table, the unrailgate path enables indices 0, 1,
  and 3 and skips index 2 (`platform_gk20a_tegra.c:396-420`). Thus a separate
  EMC-clock enable is not part of NVIDIA's prerequisite sequence.

## 2. Why TX1/Nano appeared to work

Mainline does **not** reliably get away without the fuse clock. The upstream
report says TX1 has been intermittently broken since its GPU was enabled, with
board-dependent incidence up to every boot. Thierry Reding's review notes the
likely historical masks: GPU not enabled by default, the fuse clock left on by
older code/firmware, or built-in nouveau probing before the early fuse clock was
later shut off ([review reply](https://lkml.iu.edu/2610.1/12701.html)). Nano's
boot state/timing apparently masks it more often; that is not a valid contract.

The current fuse driver explains the measured `clk_summary` precisely:

1. Early init directly enables the fuse clock because CCF is not ready
   (`drivers/soc/tegra/fuse/fuse-tegra.c:366-380`) and invokes that helper at
   lines 545-564.
2. The platform probe acquires the `fuse` clock, enables runtime PM, resumes the
   device, resets it, then drops the runtime-PM reference
   (`drivers/soc/tegra/fuse/fuse-tegra.c:186-195,233-246`). Runtime suspend
   disables the clock (`drivers/soc/tegra/fuse/fuse-tegra.c:259-276`).
3. Every later fuse read resumes the fuse device only around that read
   (`drivers/soc/tegra/fuse/fuse-tegra30.c:51-64`). `tegra_fuse_readl()` does
   not keep a permanent reference; it dispatches to that read method
   (`drivers/soc/tegra/fuse/fuse-tegra.c:343-362`).

Therefore no normal fuse/nvmem consumer leaves the clock on for nouveau. This is
not a darcy-specific missing bootloader handoff. `clk_ignore_unused` would also
be the wrong fix: runtime PM explicitly disables the clock.

## 3. Mainline-shaped fix

Use both a **DT description and a nouveau change**; either alone is incomplete.
The existing T210 GPU node has only `gpu`, `pwr`, and `ref`
(`arch/arm64/boot/dts/nvidia/tegra210.dtsi:440-452`), while nouveau only requests
those names.

The right shape is the posted upstream series:

1. Append `<&tegra_car TEGRA210_CLK_FUSE>` and the name `"fuse"` to the common
   Tegra210 GPU node.
2. Have nouveau acquire that clock and keep it enabled from before rail-on until
   after rail-off, with correct error unwinding.
3. Update `Documentation/devicetree/bindings/gpu/nvidia,gk20a.yaml`; its current
   schema permits only the existing two/three-clock forms (lines 41-53).

As of 2026-10-22, the v2 series is posted but not present in this 7.2.11 tree.
Its core solution is strong, but the binding patch still has review feedback:
the GM20B branch needs to enforce four items, and Rob Herring asked that clock
names remain defined at top level. Treat the series as pending, not an already
merged API. The driver intentionally uses an optional getter for compatibility,
even though the new binding is intended to require the clock.

For diagnosis, change only the fuse-clock variable first. If that still hangs,
test fuse-on plus the gate-off reset release. Only then add the MC flush. If MC
handling proves necessary, use the existing generic MC reset controller
(`<&mc TEGRA210_MC_RESET_GPU>`) and driver sequencing rather than open-coded MC
MMIO; the reset ID exists at `include/dt-bindings/memory/tegra210-mc.h:50-70`.
Those latter two fixes remain **UNCERTAIN** and should not be bundled into the
first test, because doing so would destroy the clean causal result.
