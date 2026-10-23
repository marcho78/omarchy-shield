# Brief: Mesa's tegra driver on darcy, after the first-draw crash

**Analysis only.** Don't change files or touch the device. Cite `file:line`.
Say plainly what is a guess, and check claims in the source: earlier rounds
had confident wrong claims.

## What happened (measured today)

On the SHIELD (Tegra210, GM20B, Arch Linux ARM, kernel 7.2.11, Mesa
26.2.5-arch1.1), nouveau loaded by hand, tegra-drm driving HDMI:
- `glmark2-es2-drm --fullscreen` fails before drawing: a glmark2 2023.01 bug
  (`canvas-generic.cpp:269-276`: with --fullscreen it never creates the GBM
  surface). Without `--fullscreen` it segfaults in libgallium.
- `tools/gpu-smoke.c` (repo; KMS + GBM + EGL + GLES2, prints each step)
  passes `gbm_create_device`, `gbm_surface_create(XRGB8888, SCANOUT |
  RENDERING)`, `eglInitialize` (EGL 1.5, Mesa), the config,
  `eglCreateContext`, `eglCreatePlatformWindowSurface`, `eglMakeCurrent`,
  `glGetString` ("tegra", "OpenGL ES 3.2 Mesa 26.2.5-arch1.1"),
  `glViewport`, then **segfaults in the first `glClear`** (SEGV_MAPERR,
  five libgallium frames under the GL call; no symbols on ALARM).

**Cause, checked in the source:** Mesa commit 2eb45daa ("gallium:
de-pointerize pipe_surface", 2025-05-23) made
`pipe_framebuffer_state.cbufs[]`/`zsbuf` `struct pipe_surface` by value
(`p_state.h:411-452` at mesa-26.2.5) and deleted tegra's unwrapping in
`tegra_set_framebuffer_state`, so nouveau gets tegra's wrapped
`tegra_resource`s as `.texture`. 1af551ed ("tegra: delete pipe_context
surface hooks", 2026-03-23) removed `tegra_create_surface`, yet
`tegra_clear_render_target`/`tegra_clear_depth_stencil` still cast the
surface to `tegra_surface`. Upstream: issue #14640 (Jetson TX1, open since
2026-01) and **MR !45355** "tegra: unwrap framebuffer and clear surfaces"
(Igor Pecovnik, tested on a Jetson Nano with 26.1.6; open, not merged). Its
patch is `patches/mesa/0001-tegra-unwrap-framebuffer-and-clear-surfaces.patch`;
it applies cleanly to 26.2.5.

**Being built now:** `packages/mesa-darcy/PKGBUILD` (26.2.5 + that patch;
gallium nouveau,tegra,softpipe; no Vulkan, no LLVM; x11+wayland, glx=dri,
GLES1 off like Arch; provides mesa/mesa-libgl/opengl-driver, conflicts
mesa), built on the SHIELD by `scripts/19-build-mesa.sh`, tested from the
package tree before it replaces ALARM's mesa.

Mesa 26.2.5's tegra sources are copied to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/mesa-tegra-26.2.5/`
(`tegra_context.c`, `tegra_screen.c`, `tegra_resource.h`, `p_state.h`,
`meson.options`, the two commits' diffs, ALARM's PKGBUILD). For anything
else, read Mesa at tag `mesa-26.2.5` on gitlab.freedesktop.org.

## Next on the device

Plain Hyprland 0.56.2 (aquamarine 0.15.1) from a VT with
`AQ_DRM_DEVICES=/dev/dri/by-path/platform-50000000.host1x-card` (tegra-drm),
software cursor first; later Xwayland, GTK4 apps, mpv, a browser (the box is
a media center).

## Questions

1. With MR !45355 applied, what else in Mesa 26.2.5's tegra driver is broken
   or unsafe for that stack? Check each wrapper against the 26.2.5 gallium
   interface, for example:
   - `tegra_set_shader_buffers`/`tegra_set_shader_images` pass resources
     without unwrapping
   - `set_global_binding`/`launch_grid` ("XXX unwrap")
   - `resource_release` (`u_default_resource_release`), sampler views
   - transfers, `resource_from_handle`/`resource_get_handle` (dma-buf import
     and export with modifiers), `resource_from_memobj`
   - fences (`create_fence_fd`, `fence_server_sync`, native fence sync for
     explicit sync)
   - `pipe_screen`/`pipe_context` hooks added since 25.2 that st/mesa, the
     DRI/EGL frontend or GBM call without a NULL check, but tegra doesn't set
     or forwards wrongly

   Rank what a compositor actually hits first.
2. Anything wrong or missing in the PKGBUILD for that stack: options, the
   `VERSION`/libgallium name, provides/conflicts against ALARM's mesa
   (`libglvnd` depends on `mesa`), GLX, xmlconfig, the shader cache.
3. A short test list for after the build, beyond `tools/gpu-smoke` and
   glmark2 (no `--fullscreen`): what proves the compositor paths, such as
   dma-buf import with modifiers, `EGL_EXT_image_dma_buf_import_modifiers`,
   and `EGL_ANDROID_native_fence_sync`, before we start Hyprland on the TV?

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-mesa-tegra-<your name>.md`
(`ncodex` or `antigravity`) and reply with only that path.
