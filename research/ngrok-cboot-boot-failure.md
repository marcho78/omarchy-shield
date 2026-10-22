# Darcy cboot vs raw U-Boot (analysis only)

Result 1 is not about the image. `fastboot boot` leaves the gadget up (`0955:b442`, `getvar` hangs): the known break on this firmware (`NOTES.md`; andreiw/shieldTV_loader). Result 3 is the signal: USB drops, then ~7 s later the bootloader is back. cboot left fastboot and the CPU reset. Stock recovery uses this header and reaches "No command", so those addresses are not the bug.

They are not DRAM. `recovery/9.1.1/recovery-header.txt` has kernel `0x00991680` and ramdisk `0x01989680`; DRAM starts at `0x80000000`. A TX1 L4T R28.1 log (same SoC, **not** this binary) prints kernel load `0x80080000` ([forum thread 55408](https://forums.developer.nvidia.com/t/tx1-upgrade-kernel-cboot-l4t-28-1/55408)).

## Rank

1. **(a), refined.** Stock is gzip, and that path is what the TX1 log places at `0x80080000`. The next line is `decompressor handler not found`, then success: uncompressed is a second path there, not an automatic abort. **UNCERTAIN** for Shield `32.00.2019.50`. U-Boot is linked at `0x80080000` and is not position-independent. Flags `0xa` are 4K pages plus bit 3 (`__HEAD_FLAG_PHYS_BASE` in `vendor/lineage-u-boot/arch/arm/cpu/armv8/linux-kernel-image-header-vars.h`). Bit 3 allows any placement (`Documentation/arm64/booting.rst`). Linux survives that. This U-Boot does not, if cboot jumps at the staging buffer. archeYR's raw image was an older foster cboot. A bad entry and a watchdog cboot left armed both look like a ~7 s reset on the NVIDIA logo. **UNCERTAIN** which the 7 s is.

2. **(d), narrow.** `image_size` `0xcbb90` is `__MEM_USAGE` (file plus BSS), so it is larger than the 370,704-byte file on purpose. The boot protocol uses it as a reservation, not a copy length. Stock has the same gap after gunzip and still boots. Fatal only if the raw path requires `kernel_size >= image_size`. **UNCERTAIN.**

3. **(b).** The probe fits the slot: recovery is `0x1980000`, and the flash was 24,942 KB (`device-info/first-test-flash-recovery.txt`). No published cap between stock's 9,032,093 bytes and 24 MiB. A fixed buffer could still overflow. Not required to explain this failure.

4. **(c).** Unlikely. cboot does not parse cpio. `secure: No` and `unlocked: Yes` means AVB is not enforcing. Random bytes are not gzip, so a conditional gunzip skips them.

5. **(e).** Unlikely. Orange state still boots. No orange splash is a weak negative. `secure: No` is the stronger fact.

A T194 snippet ([forum thread 208448](https://forums.developer.nvidia.com/t/if-the-cboot-supports-uimage-loading/208448)) takes an Android kernel as `header + pagesize` and `kernelsize`, and reads `text_offset` only off the Android path. **UNCERTAIN** that this 2019 cboot shares that or the R28 strings. The binary was not opened. Public `cboot_src_t21x` is not this Shield build.

## Smallest flashes

Menu boot only. Do not boot Android in between (`vendor_flash_recovery`). Keep the current mkbootimg header.

1. **`gzip -9 -n` the same `u-boot-dtb.bin`, keep the 24 MiB probe.** If it does not fall back in ~7 s, raw entry was the fault, and (b)/(c) are clear because the ramdisk did not change. Stop.
2. **Only if 1 fails:** gzip U-Boot, no ramdisk. Success means the probe ramdisk is fatal. One follow-up splits it: ~9 MB of the same random bytes. Works → size cap (b). Fails → content (c), a surprise.
3. **Only if 2 fails:** repack the stock kernel and stock ramdisk with these mkbootimg args, and restore the stock cmdline (`buildvariant=user veritykeyid=...`, `recovery-header.txt`). Failure means the packer. Success means this header and a gzip kernel are accepted, and U-Boot dies after the jump. Last image: pad with zeros to `0xcbb90`, gzip, still no ramdisk. If that also returns in ~7 s, stop. It is being entered and faulting, or the watchdog is still armed. No serial on this board.

Do not fold 2 into 1. A failed gzip-plus-probe would not say which half failed. Success of 1 discriminates.
