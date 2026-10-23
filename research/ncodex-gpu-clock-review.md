# GM20B clock/time-out, Mesa crash, terrain, and Tegra-wrapper review

## Bottom line

There are two unresolved kernel-level explanations, and the existing test does **not** distinguish them:

1. `simple_ondemand` lets a bursty command stream spend too much time at very low frequency, so userspace fills the GPFIFO faster than the GPU consumes it; or
2. one of GM20B's live NAPLL/voltage transitions intermittently stops forward progress.

The one-second pause itself is not a one-second reclock. It is exactly the software timeout in `nvif_chan_gpfifo_wait()` (`vendor/linux/drivers/gpu/drm/nouveau/nvif/chan.c:55-91`) after the FIFO lacks enough free entries for one million one-microsecond polls. Pinning 998.4 MHz removes both low-frequency service and transitions, so it proves that clock policy is causal but not which of the two mechanisms is responsible.

For a reliable machine today, 998.4 MHz is the only proven setting. For the intended long-term policy, first test fixed 537.6 and 614.4 MHz. If either is clean, fixed 537.6 MHz is the best provisional low-power point because it is the fastest state still at the 838 mV floor; 614.4 MHz is the next candidate if 537.6 is not fast enough. Those choices are **UNCERTAIN until the fixed-frequency load sweep is run**. Do not make `simple_ondemand + min_freq` permanent until the transition test below shows that live switching is safe.

Separately, Mesa 26.2.5 has a real error-propagation defect: `pushbuf_flush()` overwrites the submission error during cleanup and `nouveau_pushbuf_kick()` ignores the flush result. I do **not** see proof that the failed-submit cleanup itself frees the pointer later seen in `x27`; the exact UAF/corruption claim is **UNCERTAIN** without disassembling the exact built library at `pushbuf_flush+0x34`.

## 1. Clock path and why the lag is one second

### What the code actually does

- GM20B counts GR/CE2 busy cycles (`gk20a_devfreq.c:87-118`) and samples/reset them every 50 ms (`:151-179`, `:253-259`). `simple_ondemand` jumps straight to maximum above 45% busy, holds only in the narrow 40–45% band, and otherwise computes a new target from the latest sample (`drivers/devfreq/governor_simpleondemand.c:56-82`). A bursty compositor/benchmark can therefore move several states every sample; there is no multi-sample hysteresis.
- The target converts the requested frequency to a pstate and synchronously calls `nvkm_clk_ustate()` for DC and AC (`gk20a_devfreq.c:182-205`). `nvkm_clk_ustate()` schedules `nvkm_pstate_work()` and waits for it (`clk/base.c:301-345`, `:525-534`).
- There is **no channel/engine idle or quiesce call in that path**. `nvkm_pstate_work()` calls `nvkm_pstate_prog()` directly (`clk/base.c:316-332`), which raises voltage, programs the clock, then lowers voltage (`clk/base.c:160-207`).
- GM20B normally changes NDIV with the hardware dynamic ramp and explicitly waits at most 500 microseconds for that ramp (`gm20b.c:266-319`). If M or PL must change, it slides down, switches the GPC clock to bypass, disables/reprograms/re-enables the PLL, and slides up (`gm20b.c:323-461`). Voltage changes can add an interim safe-frequency transition and reprogram the DVFS coefficients (`gm20b.c:573-635`); the regulator call is at `volt/gk20a.c:108-136`.

Thus the code does not intentionally stall the engine for a second. Its explicit PLL waits are sub-millisecond per slide; regulator latency is **UNCERTAIN**, but there is no one-second wait in this clock path. The one second is the FIFO-space watchdog: Nouveau validates the BOs, then waits for `req->nr_push + 1` slots (`nouveau_gem.c:834-869`), while `nvif_chan_gpfifo_wait()` repeatedly reads GET and times out after 1,000,001 polls (`nvif/chan.c:79-89`). This proves that GET did not advance enough for a full second; it does not prove why.

The full PLL sequence keeps a bypass clock rather than deliberately gating GPC, and its comments describe several transitions as glitchless (`gm20b.c:333-340`, `:367-419`). That makes ordinary low-frequency starvation at least as plausible as a broken transition. Conversely, changing M/PL/voltage while channels are live, with no software quiesce, remains a credible GM20B-specific defect. **UNCERTAIN:** current evidence cannot rank those two more strongly.

One additional weakness is that a PLL-programming failure is not propagated back to devfreq: `nvkm_pstate_work()` only logs the error (`clk/base.c:326-331`), while `nvkm_pstate_calc()` returns zero after the wait (`:337-345`), and `clk->pstate` is assigned before programming completes (`:282-298`). No such `error setting pstate` message appears in the supplied logs, so this is not evidence that it happened here.

I compared the relevant files with current upstream: `gk20a_devfreq.c`, `gm20b.c`, and `nvif/chan.c` are still identical; the only current `clk/base.c` difference is an unrelated pstate-index bounds check. I also found no directly matching upstream report/fix in the exact-string searches. That is not proof none exists. Primary source: [Linux GM20B devfreq](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/nouveau/nvkm/subdev/clk/gk20a_devfreq.c), [GM20B clock programming](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/nouveau/nvkm/subdev/clk/gm20b.c).

### Smallest discriminating test matrix

Run the same glmark2 workload and record `nv50cal_space`, frame-time percentiles, score, temperature and wall power:

1. Fixed `userspace` at 76.8, 537.6, 614.4 and 998.4 MHz. If fixed-low fails while a higher fixed state is clean, this is service-rate/backlog, not reclocking. A binary search through the remaining states finds the minimum clean floor.
2. With two individually clean states, alternate them every 50 ms during `gpu-smoke`/glmark2. Prefer 614.4 ↔ 998.4 MHz because both should have ample throughput. If fixed endpoints are clean but alternation causes a timeout, the live transition is implicated.
3. Only if alternation is clean, restore `simple_ondemand` with `min_freq` set to the lowest clean fixed state. Compare 50, 200 and 500 ms `polling_interval`. A longer interval may reduce flapping, but it is not a valid cure for an unsafe transition.

Correlate kernel timestamps with devfreq's `trans_stat` and the `devfreq_frequency` tracepoint if exposed. A once-per-second `cur_freq` sample is too sparse to describe a 50 ms governor.

## 2. Recommended policy and persistence

The later project measurements materially change the power trade-off: default idle is 5.83 W, fixed 614.4 MHz is 6.34 W, and fixed 998.4 MHz is 8.08 W (`NOTES.md:1763-1771`). Therefore:

- **Immediate known-good workaround:** fixed 998.4 MHz. It costs about 2.25 W at idle versus default, but it is the only tested setting with zero rejected submissions.
- **Likely deployment choice, conditional on the tests:** fixed 537.6 MHz, then fixed 614.4 MHz if performance or FIFO margin is inadequate. Fixed avoids the still-unresolved transition question. **UNCERTAIN:** neither is yet demonstrated clean under the full workload.
- **Best eventual adaptive policy, only if transition testing is clean:** `simple_ondemand` with `min_freq=537600000` (or the measured minimum-clean state). The documented `min_freq` constraint overrides governor requests, while retaining 998.4 MHz boost (`Documentation/ABI/testing/sysfs-class-devfreq:74-92`). The 45/5 thresholds are driver data, not sysfs-tunable knobs (`gk20a_devfreq.c:284-293`); `polling_interval` is tunable (`sysfs-class-devfreq:94-107`).

For persistence, use a udev rule on the devfreq device-add event or a small systemd oneshot ordered after the device exists. Match by `/sys/class/devfreq/*/name` rather than assuming the path, although the measured instance is `57000000.gpu`. A udev-triggered service is preferable because it also reapplies settings after module/device recreation. A boot-only `tmpfiles.d` write can race device creation, and `nouveau.config` has no devfreq governor/minimum key. Debugfs `pstate` is the wrong interface because devfreq's next `nvkm_clk_ustate()` overwrites it (`gk20a_devfreq.c:196-197`). The standard ABI is documented in [Linux's devfreq sysfs documentation](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-class-devfreq).

Before choosing the final state, measure: idle and sustained wall power; GPU rail voltage; temperatures/fan; `nv50cal_space` count; score and p50/p95/p99 frame time; time/transition count per state; and real Hyprland/Quickshell plus video playback. Score alone hides one-second stalls.

## 3. Mesa rejected-submit handling and the crash

The concrete error loss is in Mesa 26.2.5's `src/gallium/winsys/nouveau/drm/nouveau.c`:

1. `pushbuf_submit()` returns the ioctl error after printing `kernel rejected pushbuf` (`nouveau.c:1148-1224`).
2. `pushbuf_flush()` stores that result in `ret`, but then overwrites `ret` with each successful `cli_kref_set()` while dropping BO references (`:1227-1244`). It therefore normally converts `-ETIMEDOUT` back to zero. It clears the krec and moves buffer-context lists regardless of submission success (`:1246-1259`).
3. Even if that were fixed, `nouveau_pushbuf_kick()` discards `pushbuf_flush()`'s return and returns only the subsequent validation result (`:1693-1698`). Several internal auto-flush sites also ignore it (`:1348-1355`, `:1483-1491`, `:1536-1543`, `:1747-1753`). Current Mesa main still has this code: [nouveau winsys](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/gallium/winsys/nouveau/drm/nouveau.c).

This explains why rendering continues after a kernel rejection and why software/GPU state can diverge. The kernel exits before posting the new GPFIFO entries and creates no fence (`nouveau_gem.c:864-881`, `:934-950`); userspace nevertheless discards the batch and its references. It does **not**, by itself, demonstrate that cleanup dereferences freed memory: the implementation allocates one krec (`nouveau.c:1550-1583`), the krec owns BO references until cleanup, and the loop's `kref` array is in the still-live krec.

The first correctness patch should preserve the submit error and propagate it:

```c
int submit_ret = pushbuf_submit(push, push->channel);
/* cleanup, retaining a separate cleanup_ret */
return submit_ret ? submit_ret : cleanup_ret;

/* nouveau_pushbuf_kick */
ret = pushbuf_flush(push);
if (ret)
   return ret;
return pushbuf_validate(push, false);
```

Then audit every ignored internal flush result. Merely returning early while leaving a full krec is unsafe unless all those callers stop mutating it; otherwise the fixed error handling can turn into an array overrun. A robust design either (a) retains the rejected single krec and retries it without appending more commands, or (b) marks the channel/context lost, discards it, and prevents all later submission. Blindly retrying is **UNCERTAIN** because the legacy API was not designed around recoverable submission failure, although this particular timeout occurs before the GPFIFO post.

For the observed segfault, map the exact PC with the exact unstripped `.so` (`objdump -drC`/`addr2line`) and reproduce with an ASan build if practical. `ldr x0,[x27,#72]` only proves that the compiler treated garbage `x27` as a structure pointer. Which structure it was—pushbuf, krec, BO, or another inlined object—is **UNCERTAIN** from the symbol-plus-offset alone. Error propagation is a necessary fix, but claiming it is the demonstrated UAF fix would overstate the evidence.

## 4. Why terrain is special, and how to isolate the flicker

Terrain is not a simple draw. Each frame renders a 256×256 procedural noise height map and normal map, a 256×256-cell terrain (393,216 non-indexed vertices), then defaults to bloom and two full-resolution tilt-shift passes (`scene-terrain.cpp:62-84`, `:87-163`, `:331-339`; `scene-terrain/terrain-renderer.cpp:233-245`). The vertex shader performs two texture fetches per vertex and the fragment shader samples several maps. More importantly, every renderer whose minification filter uses mipmaps calls `glGenerateMipmap()` after rendering (`scene-terrain/base-renderer.cpp:79-87`); terrain and several post-process targets are configured with `GL_LINEAR_MIPMAP_LINEAR` (`scene-terrain.cpp:75-84`, `:87-114`). This can serialize multiple render-to-texture/mipmap/pass dependencies each frame.

There is no evidence of a CPU rasterizer fallback: the renderer is Nouveau/Tegra and the formats are ordinary RGBA8/depth16 (`base-renderer.cpp:114-163`). **UNCERTAIN:** a Nouveau utility fallback for mipmap generation, fixed EMC/memory bandwidth, CPU submission overhead, or a synchronization point may dominate and therefore make GPC frequency largely irrelevant. The large vertex stream, many texture reads, and post-process traffic make fixed memory bandwidth a particularly plausible alternative to a shader-core bottleneck.

Implicit nouveau→tegra synchronization is not my first suspect when submissions succeed. Nouveau adds the completion fence to every written BO reservation (`nouveau_gem.c:930-950`; `nouveau_bo.c:1472-1482`), and Tegra's plane calls `drm_gem_plane_helper_prepare_fb()` (`tegra/plane.c:200-213`), which attaches the reservation's write fence to plane state (`drm_gem_atomic_helper.c:97-170`). A rejected submission has no fence and can display incomplete content, but the reported max-clock run had no rejections and still flickered. Same-context FBO dependencies also have GL ordering before presentation.

Test in this order:

1. Run four terrain variants: both effects off; bloom only; tilt-shift only; both. The scene exposes both switches (`scene-terrain.cpp:219-229`). This immediately separates the huge terrain draw from mipmap/post-processing.
2. Repeat at a lower mode/viewport. Strong resolution scaling points to fill/memory/postprocess; weak scaling points to CPU/submission/synchronization.
3. Time `eglSwapBuffers`, DRM ioctls and CPU usage (`strace -T`/`perf` if already present). Add GPU timer queries around each pass in an instrumented diagnostic build. A 69 ms CPU ioctl/wait is different from 69 ms queued GPU work.
4. Add `glFinish()` immediately before swap as a diagnostic only, and compare mailbox versus FIFO. If only `glFinish()` removes flicker, investigate dma-resv fence export/wait; if it persists, capture/read back the completed render target before scanout. Correct readback plus bad HDMI means display/presentation; bad readback means rendering.
5. Disable per-frame mipmap generation or change intermediate min filters to `GL_LINEAR` in a throwaway diagnostic build. This is the highest-value terrain-specific experiment because the source regenerates mip chains after several passes. Compare the same scene on a known-good GPU at ~15 fps before treating moving fine-detail aliasing as a Tegra defect. Source: [glmark2 terrain scene](https://github.com/glmark2/glmark2/blob/2023.01/src/scene-terrain.cpp), [base renderer](https://github.com/glmark2/glmark2/blob/2023.01/src/scene-terrain/base-renderer.cpp).

## 5. Review of the five Tegra follow-up commits

All five diffs pass `git diff --check`. Their intended fixes are correct:

- `756f9c2` correctly forwards the clear scissor (`tegra_context.c:754-764`).
- `6d0d3da` correctly unwraps query-result destinations, SSBOs, images, indirect grid resources and bindless inputs (`tegra_context.c:154-168`, `:610-655`, `:1081-1097`, `:1188-1225`). The fixed-size arrays match Gallium maxima; the assertions rely on the trusted Gallium contract. OpenCL `set_global_binding` and `grid_info.globals` remain explicitly unwrapped (**still broken**, but not a normal compositor path) at `:1068-1078` and `:1088`.
- `5833ad5` correctly closes the display-side GEM handle that `drmPrimeFDToHandle()` created (`tegra_screen.c:131-164`, `:329-343`). Ignoring close failure is normal in a destructor.
- `89c4bc2` correctly stops publishing absent frontbuffer/native-fence hooks, wraps resources returned by optional constructors, unwraps `flush_frontbuffer`, and publishes the complete memobj trio only when Nouveau supplies all three (`tegra_screen.c:224-258`, `:346-364`, `:521-551`, `:603-639`; `tegra_context.c:1376-1379`). NVC0 26.2.5 supplies all three memobj hooks, so the copied `caps.memobj` is consistent on darcy.
- `1be240d` correctly handles a NULL sampler view and NULL underlying transfer (`tegra_context.c:862-947`). **UNCERTAIN edge:** if an underlying map ever returns `map == NULL` but a non-NULL transfer, the wrapper still returns NULL while leaving a live transfer for the caller to unmap; check the Gallium contract/implementations before broadening the condition.

### Remaining compositor-facing defects

1. **High, conditional crash:** Tegra still publishes `set_device_reset_callback` and `dump_debug_state` unconditionally and each wrapper calls the inner hook unconditionally (`tegra_context.c:1144-1160`, `:1411-1414`). NVC0 26.2.5 provides `get_device_reset_status` but neither of those two hooks (`nvc0_context.c:184-188`, `:449-463`). Apply the same conditional-publication rule used for native fences. Robust-context/reset handling can hit this in desktop applications.
2. **Medium-high for video clients:** multi-plane resource chains are not safely translated. `resource_from_handle()` passes an outer `template->next` to Nouveau (`tegra_screen.c:260-284`), and NVC0 copies the template verbatim (`nv50/nv50_miptree.c:399-430`). An inner resource can therefore contain an outer Tegra pointer. Conversely, generic wrapping copies the inner `.next` unchanged (`tegra_screen.c:224-245`). NV12/P010 dma-buf import should remain untrusted until every plane in both directions is wrapped/unwrapped correctly. Exactly how current EGL import constructs that chain is **UNCERTAIN**.
3. **Medium:** an imported or memobj-created resource with `PIPE_BIND_SCANOUT` never receives a display-side handle, yet `resource_get_handle(WINSYS_HANDLE_TYPE_KMS)` returns `resource->handle/stride/modifier` and `true` (`tegra_screen.c:260-326`). Those fields are zero for such resources. The ordinary compositor swapchain creation path is fixed, but imported direct-scanout/export paths are not.
4. **Medium/UNCERTAIN:** modifier queries forward Nouveau's list without intersecting it with Tegra KMS plane `IN_FORMATS` (`tegra_screen.c:485-518`). Prove each advertised modifier with allocate→render→AddFB2WithModifiers→pageflip; do not assume renderer support equals display support.
5. **Low:** `tegra_screen_create()` opens `gpu_fd` itself and closes it on creation failure (`tegra_screen.c:562-589`), but `tegra_screen_destroy()` destroys the inner screen without closing that fd (`:49-55`). Unless the inner screen takes ownership—**UNCERTAIN**, and Gallium normally leaves caller fds owned by the caller—this leaks one render fd per screen lifetime/recreation.

These remaining items do not invalidate the successful smoke/glmark result. Before calling Hyprland/media use robust, I would fix item 1, test the fixed-frequency matrix, and gate multi-plane/direct-scanout video until items 2–4 have dedicated coverage.
