# Review brief: nouveau dirty tracking by revoking CPU mappings (patch 0006, v3)

Repo: `~/projects/nvidia`. The patch is `patches/linux/0006-drm-nouveau-sync-only-bos-the-cpu-may-have-written.patch`, applied in `vendor/linux` (Linux 7.2.11 + `patches/linux/0001-0007`). Kernel #20 is built and **not flashed yet**. Your earlier reviews of v1/v2 are in `research/ncodex-nouveau-sync-review.md`.

## Why v3

On kernel #19 (v2: a sticky `cpu_mapped` flag), SuperTuxKart (dynamic lighting off, EMC at 1600 MHz) runs at 20.7 FPS. `perf` shows **41% of the game's CPU time still in `dcache_clean_poc`** from `nouveau_bo_sync_for_device()` in `nouveau_bo_validate()`. The GPU is busy only 56% of the time, and STK's "SP::Draw normal" takes 30 ms of a 49 ms frame. Under v2, any BO userspace ever mapped (Mesa's `mm_GART` slabs holding vertex/index/uniform buffers, pushbufs, staging) is cleaned whole on every pushbuf, forever.

## v3, the design

- `cpu_kmapped` (sticky): kernel kmap (`nouveau_bo_map()`, the two pre-NV50 pushbuf `ttm_bo_kmap()` sites) and vmap (`nouveau_gem_object_vmap`). The whole BO is synced on every validation, as in v2.
- `cpu_dirty` with `dirty_first`/`dirty_last` pages: set in `nouveau_ttm_fault()` after `ttm_bo_vm_reserve()`. The range is the faulting page (`vmf->pgoff - drm_vma_node_start()`) plus `TTM_BO_VM_NUM_PREFAULT` (16) pages forward, because `ttm_bo_vm_fault_reserved()` maps forward from the faulting page up to 16 pages. A ptrace write (`.access` with write) marks the whole BO.
- `sync_pending`: set as in v2, by population (`nouveau_sgdma_populated()`) and moves. It means a whole-BO sync once.
- `nouveau_bo_sync_dirty()` runs with the BO reserved, from `nouveau_bo_validate()` and from `CPU_FINI` (which now reserves). If `cpu_dirty`: first `ttm_bo_unmap_virtual()` (zap PTEs + TLB flush), then clear `cpu_dirty` and clean only `dirty_first..dirty_last`, unless kmapped or pending, in which case the whole BO is cleaned below. Then `nouveau_bo_sync_for_device()`, which cleans the whole BO only if `cpu_kmapped || sync_pending`, and clear `sync_pending`.
- `nouveau_bo_sync_for_device()` is split into a page-range helper `nouveau_bo_sync_pages_for_device(first, last)`, clamped to `num_pages`, using unsigned longs.

The ordering argument: under the reservation we unmap first, so any later store must fault. The fault does `ttm_bo_vm_reserve()`, so it waits for the reservation and retries, then re-marks. Every earlier store is complete by the time the TLBI's DSB ISH completes (ARMv8: broadcast TLB maintenance completes after accesses by other PEs through the old translations), so the following clean by VA reaches them.

## Questions

1. Is the ordering argument sound on arm64 and in Linux's `unmap_mapping_range()` (mmu_gather, `flush_tlb_range`)? Are there stores in flight that can escape the clean? What about other CPUs' write buffers holding stores to the old PTEs?
2. Are there CPU write paths into a BO's pages that bypass both `nouveau_ttm_fault()` and the kmap/vmap/populate/move markers? Candidates: `ttm_bo_vm_access` read/write via kmap, `ttm_bo_access`, dma-buf `begin_cpu_access`, `get_user_pages`/`pin_user_pages` on the mmap (does TTM's `VM_PFNMAP`/`VM_IO` forbid GUP?), `process_vm_writev`, io_uring fixed buffers, a fork/COW of the mapping, mremap, the shrinker/swap writing pages, and hibernation.
3. Is the dirty range right? Can a single fault map pages *before* the faulting page (huge PMD mappings, `ttm_bo_vm_fault_reserved` with `vmf_insert_pfn_pmd`?), or more than 16? Is `vmf->pgoff - drm_vma_node_start()` the right BO page index for every VMA, including partial mmaps at an offset?
4. Cost: `ttm_bo_unmap_virtual()` also calls `ttm_mem_io_free()`. Can that hurt for TT resources, or for tiled GART BOs (`mem->kind`, the "tiled memory" fall-through in `nouveau_ttm_io_mem_reserve`)? Is refaulting pushbufs and streaming buffers every submit a performance concern, compared with the cleaning we save?
5. Any interaction with Mesa 26.2.5's nouveau winsys? Persistent maps, `nouveau_bo_map()` with `BO_WAIT`/`CPU_PREP`, user pointer (`resource_from_user_memory`), and SVM (`has_svm`, does GM20B have it?).
6. Would you rather do this in Mesa? For example `NOUVEAU_BO_COHERENT` (write-combined) for `mm_GART` slabs and pushbufs on GART-only screens: Mesa's fence BO already uses it (`nvc0_screen.c:846`). Or both?

Analysis only: change nothing in the repo or on the SHIELD.
