# GM20B/Nouveau slowness brainstorm

## Bottom line

My leading explanation is not one 5.6x bug. It is STK's unusually hostile deferred-lighting workload amplified by three real Nouveau/mainline handicaps: no compression tags, EMC fixed at 800 MHz, and 4 KiB GPU mappings. The first experiment I would run is an STK pass breakdown, followed by disabling `GL_EXT_color_buffer_float` and reducing the point-light count. I would not start with clock gating, ZCULL, or the Tegra Gallium wrapper.

An important correction to the premise: STK 1.5 does **not** use an RGBA16F MRT G-buffer here. Its first pass writes two RGBA8 targets. Lighting writes two `R11G11B10F` targets with additive blending; the final combine reads six textures and writes the RGBA16F colour target ([`rtts.cpp:84-130`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/rtts.cpp#L84), [`rtts.cpp:175-207`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/rtts.cpp#L175), [`shader_based_renderer.cpp:258-360`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/shader_based_renderer.cpp#L258)). The point-light pass can draw **32** screen-space light quads in one instanced call; each surviving fragment samples normal/depth, reconstructs position, evaluates diffuse and specular BRDFs, and blends into both float targets ([`lighting_passes.cpp:355-379`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/lighting_passes.cpp#L355), [`pointlight.frag:27-69`](https://github.com/supertuxkart/stk-code/blob/1.5/data/shaders/pointlight.frag#L27)). **UNCERTAIN:** the benchmark track's actual light count and total quad coverage were not captured, so this needs measurement rather than assumption.

## 1. Ranked causes

1. **Deferred light overdraw plus float MRT blending / NVC0 shader and hazard handling — high.** This is the only candidate that naturally explains the dynamic-on/off delta. `R11G11B10_FLOAT` and `RGBA16_FLOAT` are native, blendable NVC0 formats, so I see no evidence of a CPU/software fallback (`Mesa 26.2.5 src/gallium/drivers/nouveau/nv50/nv50_formats.c:164,313`). But “native” does not mean cheap: each light causes two texture reads, a substantial fragment shader, and read-modify-write blending of two render targets. NVC0 also emits a full `SERIALIZE` when a resource previously read by the GPU is rebound for rendering (`nvc0_state_validate.c:154-272`), which a multi-pass deferred graph can trigger repeatedly. **UNCERTAIN:** whether the dominant unit is shader, ROP/blend, memory, or over-conservative serialization cannot be told from the fence alone.

2. **No colour/depth compression plus 800 MHz EMC — high amplifiers.** The absence of comptags is confirmed, not conjectural: GM20B has no Nouveau VRAM object (`nvkm/subdev/fb/gm20b.c:25-35`), and the LTC setup explicitly sets `num_tags = 0` when there is no VRAM (`nvkm/subdev/ltc/gf100.c:151-167`; GM20B selects `gm200_ltc_new` at `nvkm/engine/device/base.c:2050-2071`). This removes the bandwidth savings that matter most for repeatedly blended MRTs and depth. The fixed 800 MHz EMC is plausibly another large multiplier. **UNCERTAIN:** “half stock maximum” does not imply exactly half application performance, and Tegra's displayed EMC rate/data-rate convention makes a paper bandwidth estimate unsafe. Pure streaming bandwidth alone is unlikely to explain 250 ms; the light overdraw, ROP traffic, cache/TLB misses, and shader work multiply it.

3. **4 KiB GMMU pages — medium/high.** Hardware exposes 64 KiB/128 KiB host-capable mappings (`nvkm/subdev/mmu/vmmgm20b.c:24-62`), but both legacy and UVMM BO selection reject host pages larger than `PAGE_SHIFT` (`nouveau_bo.c:268-336`). Moreover, `nouveau_mem_host()` hard-codes `PAGE_SHIFT` when constructing imported TTM memory (`nouveau_mem.c:89-121`). With all memory in GART, texture/RT-heavy workloads therefore pressure the GPU TLB and force more page-table walks. This is a credible scene-wide loss, but **UNCERTAIN** as a 5x cause: the resolution-independent ~20 ms terrain floor could also be draw/barrier overhead.

4. **GMMU page tables behind the Tegra SMMU — medium/low by itself.** Nouveau's private IOMMU domain is specifically used to make `instmem` (including GPU page tables/context objects) GPU-contiguous (`nvkm/subdev/instmem/gk20a.c:23-42,420-495,573-604`). Ordinary BO mappings are not flattened into a single IOVA by this allocator. Thus removing `iommus` tests the extra translation of page-table/instance-memory fetches, not the 4 KiB BO mapping problem. SMMU TLB locality may make the extra layer modest. **UNCERTAIN:** the actual GM20B walker/SMMU cache interaction is undocumented here.

5. **NVC0 fixed per-draw/pass overhead and serialization — medium.** Terrain retaining about 20 ms at 240x135 is real evidence for a non-pixel term. It may be many draws, cache barriers, command submission, or GPU serialization rather than CPU load. A debug Mesa build exposes `gpu_serialize_count` through Nouveau driver statistics; release builds compile these statistics out (`nouveau_screen.h:11-13`).

6. **MC arbitration/latency allowance — medium/low.** Mainline does not leave GPU latency allowance entirely untouched: MC probe programs all defaults (`drivers/memory/tegra/mc.c:414-442`), including GPUSRD/GPUSRD2 `0x1a` and GPUSWR/GPUSWR2 `0x80` (`tegra210.c:664-695,1130-1161`). Nouveau makes no interconnect/bandwidth request for the GPU. Stock nvgpu/BWMGR may program additional dynamic priority/PTSA settings, but that difference is **UNCERTAIN** until stock and mainline register snapshots are compared under like load.

7. **ZCULL or L2 absent — low.** Both are initialized. GM20B selects `gf117_gr_init_zcull` (`nvkm/engine/gr/gm20b.c:116-137`), and selects GM200 LTC with invalidate/flush support (`nvkm/subdev/ltc/gm200.c:29-64`). There is a ZCULL TODO about “litter vals for gf117-gm2xx” (`gf117.c:123-151`), so exact parity with nvgpu is **UNCERTAIN**, but “no ZCULL/L2” is false.

8. **Tegra wrapper, clock gating, or ELPG — very low.** The wrapper forwards draws/queries and unwraps resources; only scanout resources are forced linear and imported into Tegra DRM, with no per-frame render-target copy (`Mesa tegra_screen.c:170-215`). GM20B has no GR `clkgate_pack`, and ELPG binding is disabled (`gf100.c:1816-1826,2369-2377`). Missing power gating normally raises power, not active-work latency. The observed 998 MHz residency also argues against gating-induced throttling.

I did not find a primary-source public analysis assigning a performance loss to mainline GM20B/Nouveau on TX1/Nano. **UNCERTAIN:** absence from this search is not evidence that no relevant issue exists. The source-level limitations above are firmer evidence than anecdotal benchmark comparisons. Thierry Reding's original description confirms that Tegra display and Nouveau rendering share buffers through DMA-BUF rather than requiring a display copy ([mailing-list thread](https://lists.freedesktop.org/archives/wayland-devel/2014-June/015324.html)).

## 2. Getting GPU-side time

### First fix/validate STK's existing timers

NVC0 does implement elapsed-time queries: it advertises `query_timestamp` and `query_time_elapsed` (`nvc0_screen.c:243,267-269`), emits hardware `QUERY_GET` timestamps, and subtracts them (`nvc0_query_hw.c:203-205,272-275,362-370`). The Tegra wrapper directly forwards create/begin/end/result (`tegra_context.c:98-151`). Patch 0007's omission of the optional context `get_timestamp` callback does **not** remove Gallium query objects.

STK's timer code is weaker: it polls availability and reads a **32-bit** result with `glGetQueryObjectuiv`, returning the previous value (initially zero) until available ([`glwrap.cpp:174-236`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/glwrap.cpp#L174)). At 241 ms, 32-bit nanoseconds have not overflowed, so width does not explain this run's zero, but ES timer queries should still be handled as 64-bit and checked for disjoint. The all-zero result most likely means begin/end/get is producing a GL error, counter bits are zero, or results never become available. **UNCERTAIN:** which one.

Use a minimal EGL/GLES test before changing the driver:

- verify `GL_EXT_disjoint_timer_query` and nonzero `GL_QUERY_COUNTER_BITS_EXT`;
- use `GL_TIME_ELAPSED_EXT` and `glGetQueryObjectui64vEXT`;
- check `glGetError()` after begin/end/get and `GL_GPU_DISJOINT_EXT`;
- time a clear, a trivial fullscreen draw, and the two-output additive-blend shader separately.

Then make STK use the same 64-bit path. Its existing timers already surround solid, environment, sun, point-light, combine, and other passes. Khronos specifies timer results as asynchronous 64-bit values ([EXT timer-query specification](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_disjoint_timer_query.txt)).

### Counters already available

- **PMU busy/total is the safest aggregate signal.** Nouveau configures PMU total and GR+CE2-busy counters and samples them every 50 ms for devfreq (`nvkm/subdev/clk/gk20a_devfreq.c:87-180,230-259`). `NV_DEBUG` prints the percentage. A short run with DRM driver debugging enabled (`DRM_UT_DRIVER`, bit `0x2`) should expose it, though log volume can perturb results. A small tracepoint/debugfs readout would be cleaner. This tells “GPU busy versus idle,” not “shader versus memory stalled.”

- **Gallium/NVC0 exposes SM counters and metrics.** For `GM200_3D_CLASS`, Mesa selects the `sm52` table: active cycles/warps, instructions, global loads/stores, branches, etc., plus metrics such as achieved occupancy and IPC (`nvc0_query_hw_sm.c:1515-1738,2232-2277`; `nvc0_query_hw_metric.c:33-99`). The wrapper forwards driver-query enumeration. Start with `GALLIUM_HUD=help`, then dump one metric at a time using `GALLIUM_HUD_DUMP_DIR`; Mesa documents both variables ([Mesa environment variables](https://docs.mesa3d.org/envvars.html#envvar-GALLIUM_HUD)). **UNCERTAIN/RISK:** GM20B is compute capability 5.3, while the selected table is labeled 5.2 and selected only by its shared GM200 class. Validate one counter against a simple shader before trusting values; do not enable a large group at once.

- There is no obvious turnkey Nouveau PCOUNTER debugfs engine for `nv12b`; its device table has no separate PM/PCOUNTER subdevice (`nvkm/engine/device/base.c:2050-2073`). Standard timer queries and PMU load are the first choices.

The 241 ms “Sync Stall” is meaningful: STK places a GL fence after its instanced/particle rendering and waits on that previous-frame fence during the next frame's draw-call preparation ([`draw_calls.cpp:215-248`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/draw_calls.cpp#L215), [`shader_based_renderer.cpp:400-405`](https://github.com/supertuxkart/stk-code/blob/1.5/src/graphics/shader_based_renderer.cpp#L400)). It is queue completion latency, not necessarily the cost of one pass.

## 3. Experiments, cheapest and most discriminating first

1. **Resolution sweep of dynamic-on minus dynamic-off.** Use at least 527², 1054², and 1581² with identical track/light state. A near pixel-proportional delta implicates fragment/texture/ROP/bandwidth; a nearly fixed delta implicates draw/barrier/submit/TLB setup. Record the actual point-light count and summed clip-quad area.

2. **Force the 8-bit fallback without rebuilding:** run with `MESA_EXTENSION_OVERRIDE=-GL_EXT_color_buffer_float`. STK checks that exact extension and changes RGBA16F and R11G11B10F RTTs to RGBA8 (`central_settings.cpp:269-273`; `rtts.cpp:87-105`). A large speedup isolates float-target blending/bandwidth/ROP; little change shifts suspicion to shader work, overdraw, TLB, or barriers. Verify the extension is actually absent in STK's log.

3. **Binary-search STK's lighting pass.** In controlled builds/runs: (a) skip point lights, (b) render 1/4/8/16/32 lights, (c) skip degraded IBL, and (d) replace the point-light fragment shader with constant outputs while retaining the same two-target blend. Scaling with light coverage is normal workload cost; a large constant-output cost points to MRT blend/memory/ROP; expensive real shader with cheap constant output points to NVC0 codegen/SM throughput.

4. **Repair timer queries and log PMU busy during the same cases.** High PMU busy plus low SM IPC/occupancy suggests memory/texture/ROP stalls; high IPC suggests shader work. **UNCERTAIN:** PMU “busy” includes GR/CE activity and cannot identify stalls.

5. **Bypass the Tegra wrapper with a small surfaceless/pbuffer EGL benchmark opened on the Nouveau render node.** Reproduce the two-R11G11B10F additive-light pass and combine. Equivalent timing exonerates the wrapper. This is more reliable than comparing unrelated glmark scenes.

6. **Remove GPU `iommus` only as an ephemeral DT A/B.** If both terrain and STK improve substantially, instmem/page-table SMMU translation matters. No change rules out only that extra layer, **not** 4 KiB GMMU pages. The fallback requires physically contiguous `dma_alloc_attrs()` instmem and can fail under fragmentation (`gk20a.c:23-42,383-417`), so preserve the known-good boot path and compare dmesg (`using DMA API`).

7. **EMC A/B after implementing the correct table handoff.** This is high value but not cheap. Mainline does not consume the downstream `emc-table@1` DT representation directly; it expects a reserved-memory array of firmware-trained `struct tegra210_emc_timing` records (`Documentation/.../nvidia,tegra210-emc.yaml:39-53`; `tegra210-emc-table.c:12-56`). Probe requires an entry matching the current rate (`tegra210-emc-core.c:1846-1913`), and rate changes above 204 MHz require `trained` data (`:1528-1553`). Conversion, RAM-code selection, parent clocks, refresh/training values, and core-voltage assumptions must be reviewed before trying 1600 MHz. Once valid, the driver's `available_rates` and min/max controls make 800-versus-1600 a clean test (`:1571-1684`). **UNCERTAIN:** the current mainline voltage coupling is sufficient for every downstream table point.

8. **Compare MC registers under stock and mainline load before changing QoS.** Capture GPU LA/PTSA/arbitration values and EMC rate. Only then test one difference at a time. Static mainline LA is already programmed, so blind priority writes are poorly discriminating.

9. **Prototype big pages last, after counters show a reason.** Merely deleting the `> PAGE_SHIFT` checks is incorrect. A complete path must (a) obtain 64/128 KiB-aligned, DMA-contiguous chunks or allocate contiguous IOVA, (b) represent the host memory at shift 16/17 instead of the hard-coded shift 12, (c) reserve/map the VMA with the matching page descriptor, (d) fall back to 4 KiB for fragmented/imported BOs, and (e) preserve cache maintenance and teardown. High-order TTM chunks are the smaller prototype but can fragment; flattening every BO into Nouveau's private IOMMU space is closer to nvgpu but requires a new IOVA lifetime/mapping architecture. The current private IOMMU allocator is instmem-only.

There is no useful Nouveau “fast mode” to try: `NOUVEAU_MESA_DEBUG` is only numeric logging (`nouveau_screen.c:312-316` and its few uses), while `NOUVEAU_DISABLE_FENCES` is a correctness-breaking diagnostic, not an optimization. `NV50_PROG_OPTIMIZE` defaults to 4 and is read only in debug builds (`nvc0_program.c:598-601`).

## 4. Cost of the existing fixes

- **Linux 0004:** negligible. It makes one 4 KiB channel-progress semaphore coherent so CPU polling sees GPU writes. It neither changes render-target mappings nor inserts GPU work.
- **Linux 0005:** correct implicit synchronization, not a 241 ms producer. It shares the imported scanout GEM object's `dma_resv`; `drm_gem_plane_helper_prepare_fb()` copies the writer fence to plane state for atomic helpers to wait on (`drm_gem_atomic_helper.c:97-171`). This can move where display/compositor backpressure is observed, but STK's `glClientWaitSync` waits its own GL queue. An offscreen/direct-render-node A/B is the clean proof.
- **Linux 0006:** the longer fence wait after removing CPU cache cleaning is expected accounting: submission is no longer spending ~100 ms cleaning BOs, so the CPU reaches its previous-frame fence sooner and waits there while almost the same GPU critical path completes. The patch removes CPU work; it does not add GPU commands. A missed cache-dirty transition could cause corruption, but is not a plausible clean 250 ms slowdown.
- **Mesa wrapper fixes 0001-0007:** resource unwraps are stack copies/pointer substitutions before the same NVC0 calls. They do not copy BO contents or add GPU passes. `tegra_screen_resource_create_with_modifiers()` creates the BO in Nouveau and imports only scanout resources into Tegra DRM; non-scanout STK RTTs remain ordinary tiled Nouveau resources. The wrapper is still worth bypassing once, but it ranks far below the deferred workload and memory-system limits.

## Recommended next move

Fix the existing timer-query path, log light count/coverage, and run three A/Bs: resolution scaling, `-GL_EXT_color_buffer_float`, and point lights 0/1/8/32. Those four measurements should decide whether to spend engineering time on STK/NVC0 shaders and MRT blending, EMC, or big pages. Removing the IOMMU is a useful later discriminator; ZCULL, L2, and clock gating are not currently supported by the evidence.
