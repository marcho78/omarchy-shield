# Darcy cboot failure triage

## Ranking

1. **(f) U-Boot starts, then faults/resets before video — most likely.** Recovery boot disconnects USB and later returns as fastboot, unlike the wedged `fastboot boot` path. The load address is right, and no U-Boot output does not prove non-entry: failure can precede framebuffer probe. Prime suspects are generic Tegra early init (timer/UART/clock/XUSB), an exception-level assumption, or x0/DT handling.

2. **(a) raw-kernel path bug — possible, but not “always gunzips.”** Static disassembly of this device's exact `recovery/9.1.1/blob-parts/00-EBT.bin` contradicts mandatory gzip: `0x1415c-0x141f8` matches compression magic; no match returns to a raw copy at `0x3cf4-0x3d1c`. Gzip is still a cheap alternate path worth testing.

3. **(e) AVB/custom-image rejection — possible but lower.** The EBT contains AVB verification paths, yet `unlocked: Yes` and `secure: No` should make verification failure non-fatal. Absence of an orange screen is not diagnostic. **UNCERTAIN:** NVIDIA may apply a recovery-specific policy.

4. **(b) 24 MiB ramdisk limit — unlikely.** EBT compares the aligned ramdisk size with `0x0c800000` (200 MiB) at `0x3d2c-0x3d58`; the practical limit here is the 25.5 MiB partition.

5. **(c) ramdisk-content validation — very unlikely.** The same loader copies ramdisk bytes at `0x40b8-0x40d4` and sets `linux,initrd-*`; I found no cpio/initramfs parsing. AVB of the whole boot image is separate.

6. **(d) ARM64 `image_size` rejection — least likely.** The loader uses Android-header `kernel_size`, reserves a `0x02f80000` (47.5 MiB) decompression target (`0x4004-0x4028`), and does not appear to consume the ARM64 header's `image_size`. **UNCERTAIN** because this is symbol-less static reverse engineering.

## Minimum experiment tree

1. **Gzip U-Boot + 1 MiB deterministic-random ramdisk.** This changes compression and removes the alleged size limit while retaining invalid ramdisk content.
   - If it boots, content validation is disproved. For diagnosis only, retry **raw U-Boot + the same 1 MiB ramdisk**: success implicates 24 MiB; failure implicates the raw path. Operationally, simply keep gzip and proceed.
   - If it still returns to fastboot, stop varying ramdisks: gzip, size, and likely content are not the issue.

2. On failure, boot a **tiny gzip-compressed, valid ARM64-Image canary with no ramdisk** whose only action is a PSCI `SYSTEM_OFF`, then loops. Power-off proves cboot accepted the image and transferred control; the fault is U-Boot. Return to fastboot points to cboot/AVB/header handling. **UNCERTAIN:** if `SYSTEM_OFF` is unsupported, “USB remains disconnected until watchdog” is the weaker success signal.

3. Only if the canary runs, test U-Boot with a darcy chainload mode that skips generic Tegra clock/timer/UART/XUSB init. That single test targets the remaining high-probability cluster.

## Cboot notes

The exact Shield EBT is more authoritative than Jetson analogies: it advertises gzip/zlib and LZ4 handlers, raw fallback, fixed kernel/ramdisk placement, and the limits above. I could not verify a public `cboot_src_t21x`; NVIDIA's [R32.7.5 page](https://developer.nvidia.com/embedded/linux-tegra-r3275) publishes CBoot source for newer Tegra families, not T210.

Treat `fastboot boot` as a separate firmware defect: [andreiw/shieldTV_loader](https://github.com/andreiw/shieldTV_loader) explicitly says it is broken on newer SHIELD firmware. Staying enumerated but unresponsive matches that report and says nothing about U-Boot.
