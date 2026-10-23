# Brainstorm brief: why is GM20B so slow under nouveau on the SHIELD?

Repo: `~/projects/nvidia`. The kernel is Linux 7.2.11 with `patches/linux/0001-0006` (`vendor/linux`). Mesa is 26.2.5 (`packages/mesa-darcy`): the gallium tegra driver wrapping nouveau nvc0, with MR !45355 and our 0002-0007. Hyprland 0.56 runs on tegra-drm (render-only, with linear scanout). The device is a SHIELD TV 2017: Tegra210, GM20B (2 SMs at 998 MHz), 3 GB LPDDR4. EMC is fixed at **800 MHz**; stock darcy tables go to 1600 MHz, and mainline has no tables here.

## What we measured

1. **SuperTuxKart 1.5 `--benchmark`** (GLES 3.2, renderer "tegra", 1054x1054 window, dynamic lighting on, no shadows/SSAO/bloom/MLAA):
   - kernel #15: 3.4 FPS. perf: 69% of the game's samples in `dcache_clean_poc` from `nouveau_bo_validate` → `nouveau_bo_sync_for_device` (every pushbuf cleaned every non-coherent BO it used).
   - kernel #16 (`patches/linux/0006`: sync only BOs that are CPU-mapped or have new pages; reviewed in `research/ncodex-nouveau-sync-review.md`): 3.2 FPS. The cleaning fell to 26% of samples and CPU load to 14%, but STK's own profile now shows a "Sync Stall" (its `glClientWaitSync` on the previous frame's fence) of **241 ms per frame**, out of a 307 ms frame. "SP::Draw normal" fell from 140 to 39 ms. devfreq was at 998 MHz for 94% of the run (the pstate AC line confirms 998 MHz), and board power was 10.3 W against 6 W idle. STK's GPU timer queries return 0 for every pass.
   - The same run with dynamic lighting off (forward renderer): **17.9 FPS** (792 frames in 44 s; steady 11, typical 17), 5.6x faster. Its frame: 56.6 ms main loop, 31.9 ms "SP::Draw normal", 8.5 ms draw-call generation, no big sync stall; GPU at 998 MHz 80% of the time. So the deferred "dynamic lighting" pipeline costs about 250 ms per frame of GPU time on this stack, even with SSAO, shadows, glow, bloom, light shafts and MLAA off ("Degraded IBL" on). What in it could be pathological: RGBA16F MRT G-buffer, FP16 blending of instanced point lights, full-screen passes, the env-map/IBL pass, a mipmap or blit falling back to a slow path in nvc0 or the tegra wrapper?
2. **glmark2-es2-wayland `--off-screen`** (no compositor in the loop), FPS and frame time:

   | size | terrain | texture | build (VBO) |
   |---|---|---|---|
   | 1920x1080 | 15 (71.4 ms) | 201 (4.98 ms) | 217 (4.61 ms) |
   | 960x540 | 28 (37.0 ms) | 707 (1.42 ms) | 680 (1.47 ms) |
   | 480x270 | 44 (23.1 ms) | 1727 (0.58 ms) | 1277 (0.78 ms) |
   | 240x135 | 51 (19.8 ms) | 3477 (0.29 ms) | 1412 (0.71 ms) |

   texture scales with pixels: about 415 Mpix/s at 1080p for a trivial shader. terrain has about 20 ms per frame that doesn't scale with size.

## What the source says

- `nouveau_bo.c:281-283` and `321-323`: for GART BOs, nouveau skips every page size above PAGE_SHIFT. On Tegra (VRAM 0 MiB, everything GART) **every GPU mapping uses 4 KiB pages**. NVIDIA's nvgpu uses 128K big pages, through SMMU-contiguous IOVA.
- dmesg: "imem: using IOMMU". `nvkm_device_tegra_probe_iommu` attaches its own paging domain, and instmem objects (GMMU page tables among them) sit behind the SMMU through bit 34. BOs are DMA-mapped (dma-direct after the attach?), so their PTEs point at physical addresses.
- No compression or comptags on Tegra in nouveau, as far as I know. Unverified.
- The GPU firmware (acr, gr, pmu) is present. dmesg shows no nouveau errors.

## Questions

1. Ranked by likely size: what makes GM20B under nouveau and Mesa nvc0 this slow? Candidates: 4K GMMU pages with the page tables behind the SMMU (TLB miss cost); no colour/depth compression; EMC at 800 MHz; ZCULL not set up; L2 (LTC) configuration; MC client priority or latency allowance for the GPU on Tegra210; GR clock gating, ELPG or SLCG/BLCG states; the tegra gallium wrapper (render-only copies or syncs); a pathology in nvc0's MRT and float render-target or deferred paths. Is there anything known about mainline nouveau on Jetson TX1/Nano performance (for example Thierry Reding's or Ben Skeggs' notes, or Mesa issues)?
2. How can we see GPU-side time? Options: nouveau's PCOUNTER or HW query support on GM20B (`GALLIUM_HUD`, which `nvc0_query_hw_sm` groups exist for GM20B?), timer queries (why does STK read 0? does the tegra wrapper or nouveau lack `GL_EXT_disjoint_timer_query`?), nouveau debugfs, PMU load counters.
3. Experiments we can run, cheapest first, each with what its result would tell us:
   - a. Remove `iommus` from the GPU node (instmem through the DMA API, needing CMA), A/B with terrain and STK.
   - b. Big pages for GART BOs: what would it take? Contiguous TTM pool chunks with `vmm->page[i].shift = 16 or 17` when the dma addresses of a BO are 64K/128K-contiguous, or mapping BOs into the GPU's IOMMU domain to make them IOVA-contiguous as nvgpu does.
   - c. EMC tables, from stock darcy's `tegra210-darcy-p2894-emc-a00.dtsi`, and the mainline tegra210-emc driver.
   - d. Anything in Mesa nvc0, such as a known performance flag or a debug env var.
4. Does anything in our earlier fixes cost GPU time? For example 0004 (semaphore COHERENT), 0005 (sharing the dma-buf resv, which makes page flips wait for nouveau's fences), or the tegra wrapper's resource unwraps.

Analysis only: change nothing in the repo or on the SHIELD.
