# Review: Nouveau dirty-page cache synchronization (v3)

## Verdict

**Request changes before flashing.** The central arm64 ordering argument is sound, and the fault-derived page range is conservative and correctly indexed. However, I found two ways the dirty indication can be consumed before the corresponding CPU write/mapping exists, plus misuse of `ttm_bo_unmap_virtual()` as a PTE-zap helper. Any of those can defeat the intended invariant or damage a live I/O mapping. There is also an important performance bug: coherent BOs are still unmapped and refaulted, which negates the proposed Mesa `NOUVEAU_BO_COHERENT` optimization.

For darcy's ordinary untiled GART BOs, the most likely runtime issue is the cost of repeated full-BO PTE revocation/refault, not `ttm_mem_io_free()`. The correctness bugs are nevertheless real kernel-wide and should be fixed first.

## Findings, ranked

### High — a fault's mark can be cleared by validation before the PTE is installed

`nouveau_ttm_fault()` marks the range before calling `nouveau_ttm_fault_reserve_notify()` (`vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:68-82`). The notify function can call `nouveau_bo_validate()` while the reservation is already held (`nouveau_bo.c:1423-1465`). Validation calls `nouveau_bo_sync_dirty()`, which consumes and clears the just-added mark (`nouveau_bo.c:830-843`, `:758-772`). The fault then installs writable PTEs without restoring it.

This occurs when fault notification must relocate a tiled SYSTEM BO to TT, or handle old non-mappable VRAM. The common GM20B untiled-TT fast path returns before validation, so the SuperTuxKart workload may not trigger it; that does not make the invariant valid.

Required fix: perform `nouveau_ttm_fault_reserve_notify()` first, then mark the fault/prefault range immediately before `ttm_bo_vm_fault_reserved()`, still under the BO reservation. A failed or retrying fault may leave a conservative false-positive mark, which is safe. A successful relocation can no longer consume the mark for the mapping that follows.

### High — `.access` marks and writes under two different reservations

The ptrace/access-process wrapper reserves the BO, marks it dirty, unlocks, and then calls `ttm_bo_vm_access()` (`nouveau_gem.c:92-106`). The latter enters `ttm_bo_access()`, reserves the BO again, and only then performs the kmap/memcpy (`drivers/gpu/drm/ttm/ttm_bo_vm.c:368-469`). A validation in the gap can consume the mark; the later write then leaves dirty cache lines with `cpu_dirty == false`.

This is not only theoretical bookkeeping: arm64 has `CONFIG_HAVE_IOREMAP_PROT`, so `/proc/<pid>/mem` and ptrace fall back to `vm_ops->access` for this `VM_IO|VM_PFNMAP` VMA (`mm/memory.c:7020-7095`).

Required fix: make the write and dirty update one reservation-protected operation. The cleanest solution is a TTM helper that performs `ttm_bo_access()` with an already-held reservation. Since this is a rare debugging path, a simpler safe policy is to set a sticky “always whole-sync” flag for any `.access` write before delegating to TTM; do not use a mark that validation can clear between the two reservations. Concurrent CPU writing after a GPU submission remains an application-level ownership violation, but a completed ptrace write must be visible to a later submission.

### High — `ttm_bo_unmap_virtual()` does more than revoke user PTEs

`nouveau_bo_sync_dirty()` calls `ttm_bo_unmap_virtual()` (`nouveau_bo.c:758-767`). That helper first zaps user mappings, then calls `ttm_mem_io_free()` (`drivers/gpu/drm/ttm/ttm_bo.c:1047-1058`). For Nouveau, freeing I/O state destroys the NVIF mapping handle for tiled TT and for VRAM (`nouveau_bo.c:1282-1300`) and clears `resource->bus.offset/addr` (`drivers/gpu/drm/ttm/ttm_bo_util.c:62-75`).

That teardown is appropriate before a TTM move, but not for a cache-dirty barrier. It causes needless handle destruction/recreation on each submit for a user-mapped tiled BO. More seriously, if the BO also has a live I/O-backed kmap/vmap (`cpu_kmapped`), freeing the underlying I/O handle while that kernel mapping remains live is unsafe. **UNCERTAIN:** I did not establish a current GM20B/Mesa path that simultaneously user-maps and persistently kmaps a tiled BO, but the helper contract permits the combination and the patch should not invalidate it.

Required fix: revoke only the GEM VMA PTEs, using the operation already inside the TTM helper:

```c
drm_vma_node_unmap(&bo->base.vma_node, bo->bdev->dev_mapping);
```

Do not call `ttm_mem_io_free()` for this purpose. For darcy's normal `mm_GART` and push BOs, Mesa supplies zero memtype/kind, so the current I/O-free half is generally a no-op; the TLB/refault cost remains.

### Medium — coherent BOs still pay the revocation cost

The range helper skips cache maintenance for `nvbo->force_coherent` (`nouveau_bo.c:693-733`), but `nouveau_bo_sync_dirty()` revokes the mappings before reaching that check. Thus a coherent BO that faults once is still unmapped and refaulted on each validation. The same pointless behavior applies on globally DMA-coherent devices even though their DMA sync is a no-op.

This matters directly to the Mesa proposal: merely adding `NOUVEAU_BO_COHERENT` to pushbufs or `mm_GART` will avoid `dcache_clean_poc` but **will not avoid v3's TLB shootdowns/refaults**. Coherent/WC BOs should not be marked `cpu_dirty`, or `sync_dirty()` should clear their bookkeeping without revoking PTEs. The noncoherent decision should likewise be gated appropriately for the device; `dma_need_sync()` is preferable to assuming every Nouveau device needs software cache ownership transfers.

### Medium — the patch has no targeted regression coverage

The new correctness model spans TTM faults, BO moves, ptrace access, mmap revocation, population, and dma-buf vmap, but the patch adds no test. At minimum, add focused tests or a small reproducer for:

- a fault that invokes `nouveau_ttm_fault_reserve_notify()` relocation;
- a ptrace POKE followed by a GPU checksum/copy;
- partial mappings at a nonzero BO page offset and the last BO page;
- forked mappings followed by sync and refault;
- a tiled BO with simultaneous user mapping and kernel vmap/kmap;
- population/swap-in and forced moves;
- a coherent BO proving that validation does not zap its PTEs.

### Optional — avoid sticky false positives on failed kernel maps

`nouveau_bo_map()` and `nouveau_gem_object_vmap()` set `cpu_kmapped` before knowing whether kmap/vmap succeeds (`nouveau_bo.c:669-681`, `nouveau_gem.c:257-262`). This is safe but permanently forces full cleaning after a failed mapping. Set it after success where the call structure permits.

## 1. arm64 ordering and in-flight stores

Subject to the fixes above, the proposed revoke-then-clean ordering is sound on arm64:

1. `drm_vma_node_unmap()` calls `unmap_mapping_range()` over the complete GEM offset node (`include/drm/drm_vma_manager.h:208-227`).
2. Each matching VMA is zapped through `mmu_gather`, and `tlb_finish_mmu()` performs the pending synchronous TLB flush before returning (`mm/memory.c:4339-4358`; `mm/mmu_gather.c:515-554`).
3. arm64's range flush executes `dsb(ishst)`, broadcast TLBI, then `dsb(ish)` (`arch/arm64/include/asm/tlbflush.h:561-610`). Completion of the broadcast invalidation is the boundary that prevents later accesses through the old translation and completes relevant accesses already using it.
4. The DMA sync cleans the pages through the kernel linear map to PoC and completes with the DMA layer's synchronization barrier (`arch/arm64/mm/dma-mapping.c:15-21`; `kernel/dma/direct.h:56-66`, or the IOMMU equivalent at `drivers/iommu/dma-iommu.c:1117-1131`).

Therefore another CPU's store buffer or dirty cache line cannot legitimately “escape” between the completed TLBI and the following clean. A subsequent user store faults, blocks on the BO reservation, and can install a PTE only after this sync releases the reservation. No extra ad-hoc IPI or cache operation is needed.

This does not make simultaneous CPU and GPU mutation legal. Once the reservation is released, userspace can fault and write again while the submitted GPU owns the BO; Mesa/fences must still enforce ownership. The patch establishes visibility at the handoff, not ongoing mutual exclusion. The Linux [cache/TLB documentation](https://docs.kernel.org/next/core-api/cachetlb.html) is consistent with the synchronous all-CPU effect relied on here.

## 2. CPU write paths

| Path | Result |
|---|---|
| Normal Nouveau mmap, including multiple/partial VMAs | Covered by `nouveau_ttm_fault()`, apart from the mark-before-notify bug. Revocation covers every VMA associated with the GEM offset node. |
| Ptrace and `/proc/pid/mem` write | Reaches `.access`, but the two-reservation race above must be fixed. |
| `process_vm_writev()` | Does not fall back to `.access`; its `pin_user_pages_remote()` fails for `VM_IO|VM_PFNMAP` (`mm/process_vm_access.c:73-129`, `mm/gup.c:1200-1208`). It cannot write this mapping. |
| io_uring registered/fixed buffer, ordinary GUP/PUP | Rejected for the same `VM_IO|VM_PFNMAP` reason. |
| fork | TTM sets `VM_PFNMAP`; the page tables may be copied, but the original fault already marked the BO and `unmap_mapping_range()` covers all file-backed VMAs. After revocation, either process must refault. |
| COW | TTM rejects COW mappings (`ttm_bo_vm.c:488-511`). |
| `mremap()` move/expand | Rejected by `VM_DONTEXPAND|VM_PFNMAP` (`mm/mremap.c:1814-1855`). Shrinking creates no new writable alias. |
| dma-buf mmap/vmap of a native Nouveau BO | mmap uses Nouveau's `vm_ops`; vmap reaches the `cpu_kmapped` wrapper. Covered. |
| dma-buf `begin_cpu_access`/`end_cpu_access` | Generic DRM PRIME ops have no begin/end callbacks (`drm_prime.c:827-836`), so these calls do not provide a marker. Actual native mmap/vmap access still follows the covered paths. Imported external BO coherency belongs to the exporter/attachment protocol; Nouveau deliberately has no native page array to clean. |
| TTM population/swap-in | Successful native population marks `sync_pending`; swap-in occurs afterward while that flag remains set (`nouveau_bo.c:1468-1493`, `drivers/gpu/drm/ttm/ttm_tt.c:370-416`). Covered. |
| TTM CPU memcpy or GPU move | `nouveau_bo_move()` sets `sync_pending` before either route (`nouveau_bo.c:1190-1279`). Conservative whole sync follows validation. |
| hibernation | **UNCERTAIN:** not exhaustively audited. Hibernation should preserve logical RAM contents while GPU work is quiesced, rather than constitute a new BO CPU write, but resume/swap stress should be included before treating the scheme as general-purpose. |

Kernel writes through Nouveau's lasting `nouveau_bo_map()`, the two direct relocation kmaps, and GEM/dma-buf vmap are covered by `cpu_kmapped`. I found no other direct `ttm_bo_kmap()` caller in the Nouveau GEM/TTM layer.

## 3. Dirty range correctness

The ordinary range calculation is correct. TTM computes the BO page as:

```text
((vmf->address - vma->vm_start) >> PAGE_SHIFT)
  + vma->vm_pgoff - drm_vma_node_start(node)
```

and `vmf->pgoff` already represents the first two terms. Therefore `vmf->pgoff - drm_vma_node_start()` is the right BO-relative page for full and partial mappings (`ttm_bo_vm.c:211-214`).

`ttm_bo_vm_fault_reserved()` installs only PTE-sized mappings with `vmf_insert_pfn_prot()`, starting at the fault and walking forward for at most `num_prefault` entries (`:241-280`). It does not use `vmf_insert_pfn_pmd()` and cannot map pages before the fault. Marking 16 pages can overestimate at a VMA/BO boundary or after an insertion failure; the sync helper clamps to `num_pages`, so that is safe. Marking read faults is also necessary because a writable VMA receives writable PTEs and can later be stored through without another fault.

The min/max interval is correct but may be imprecise for sparse slab writes: two faults far apart clean the untouched span between them. A bitmap or a small interval set would reduce that cost, but first measure; it adds state and hot-path complexity.

## 4. Revocation and performance cost

For Mesa's untiled GART slabs (`mem->kind == 0`), `nouveau_ttm_io_mem_reserve()` leaves the resource as ordinary TT memory and creates no NVIF I/O handle (`nouveau_bo.c:1319-1334`). Consequently, the `ttm_mem_io_free()` half of `ttm_bo_unmap_virtual()` normally does nothing on the exact STK buffers. For tiled GART or VRAM it is both costly and potentially unsafe, as described above.

The remaining cost is substantial but plausibly much lower than cleaning every slab on every submit:

- Mesa keeps the `mmap()` for the BO's lifetime ([`nouveau.c:755-766`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L755-766)).
- A validation with any dirty page zaps the entire BO mapping, not merely `dirty_first..dirty_last`.
- The next writes incur roughly one minor fault per up-to-16 forward pages. Push BOs are 512 KiB and Mesa's slab BOs range up to 4 MiB (`nouveau_mm.c:108-143`), though only touched ranges refault.
- A sparse pair of writes can make the min/max cache clean nearly whole-BO even though the fault count remains small.

Measure `dcache_clean_poc`, minor faults, TLBI time, bytes actually cleaned, and submits/second. The observed 41% cleaning cost makes the experiment worthwhile after correctness fixes, but FPS alone cannot show whether the cost was merely moved from cache maintenance into VM faults.

## 5. Mesa 26.2.5 interaction

The patch targets Mesa's real behavior:

- `nouveau_bo_map()` creates one persistent `MAP_SHARED` mapping and then performs `CPU_PREP`/wait as requested; the winsys contains no `CPU_FINI` call ([mapping](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L755-766), [wait](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L908-937)). Revoking PTEs is transparent to its stable pointer.
- `mm_GART` is created as cached `GART|MAP`, with no coherent flag ([`nouveau_screen.c:455-457`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nouveau_screen.c#L455-457)). Slab transfers often map with access flags zero and perform their own suballocation fencing ([`nouveau_buffer.c:467-490`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nouveau_buffer.c#L467-490)); PREP/FINI alone cannot discover all writes.
- Winsys push BOs are `GART|MAP`, not coherent ([`nouveau.c:1588-1605`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L1588-1605)).
- The NVC0 fence BO already adds `NOUVEAU_BO_COHERENT` when supported ([`nvc0_screen.c:845-853`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nvc0/nvc0_screen.c#L845-853)), providing a useful precedent and test case for the coherent-unmap bug.
- GM20B is chipset `0x12b`; Mesa enables SVM only above `0x130`, so `has_svm` is false ([`nouveau_screen.c:336-380`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nouveau_screen.c#L336-380)). `resource_from_user_memory_compute_only` follows that flag ([`nvc0_screen.c:351-352`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nvc0/nvc0_screen.c#L351-352)). Gallium user buffers on this GPU are copied into GART before GPU use ([`nouveau_buffer.c:875-897`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nouveau_buffer.c#L875-897)); there is no direct GM20B SVM/userptr bypass.

## 6. Kernel versus Mesa

I would use both layers, but with narrower responsibilities:

1. **Near-term safest performance path:** retain the v2-style kernel rule that safely skips GPU-only BOs, and make the hottest known write-only upload allocations coherent/WC in Mesa. Push BOs are the first candidate. This avoids both cache cleans and PTE shootdowns for them.
2. **Do not blindly make all `mm_GART` coherent.** Those slabs also serve vertex/uniform storage, staging, and CPU readback. Nouveau implements coherent BOs as write-combined TTM mappings (`nouveau_sgdma.c:69-90`); sequential uploads may benefit, but reads and small irregular accesses can regress badly. A distinct coherent upload/push pool is preferable to changing the shared allocator globally.
3. **Keep a corrected v3 kernel mechanism for cached persistent maps and non-Mesa clients.** Mesa cannot reliably express page-granular dirtiness through the current UAPI, and its persistent slab mapping plus missing FINI means a kernel-independent PREP/FINI solution is incomplete.
4. If v3 remains, add the coherent fast path before recommending any Mesa coherent change; otherwise `NOUVEAU_BO_COHERENT` still incurs needless unmap/refault cycles.

After the three required correctness fixes, an A/B comparison of (a) v2 + coherent push BOs and (b) corrected v3 + coherent push BOs should decide whether fault-based range tracking earns its complexity. Record rendered checksums and GPU fault/error logs as well as FPS, cache-clean time, minor faults, and TLBI cost.

## Verification status

This was a source review only, as requested. I did not build, run, flash, or touch the SHIELD. Mesa observations are against the `mesa-26.2.5` tagged sources linked above.
