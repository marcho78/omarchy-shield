# Review brief: nouveau syncs every BO on every pushbuf (Tegra GM20B)

Repo: `~/projects/nvidia`. The patch is `patches/linux/0006-drm-nouveau-sync-only-bos-the-cpu-may-have-written.patch`. It goes on Linux 7.2.11 (`vendor/linux`, with `patches/linux/0001-0005` applied first; 0004 makes the channel progress semaphore COHERENT, the same coherency family). Kernel #16 is building now. It is not flashed or tested yet.

## Evidence

- Device: SHIELD TV 2017 (Tegra210, GM20B), Mesa 26.2.5 (gallium tegra wrapping nouveau, our `packages/mesa-darcy`), Hyprland 0.56 on Wayland.
- SuperTuxKart 1.5 `--benchmark` (OpenGL ES 3.2, renderer "tegra", at 1054x1054 with low settings) ran at **3 FPS**: 762 frames in 221 s.
- STK's own CPU profile, per frame: "Draw Call Generation" 97 ms, "Sync Stall" 90 ms, "SP::Draw normal with first pass" 140 ms, out of a 293 ms main loop. Its GPU timer queries return 0.
- `perf record -a -g` for 30 s mid-race found **69.28% of the game's samples** in `__pi_dcache_clean_poc_nosync` ← `__dma_sync_single_for_device` ← `nouveau_bo_sync_for_device` ← `nouveau_bo_validate` ← `nouveau_gem_ioctl_pushbuf`. A further 1.78% was in `nouveau_bo_sync_for_device` itself. Nothing else reached 0.3%.
- GPU devfreq sat at 998 MHz in 59% of the samples. The main thread used about 73% of one core.

## The cause, as read in the source

`nouveau_bo_validate()` (`nouveau_bo.c`) calls `nouveau_bo_sync_for_device()` after `ttm_bo_validate()` for every BO in every pushbuf's buffer list. For each non-`force_coherent` BO, that runs `dma_sync_single_for_device(DMA_TO_DEVICE)` over all of its pages. `nouveau_sgdma_create_ttm()` maps non-coherent BOs `ttm_cached`. Every texture and render target a draw uses is therefore cleaned by VA on every submit.

## The patch

There are two new `struct nouveau_bo` fields, in the "protected by ttm_bo_reserve()" group.

`cpu_mapped` is sticky. It is set:
- in `nouveau_ttm_fault()`, after `ttm_bo_vm_reserve()`
- in a new `.access` wrapper (`nouveau_ttm_vm_access`), under a reserve, before calling `ttm_bo_vm_access()`
- in `nouveau_bo_map()` (kernel kmap), under the reserve
- in a new `.vmap` wrapper (`nouveau_gem_object_vmap`), where `drm_gem_ttm_vmap()` already runs under the resv lock
- at the two `ttm_bo_kmap()` sites in `nouveau_gem.c`'s pushbuf paths (reloc and the pre-IB jump), which are pre-NV50 only

`sync_pending` is set at the top of `nouveau_bo_move()`, before any early return: allocation, zeroing, memcpy moves and swap-in all go through a move. It is cleared in `nouveau_bo_validate()` after the sync, under the reserve.

`nouveau_bo_sync_for_device()` returns early when `!cpu_mapped && !sync_pending`. `cpu_fini` calls it without the reserve, so it may read stale flags there. My reasoning is that the GPU only uses a BO after `nouveau_bo_validate()`, which reads the flags under the lock, so a pending sync is never lost. `nouveau_bo_sync_for_cpu()` (cpu_prep) is unchanged.

## Questions

1. **Correctness.** Is there any path where the CPU can leave dirty cache lines in a non-coherent BO's pages without setting either flag? Candidates I considered:
   - TTM pool zeroing on populate, which always comes with a move before GPU use
   - a fault on a SYSTEM-placed BO, which populates without a move but sets `cpu_mapped`
   - swapout and swapin
   - `ttm_bo_move_memcpy`
   - pipelined gutting
   - dma-buf exports CPU-mapped by importers: `dma_buf_mmap` goes through our fault, `dma_buf_vmap` through our vmap
   - imported sg BOs, which have no `pages` array and were never synced
   - `drm_gpuvm`/EXEC (VM_BIND) validation
   - the fbdev/drm_client vmap
   - shrinker paths

   Is a move guaranteed between page population and the first GPU use in every case?
2. **Ordering and locking.** Is clearing `sync_pending` in `nouveau_bo_validate()` safe, given that `ttm_bo_validate()` can move the BO and then we sync? Can a move happen between the sync and the pushbuf's use, for example an eviction under memory pressure from a later BO in the same validate list? (`validate_list` validates the BOs one by one: could BO #2's validation evict BO #1 after BO #1 was synced, and does the pushbuf then use BO #1 anyway, or does TTM's ww-locking prevent that?)
3. **Speculation.** I assume speculative fills only create clean lines, so they can't write back over GPU data, and that CPU reads still go through cpu_prep → sync_for_cpu (invalidate). Is that right on Cortex-A57 for the cases nouveau relies on?
4. **Mesa side.** Does Mesa's nvc0 on GM20B (GART-only, no VRAM) CPU-map textures or render targets? If it maps most BOs, the sticky flag would make the patch useless. Point me at the Mesa code paths if you know them: `nvc0_miptree_transfer_map`, the winsys `nouveau_bo_map`, `PIPE_MAP_DIRECTLY`, and staging uploads.
5. **Upstream.** Would upstream prefer something else, such as Mesa allocating textures COHERENT (write-combined on this kernel, see `nouveau_sgdma_create_ttm`), dirty tracking by write-protect faults, or doing the sync only on the cpu_prep/cpu_fini protocol? Is anything in this patch a blocker for sending it upstream?

Analysis only: change nothing in the repo or on the SHIELD.
