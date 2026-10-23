# Mesa 26.2.5 Tegra wrapper review

## Bottom line

MR !45355 is sufficient to justify a **controlled, staged run of `gpu-smoke`**, but it does not make the Tegra wrapper generally sound. The ordinary Hyprland render path (output BO creation, framebuffer bind, clear/draw, sampler view, swap, KMS handle) is likely to get substantially farther. I would not yet treat this package as a safe drop-in for Xwayland, browsers, or media applications.

The most important additional defects are a leaked Tegra GEM handle for every scanout resource, a falsely advertised memory-object implementation, an unsafe frontbuffer callback, and several still-unwrapped resource-bearing interfaces. None invalidates the diagnosis fixed by !45355.

## 1. Ranked driver findings

### High: scanout resources leak a Tegra DRM GEM handle

`tegra_screen_import_resource()` imports the Nouveau dma-buf into the Tegra KMS fd with `drmPrimeFDToHandle()` and stores the resulting GEM handle (`tegra_screen.c:131-164`). `tegra_screen_resource_destroy()` releases only the Nouveau resource and wrapper; it never performs `DRM_IOCTL_GEM_CLOSE`/`drmCloseBufferHandle()` on `resource->handle` (`tegra_screen.c:316-325`). Both normal scanout creation and modifier creation take this path (`tegra_screen.c:200-205`, `443-452`).

That is a persistent per-fd kernel-object leak until the display fd closes. A compositor's steady swapchain may hide it, but output recreation, mode changes, and modifier-backed client allocations can accumulate it. Close the nonzero display GEM handle in resource destruction, after users of the framebuffer have released their references.

### High, conditional: `memobj` is advertised but only one-third implemented

The wrapper copies all Nouveau capabilities, including `caps.memobj`, wholesale (`tegra_screen.c:591-594`); NVC0 sets `memobj = true` (`src/gallium/drivers/nouveau/nvc0/nvc0_screen.c:307`). Tegra forwards only `memobj_create_from_handle` (`tegra_screen.c:503-512`, `589`) and leaves `memobj_destroy` and `resource_from_memobj` NULL. The GL state tracker enables `EXT_memory_object[_fd]` from that cap (`src/mesa/state_tracker/st_extensions.c:1106-1110`) and calls `screen->resource_from_memobj` without a NULL check (`src/mesa/state_tracker/st_cb_texture.c:3437`). Object deletion likewise needs `memobj_destroy`.

This is a deterministic NULL-call/crash when an application uses the advertised extension. It is not expected during basic compositor startup, but it is credible for a browser or interop workload. The safe short-term action is to clear the outer `caps.memobj`; the complete fix forwards destroy and wraps the resource returned by Nouveau.

### High, conditional: frontbuffer and two resource constructors are false/invalid wrappers

- `tegra_screen_flush_frontbuffer()` passes the **outer** `tegra_resource` to Nouveau and calls `screen->gpu->flush_frontbuffer` unconditionally (`tegra_screen.c:328-345`). NVC0 does not install that callback in the reviewed 26.2.5 screen initialization. Thus the outer non-NULL hook both falsely advertises support and, if called, dereferences NULL; if Nouveau later supplies a hook, it still receives the wrong resource type. This is principally an X11/GL frontbuffer risk, not a normal Wayland backbuffer path.
- `resource_create_front` and `resource_from_user_memory` return a raw Nouveau resource after merely changing its `screen` pointer (`tegra_screen.c:224-239`, `268-283`). Later Tegra hooks cast it to `struct tegra_resource`, so use or destruction is unsafe. `resource_create_front` additionally calls an underlying hook that is **UNCERTAIN** to be non-NULL on this exact GM20B setup. Do not publish either outer hook unless its result is wrapped normally.

### Medium-high: common advanced-GL resource arguments remain wrapped

These are concrete type errors, not theoretical interface omissions:

- SSBOs: `tegra_set_shader_buffers` forwards each `.buffer` unchanged (`tegra_context.c:595-605`; field at `p_state.h:660-664`).
- Images: `tegra_set_shader_images` forwards each `.resource` unchanged (`tegra_context.c:607-617`; field at `p_state.h:531-550`).
- Query-buffer results: `tegra_get_query_result_resource` forwards its resource unchanged (`tegra_context.c:154-168`), while NVC0 advertises query-buffer objects and consumes it as an NVC0 resource.
- Compute: `set_global_binding` and `launch_grid` explicitly retain “XXX unwrap” comments (`tegra_context.c:1017-1039`). `pipe_grid_info` has `indirect`, `indirect_draw_count`, and `globals` resource fields (`p_state.h:989-1008`), all of which need local-copy unwrapping.
- Bindless: `create_texture_handle` forwards the outer Tegra sampler view, and `create_image_handle` forwards an image containing an outer resource (`tegra_context.c:1130-1162`).

Basic Hyprland compositing probably uses render targets, textures, vertex/constant buffers, and samplers, all of whose primary paths are unwrapped after !45355 (`tegra_context.c:477-492`, `545-573`, `619-640`, `679-713`). Whether Hyprland 0.56 or Qt Quick selects SSBO/image shaders on GLES 3.2 is **UNCERTAIN**; GTK4/browser workloads make these defects much more likely. Fix SSBO/images and query-result resources before calling the desktop stack robust.

### Medium: `clear` silently drops the scissor

The wrapper accepts the 26.2.5 `scissor_state` but always passes NULL to Nouveau (`tegra_context.c:715-725`). This can clear outside the damage/scissor region. It should not crash, but can produce compositor corruption or flicker when partial rendering is used. Forward the argument.

### Medium-low: map and sampler-view failure paths can crash

`tegra_transfer_map()` allocates its wrapper, calls Nouveau, then unconditionally dereferences `transfer->gpu` in `memcpy()` (`tegra_context.c:866-896`). A failed map/OOM is therefore converted into a segfault and leaks the wrapper. Return NULL and free it if either the map or underlying transfer is NULL.

Similarly, `tegra_create_sampler_view()` dereferences `view->gpu` to inflate its refcount without checking whether Nouveau returned NULL (`tegra_context.c:823-850`). The normal sampler create/bind/release path otherwise keeps an outer resource reference and passes the inner view (`tegra_context.c:836-844`, `545-573`). `u_default_sampler_view_release` and `u_default_resource_release` are correct for releasing the **outer** objects (`tegra_context.c:1315-1319`; `src/gallium/auxiliary/util/u_inlines.h:206-216`, `253-282`). The unusual 100,000,000 private-refcount scheme deserves eventual replacement, but I did not find a normal-path use-after-free from it.

### Medium-low: dma-buf import/export is sound for the main single-plane path, with edges

The intended split-device path is coherent:

1. Nouveau allocates; Tegra exports it as an fd and imports it on the display fd (`tegra_screen.c:131-164`).
2. The wrapper records display handle/stride/modifier and returns those for `WINSYS_HANDLE_TYPE_KMS` scanout requests (`tegra_screen.c:285-314`).
3. FD sharing requests and ordinary imported render resources go to Nouveau (`tegra_screen.c:254-265`, `307-311`).

Remaining edges:

- Imported resources carrying `PIPE_BIND_SCANOUT` have no display-side `handle/stride/modifier` populated, yet the special KMS branch returns those zero-initialized fields (`tegra_screen.c:242-265`, `302-306`). Direct scanout through this particular Gallium export path would fail. Aquamarine may instead create KMS FBs directly from client dma-bufs; that is **UNCERTAIN** and should not excuse the wrapper bug.
- Multi-plane DRI import chains `template->next`; Tegra passes that template to Nouveau without replacing the next outer wrapper with its GPU resource (`tegra_screen.c:242-255`). NVC0 copies the template (`src/gallium/drivers/nouveau/nv50/nv50_miptree.c:427-430`), so its inner plane chain can contain an outer object. Whether NVC0 traverses that chain for every lowered YUV path is **UNCERTAIN**. Treat NV12/video import as unproven.
- Modifier advertisement is copied from Nouveau alone (`tegra_screen.c:467-500`), not explicitly intersected with the Tegra display plane's `IN_FORMATS`. Compatibility of all six advertised block heights on darcy is **UNCERTAIN**; test each advertised scanout modifier.

### Low/dormant: native-fence wrappers lie about callable hooks, but the cap should suppress EGL exposure

Tegra installs `create_fence_fd`, `fence_server_sync`, and `fence_get_fd` wrappers unconditionally (`tegra_context.c:801-821`, `1312-1313`; `tegra_screen.c:372-379`, `575-577`). Those wrappers unconditionally call the corresponding Nouveau hooks. Nouveau 26.2.5's base screen installs only fence reference/finish (`src/gallium/drivers/nouveau/nouveau_screen.c:428-429`), and the reviewed NVC0 context setup does not install native-fd/server-sync hooks (`src/gallium/drivers/nouveau/nvc0/nvc0_context.c:447-477`).

However, NVC0 does not set `caps.native_fence_fd`; the outer cap copy therefore remains false. DRI advertises native-fd fences strictly from that cap (`src/gallium/frontends/dri/dri_helpers.c:80-89`), so `EGL_ANDROID_native_fence_sync` should be absent. If it is advertised at runtime, using it can call NULL through these wrappers (`dri_helpers.c:118-152`, `238-240`) and is a stop sign. Publish these outer hooks only when the corresponding inner hook exists. Merely guarding them does not create explicit-sync support; implicit synchronization must suffice. Whether Hyprland's requested configuration requires explicit sync rather than gracefully falling back is **UNCERTAIN**, but native-fence support should not be made a precondition if the extension is honestly absent.

### Interface-drift check

Of the notable post-25.1 changes, `resource_release` is initialized correctly, the removed surface hooks are addressed by !45355, and the newly stored NIR option arrays are copied (`tegra_screen.c:591-594`). `image_copy_buffer` is unset, but NVC0 also leaves it unset; the threaded-context code requires it only for a render-pass mode (`src/gallium/auxiliary/util/u_threaded_context.c:5558-5563`). `set_resource_label`, timestamp conversion, semaphore/timeline, and VM hooks are optional/capability-gated in this stack. I found no additional unconditional frontend call relevant to the initial compositor path.

## 2. PKGBUILD/package review

The central choices are appropriate: the exact ALARM Mesa version, `nouveau,tegra,softpipe`, no LLVM/Vulkan, X11+Wayland, and DRI GLX (`packages/mesa-darcy/PKGBUILD:10-25`, `44-69`). `VERSION` is also correct: Mesa reads it as the Meson project version and uses it in the libgallium filename (`packages/mesa-darcy/PKGBUILD:34-39`; `src/gallium/targets/dri/meson.build:36-43`), matching Arch's cache-invalidation practice (`alarm-PKGBUILD:244-247`).

Recommended corrections/checks:

1. **Restore Arch's indirect-GLX compatibility symlink.** The stock package creates `libGLX_indirect.so.0 -> libGLX_mesa.so.0` (`alarm-PKGBUILD:391-393`); this package installs Meson's output verbatim (`packages/mesa-darcy/PKGBUILD:74-76`). Direct DRI3 Xwayland should not need it, but omitting a file supplied by the replaced `mesa` package is an avoidable regression.
2. **Make required features explicit:** `egl=enabled`, `gbm=enabled`, `gles2=enabled`, `opengl=true`, `glvnd=enabled`, `shader-cache=enabled`, `xmlconfig=enabled`, and `expat=enabled`. Currently `arch-meson` plus installed dependencies should auto-enable them; that is likely why the build works, but an accidental missing build dependency can silently remove a required feature. Shader cache requires compression and is enabled when zlib/zstd are found (`meson.options:251-273`; `meson.build:1173-1187`, `1812-1816`). XML config is enabled when expat is found (`meson.options:74-80`, `802-808`; `meson.build:1838-1855`).
3. **Align compiler-runtime dependency names with the same ALARM snapshot.** The custom package says `gcc-libs` (`PKGBUILD:18-19`), whereas ALARM 26.2.5 uses `libgcc` and `libstdc++` (`alarm-PKGBUILD:295-315`). Which naming the device repository presently accepts is **UNCERTAIN**; `makepkg` will expose it, but the recipe should match its source distribution. `libelf` is in stock Mesa; whether this narrow no-LLVM build links it is **UNCERTAIN**. Decide from `readelf -d`/`namcap`, not by copying the broad package dependency list.
4. `provides=(mesa=... mesa-libgl=... opengl-driver)` plus `conflicts=(mesa mesa-libgl)` is suitable for satisfying `libglvnd`'s `mesa` dependency (`PKGBUILD:22-25`). There is no need to provide disabled VA/Vulkan packages. Rebuild or pin it when ALARM raises the required Mesa version.
5. The installer removes `mesa` with `pacman -Rdd` before installing the replacement (`scripts/19-build-mesa.sh:64-69`). If the second transaction fails, the machine has no Mesa and package dependency checks were bypassed. Keep the stock package cached, validate the local package with `pacman -T`/`namcap`, and make rollback explicit. This is an installation-transaction risk, not a PKGBUILD-content defect.
6. For bring-up, stripping symbols and compiling out assertions (`options=(!debug)`, `b_ndebug=true`; `PKGBUILD:26`, `45-46`) is counterproductive. At least retain a symbolized one-off package until the wrapper fixes settle; three gigabytes of RAM affects build time, not the value of usable traces.

Before replacement, inspect the staged package for `tegra_dri.so`, `nouveau_dri.so`, `swrast_dri.so`, `dri_gbm.so`, the GLVND EGL vendor JSON, and the versioned libgallium target, then run `readelf -d`/`lddtree` to derive runtime dependencies.

## 3. Short post-build gate

Run in this order and stop at the first failure:

1. **Existing render/scanout test:** run staged `tools/gpu-smoke` through at least hundreds of swaps, followed by non-fullscreen `glmark2-es2-drm`. This proves the !45355 framebuffer/clear fix plus shaders, vertex upload, GBM swap, KMS-handle export, and page flips (`tools/gpu-smoke.c:121-190`, `192-285`). Watch `dmesg` for Nouveau faults and Tegra IOMMU/DRM errors.
2. **Modifier allocation-to-scanout test:** enumerate XRGB8888 via `eglQueryDmaBufFormatsEXT`/`eglQueryDmaBufModifiersEXT`; explicitly create, render to, export, `AddFB2WithModifiers`, and page-flip one linear BO and each advertised NVIDIA block-linear modifier. `gpu-smoke`'s generic `gbm_surface_create` does not prove the advertised modifier intersection.
3. **dma-buf round trip:** export a rendered BO as fd+stride+offset+modifier, import it through `EGL_LINUX_DMA_BUF_EXT` (or `gbm_bo_import` followed by EGLImage), bind it as a texture, sample into a second framebuffer, and verify pixels with `glReadPixels`. Re-export the imported image and compare metadata. This directly covers `resource_from_handle`, sampler views, modifier import, and FD export. Repeat with an independently opened GBM/EGL display; add an NV12 two-plane case before declaring browser/mpv video ready.
4. **Fence truth test:** inspect the EGL display extension string. Expected here: `EGL_EXT_image_dma_buf_import_modifiers` present and `EGL_ANDROID_native_fence_sync` absent. If native-fence is present, exercise create/export/import/server-wait and treat a crash as the known false-wrapper bug. Absence is acceptable for the initial implicit-sync compositor trial.
5. **Throwaway compositor:** after the above, run a small DRM Wayland compositor with GL rendering and software cursor, then a native Wayland EGL client and a dma-buf client. Weston plus `weston-simple-egl`/`weston-simple-dmabuf-egl` is suitable if already available. Only then try Hyprland with `AQ_DRM_DEVICES` and software cursor. After Hyprland is stable, test Xwayland (`glxinfo -B` plus a GLX client), GTK4, and mpv separately; those widen coverage beyond the compositor's basic GL path.

**Decision:** proceed with the staged !45355 build for `gpu-smoke`, but add at least the GEM-handle close, scissor forwarding, memobj masking, and conditional frontbuffer/fence hooks before relying on the machine as a long-running Omarchy/media desktop. Unwrap SSBO/image/query/compute inputs before browser-class workloads.
