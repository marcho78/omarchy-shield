# Review: Nouveau selective CPU-cache synchronization

## Verdict

The optimization is well targeted and should remove the pathological texture/render-target cleaning seen in the profile. For the stated Mesa 26.2.5 legacy-pushbuf workload, I found no likely missed native-Nouveau GPU handoff. I would regard it as a reasonable instrumented test patch.

I would **request changes before upstreaming**. The main correctness issue is that `CPU_FINI` reads fields documented as reservation-protected without taking the reservation. The second issue is that “page population always comes with a move” is not a TTM invariant; it is true for the Nouveau GPU-use paths traced here, but the state should ideally be set at population too.

## Findings, ranked

### 1. High: `CPU_FINI` violates the new locking contract

`cpu_mapped` and `sync_pending` are in the “protected by `ttm_bo_reserve()`” group ([`nouveau_bo.h:24-34`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.h:24)), and the new early return consumes both ([`nouveau_bo.c:694-734`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.c:694)). But `nouveau_gem_ioctl_cpu_fini()` calls the helper with no reservation ([`nouveau_gem.c:1048-1063`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:1048)). This is a kernel data race and can theoretically observe `false` and skip the clean.

“A later validation catches it” is sufficient for the legacy pushbuf path, which validates every listed BO, but not as a general UAPI argument. The modern EXEC path locks the VM and validates only BOs on the GPUVM evicted list ([`nouveau_exec.c:102-125`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_exec.c:102), [`drm_gpuvm.c:1473-1513`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/drm_gpuvm.c:1473)); an already-resident BO need not pass `nouveau_bo_validate()` before its next use. `CPU_FINI` may therefore be the relevant handoff.

Fix: reserve the BO in `CPU_FINI`, perform the sync, then unreserve and propagate reservation failure. Merely using `READ_ONCE()` would remove the formal scalar data race but would not serialize the flag with page-array/resource changes. `CPU_PREP` also accesses the page arrays without reserving, but that is a pre-existing issue rather than introduced by this patch.

Practical severity on this exact stack is lower: Mesa's legacy pushbuf path validates every submitted BO, and an actual mmap fault makes `cpu_mapped` sticky. It remains an upstream blocker.

### 2. Medium: a move is not the universal population boundary claimed

For the native BO paths that lead to Nouveau GPU use, the reasoning mostly holds:

| Path | Why the patch catches CPU-dirty contents |
|---|---|
| Initial TT allocation | TTM populates before calling the driver's move ([`ttm_bo.c:121-163`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_bo.c:121)); the move sets `sync_pending`. |
| mmap fault | `cpu_mapped` is set while reserved before the TTM fault/population ([`nouveau_gem.c:42-67`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:42)). |
| GEM/dma-buf vmap | The wrapper marks it before `drm_gem_ttm_vmap`; the DRM vmap contract holds the reservation ([`drm_gem.c:1413-1428`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/drm_gem.c:1413)). |
| Swapout/swapin | Swapout first moves non-SYSTEM BOs to SYSTEM ([`ttm_bo.c:1146-1186`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_bo.c:1146)); return to TT populates/swaps in before the following driver move ([`ttm_tt.c:399-414`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_tt.c:399)). |
| CPU memcpy move | The driver sets the flag before `ttm_bo_move_memcpy()`, whose copy occurs at [`ttm_bo_util.c:146-201`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_bo_util.c:146). |
| Pipelined gutting | Nouveau's eviction callback always supplies a SYSTEM/GART placement ([`nouveau_bo.c:897-912`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.c:897)), so ordinary live Nouveau eviction does not take the zero-placement gutting branch. A resurrected gutted BO also has no resource and must move before Nouveau GPU use. |

However, TTM can populate without moving. `ttm_bo_setup_export()` directly calls `ttm_bo_populate()` ([`ttm_bo.c:1287-1299`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_bo.c:1287)), as do fault/vmap helpers. Fault/vmap are covered by `cpu_mapped`; export is not itself covered by either setter. This is mainly a proof/invariant problem for this patch—export to another device follows dma-buf ownership rules rather than Nouveau pushbuf validation—but the commit message's universal claim is too strong.

More robust design: retain move marking for CPU memcpy moves, and also mark successful native page population in `nouveau_ttm_tt_populate()`. Since `struct ttm_tt` has no BO backpointer, Nouveau could store the `nouveau_bo *` in `struct nouveau_sgdma_be` when it creates the TT. Marking in the callback before generic swap-in is conservative and still covers the copy that follows. Imported/external SG BOs should remain a separate case.

### 3. Low: conservative false positives

The `.access` wrapper marks even reads and failed accesses ([`nouveau_gem.c:70-83`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:70)); it can mark only when `write != 0`. `nouveau_bo_map()` marks before knowing whether `ttm_bo_kmap()` succeeds ([`nouveau_bo.c:669-681`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.c:669)). Faults and vmaps must remain conservative: a readable first fault may install a writable PTE, and vmap exposes no write intent. These cases cost performance but do not threaten correctness.

## Ordering, eviction, and clearing `sync_pending`

Clearing after a successful validate-and-sync is sound while the reservation is held. Legacy `validate_init()` reserves **all** list BOs before `validate_list()` starts ([`nouveau_gem.c:487-596`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:487)); those reservations are retained until the fence is attached and validation is finalized ([`nouveau_gem.c:442-475`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_gem.c:442)). TTM eviction skips a BO whose reservation it cannot acquire ([`ttm_bo_util.c:821-866`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_bo_util.c:821)). Thus validating BO #2 cannot move already-reserved BO #1 out from under the submission. The legacy code also rejects duplicate BO entries.

A failed move leaves `sync_pending=true`, which is safely conservative. A successful hardware move is waited synchronously before returning ([`nouveau_bo.c:947-999`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.c:947)), so the subsequent cache operation does not race the move engine.

Imported SG BOs deliberately have `pages == NULL`: TTM allocates only their DMA-address array ([`ttm_tt.c:138-145`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/ttm/ttm_tt.c:138)), and Nouveau fills it from the attachment SG table ([`nouveau_bo.c:1433-1447`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_bo.c:1433)). Skipping Nouveau's page loop is therefore appropriate; coherency belongs to the dma-buf exporter/attachment protocol. **UNCERTAIN:** re-export and exporters that violate begin/end-CPU-access rules were not exhaustively audited.

## Cortex-A57 speculation

The narrow hardware assumption is right: a speculative load or prefetch can install a **clean** stale line, but it does not make that line dirty and therefore cannot later write stale bytes back over GPU data. Before CPU consumption of GPU-written data, `dma_sync_single_for_cpu(..., DMA_FROM_DEVICE)` invalidates as required; before device reads, the device-side sync cleans CPU writes. The kernel DMA API describes these as ownership transitions and requires the device sync after the software's last modification ([`dma-api.rst:234-257`](/home/marcho/projects/nvidia/vendor/linux/Documentation/core-api/dma-api.rst:234), [`dma-api.rst:394-410`](/home/marcho/projects/nvidia/vendor/linux/Documentation/core-api/dma-api.rst:394)).

The caveat is more important than the microarchitecture: CPU access while the device owns the mapping is outside the DMA API contract. If software writes an already-mapped BO concurrently with GPU use, reservation locking cannot stop stores through established PTEs; userspace synchronization must. **UNCERTAIN:** this review does not claim that arbitrary speculative access is sanctioned by the DMA API, only that clean speculative fills do not create the dirty-writeback hazard this patch tracks.

## Mesa 26.2.5 behavior

The patch should remain useful on GM20B:

- NVC0 maps a miptree directly only when it is non-VRAM, `PIPE_USAGE_STAGING`, and linear ([`nvc0_transfer.c:349-357`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nvc0/nvc0_transfer.c#L349-357)). Ordinary textures/render targets use a temporary `NOUVEAU_BO_GART | NOUVEAU_BO_MAP` staging BO ([lines 372-492](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nvc0/nvc0_transfer.c#L372-492)), then GPU-copy it to the final texture on unmap ([lines 495-525](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nvc0/nvc0_transfer.c#L495-525)). The final texture therefore normally stays unmarked.
- GART buffer resources are mapped directly through `BO_MAP` ([`nouveau_buffer.c:458-480`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/drivers/nouveau/nouveau_buffer.c#L458-480)), so vertex/uniform/dynamic buffers that the CPU touches will become sticky and continue to be cleaned. That is the necessary conservative cost.
- The winsys's `nouveau_bo_map()` installs a persistent mmap and invokes `nouveau_bo_wait()` ([`nouveau.c:755-766`](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L755-766)). `nouveau_bo_wait()` can issue `CPU_PREP` ([lines 909-937](https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.5/src/gallium/winsys/nouveau/drm/nouveau.c#L909-937)); I find no `CPU_FINI` issuance in that file. Therefore an upstream solution cannot rely only on PREP/FINI without changing userspace/ABI expectations.

## Upstream direction and recommended validation

I would keep the kernel optimization rather than mark all textures `COHERENT`. On this platform that selects write-combined CPU mappings ([`nouveau_sgdma.c:67-88`](/home/marcho/projects/nvidia/vendor/linux/drivers/gpu/drm/nouveau/nouveau_sgdma.c:67)); it is sensible for selected upload buffers, but unnecessary for GPU-only textures and potentially poor for CPU reads. Precise write-protect/page-dirty tracking would be substantially more complex, and PREP/FINI-only tracking does not match current Mesa.

Before submission:

1. Reserve in `CPU_FINI` (and consider a separate cleanup of the pre-existing unlocked `CPU_PREP`).
2. Encode native population as a dirty-generation event, or narrow and prove the move-based invariant in comments.
3. Add temporary counters for BOs/bytes synced versus skipped, split by `cpu_mapped` and `sync_pending`; confirm final textures/render targets dominate the skipped bytes.
4. Exercise: persistent mapped buffer writes across submits, texture staging upload/readback, forced TTM swap/eviction, fbdev/DRM-client vmap, native PRIME export/scanout, imported dma-buf, and a small EXEC + `CPU_PREP/CPU_FINI` test. Compare rendered checksums, not only FPS.

With those changes, the sticky-mapping approach is defensible as a deliberately conservative first optimization: it preserves the existing clean on every GPU handoff for anything the CPU can access, while eliminating the clearly unnecessary full-cache walks for GPU-only resources.
