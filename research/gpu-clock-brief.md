# Brief: darcy's GPU on the TV: clock flapping, a Mesa crash, a slow scene

**Analysis only.** Don't change files or touch the device. Cite `file:line`
(kernel: `~/projects/nvidia/vendor/linux`, 7.2.11; Mesa 26.2.5 sources at
gitlab.freedesktop.org tag `mesa-26.2.5`; some are copied to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/mesa-tegra-26.2.5/`).
Say plainly what is a guess. Earlier rounds had confident wrong claims.

## Measured today, with Mesa 26.2.5 + MR !45355 (your last review's go-ahead)

All runs: nouveau loaded by hand, tegra-drm on HDMI 1920x1080@60, Mesa from
makepkg's package tree by LD_LIBRARY_PATH and
`__EGL_VENDOR_LIBRARY_FILENAMES`.

1. `tools/gpu-smoke.c` (KMS + GBM + EGL + GLES2, colour fade + triangle):
   1200 and 1800 frames, clean. The user confirms the picture and colours.
2. `glmark2-es2-drm` (no `--fullscreen`), GPU on its default devfreq
   governor: all scenes run, score 119, but **28-42 "nouveau: kernel
   rejected pushbuf: Connection timed out"** per run, the kernel logging
   `nv50cal_space: -110` each time (`nouveau_gem.c:864-869`;
   `nvif_chan_gpfifo_wait` busy-waits 1,000,000 × udelay(1),
   `nvif/chan.c:55-91`). One run then **segfaulted** in the bump scene:
   `eglSwapBuffers` → `dri_flush` → `nouveau_fence_wait` →
   `_nouveau_fence_wait` → `nouveau_fence_kick` → `nouveau_pushbuf_kick` →
   `pushbuf_flush.isra.0+0x34`, `ldr x0, [x27, #72]` with
   `x27 = 0x2833b42c30b5302c` (names from the unstripped build's symbols).
3. The GPU's clock (sampled once a second during gpu-smoke) jumps every
   second among 76.8, 153.6, 307.2, 384, 460.8 and 998.4 MHz, vdd-gpu 838
   or 1094 mV. That's `gk20a_devfreq.c`: `simple_ondemand`, polling 50 ms,
   upthreshold 45, downdifferential 5 (`:253-292`), calling
   `nvkm_clk_ustate()` (`:196-197`), which also overrides the debugfs
   `pstate` file. Idle, it stays at 76.8 MHz.
4. **Pinned at 998.4 MHz** (`userspace` governor, `set_freq`): **no rejected
   pushbuf, no crash**, score 308 (build 467, texture 381, shading 371, bump
   410, effect2d 215, terrain 15 fps), CPU ≤ 53 °C, GPU ≤ 50 °C, 10.5-12.4 W
   (VDD_SYS). No kernel messages.
5. **terrain** runs at 15 fps (69 ms a frame) both at 76.8 MHz and at 998.4
   MHz, and the user sees it **flicker** (the other scenes look fine).
   tegra-drm's `prepare_fb` uses `drm_gem_plane_helper_prepare_fb`
   (`tegra/plane.c:200-209`); glmark2's DRM "mailbox" flip logic
   (`native-state-drm.cpp:134-210`) looks right to me.

## Questions

1. Why does devfreq reclocking make the GPU fall a full second behind?
   Follow `gk20a_devfreq` → `nvkm_clk_ustate` → `nvkm_pstate_work` →
   `gm20b_clk` programming (NAPLL, slide, voltage via `gm20b_volt` / the
   PWM regulator) while channels are busy. Is the engine stalled or idled
   per reclock, and could 50 ms polling flap continuously? Upstream reports
   or fixes?
2. The clock policy for this box (media center, 1080p desktop, video on the
   CPU): a fixed clock (which?), or `simple_ondemand` with a raised
   `min_freq` (sysfs) or other knobs? How do we make it persistent and
   reproducible (udev rule, tmpfiles.d, `nouveau.config`)? What would you
   measure first (idle power at 998 vs 76.8 MHz is next on my list)?
3. The Mesa crash: where in Mesa 26.2.5's nouveau winsys
   (`src/gallium/winsys/nouveau/drm/nouveau.c`, `pushbuf_flush`,
   `pushbuf_submit`, `nouveau_pushbuf_kick`) does a rejected submission
   leave freed or stale state that a later kick dereferences? Fix?
4. terrain: what in glmark2's terrain scene would be bound by neither GPU
   clock (CPU fallback, a format nouveau can't render, readback, a
   synchronous wait), and what could make it flicker on nouveau + tegra
   (implicit sync between nouveau and tegra-drm, render-to-texture
   ordering)? Give a test plan.
5. Review my five follow-up tegra patches: the git repository
   `/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/mesa-work`,
   `git log 765a7a3..HEAD` (scissor; unwrapping buffers, images, queries,
   grids, handles; closing the display GEM handle; hooks nouveau lacks plus
   memobj; failure paths). Correctness, and anything still missing that a
   compositor uses.

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-gpu-clock-ncodex.md`
and reply with only that path.
