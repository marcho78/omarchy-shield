# Static review: P2894/darcy U-Boot patch

## Verdict

**Do not run a FIT-bearing image on the SHIELD yet.** I found three boot-path blockers: the outer Android image gives a newly added ramdisk address zero, the cboot-loaded FIT is not protected from U-Boot's own relocation/heap reservations, and Tegra's inherited `fdt_high=~0` makes U-Boot enlarge a FIT-embedded DTB in place without guaranteed space. The report-only image also has a dangerous framebuffer fallback and performs substantially more hardware initialization than `NOTES.md` claims.

This was a static review only. I did not edit/build the project or access the SHIELD.

## Ranked findings

### 1. BLOCKER — The payload boot image uses an unverified, likely overlapping ramdisk address

`scripts/06-make-bootimg.sh:17-25` adds the FIT as the Android ramdisk but reuses `--ramdisk_offset 0` from `config.sh:18-24`. That value came from stock **boot.img**, which has no ramdisk (`recovery/9.1.1/boot-header.txt:3-5`). Stock **recovery.img**, which does carry a ramdisk, uses `0x01989680` (`recovery/9.1.1/recovery-header.txt:3-5`).

**UNCERTAIN:** the exact address translation performed by darcy cboot (literal address, DRAM-relative offset, or ignored hint) is not established here. If it is DRAM-relative, zero places the FIT at the bottom of DRAM, while the kernel/U-Boot header address is nearby; a realistic FIT can overlap the U-Boot image before its first instruction or later overlap a kernel load at `0x80080000`. The design claim that cboot starts U-Boot at `0x80080000` also does not match the outer header's `0x00991680` without an undocumented cboot translation (`NOTES.md:171-172`, `config.sh:23`, `configs/p2894_defconfig:4`).

**Required before device use:** derive the outer header addresses from a known-working U-Boot-chainloaded Lineage image or use the stock recovery layout, then prove from an unpacked generated image that kernel and maximum FIT ranges are disjoint. Treat cboot's address semantics as **UNCERTAIN** until confirmed from source or a captured handoff.

### 2. BLOCKER — The incoming FIT is not reserved before U-Boot relocates and allocates its heap

The FIT address is first read in `nvidia_board_late_init()` (`board/nvidia/p2894/p2894.c:114-143`), after relocation. Before then, U-Boot selects the relocation destination and reserves video, U-Boot, and the 37 MiB heap (`common/board_f.c:984-1001`; `configs/p2894_defconfig:5`). Generic cboot support reserves only the cboot DTB, and does so during late init (`arch/arm/mach-tegra/cboot.c:412-454`; call order at `arch/arm/mach-tegra/board2.c:272-292`). It never reserves cboot's initrd/FIT.

Therefore there is no invariant preventing relocation, malloc, stacks, or page tables from overwriting the FIT before `bootm ${cboot_initrd_start}` (`board/nvidia/p2894/p2894.env:7-10`). **UNCERTAIN:** whether it actually overlaps depends on the live cboot memory map and chosen ramdisk address, but the current code cannot demonstrate safety.

Parse and validate `linux,initrd-start/end` before relocation and exclude that whole range from relocation reservations. At minimum, pair this with an explicitly proven low ramdisk load range that is disjoint from both the initial U-Boot image and the later kernel destination.

### 3. BLOCKER — `fdt_high=~0` can grow the FIT's embedded DTB over adjacent data

Tegra's default environment sets `fdt_high=ffffffffffffffff` and `initrd_high=ffffffffffffffff` (`include/configs/tegra-common-post.h:52-65`). For a normal FIT DT image with no separate load address, `bootm` consequently uses the DTB in place and reserves `DT size + CONFIG_SYS_FDT_PAD`; it explicitly assumes padding exists after the original DTB and changes its totalsize (`boot/image-fdt.c:176-189`, `boot/image-fdt.c:242-257`). The current generated configuration uses a 12 KiB pad (`build/u-boot/.config:1892`). A FIT component has no inherent 12 KiB writable tail.

`ft_board_setup()` then adds a node and a memreserve entry (`board/nvidia/p2894/p2894.c:149-158`), potentially overwriting the next FIT component or memory beyond cboot's ramdisk allocation. Force relocation of the kernel DTB to a separately allocated/reserved address (unset or replace `fdt_high`) rather than modifying an inline FIT component. Keeping an inline initramfs through `initrd_high=~0` is acceptable only after the complete FIT range and all kernel destinations are proven disjoint.

### 4. HIGH — Framebuffer failure falls back to writing a 2015 address, and the cboot size is ignored

The control DT enables a 1920x1080 framebuffer at a hard-coded 2015 SHIELD address (`arch/arm/dts/tegra210-p2894.dts:30-42`). `board_fix_fdt()` treats missing/invalid cboot data or a missing property as success and leaves that device enabled (`board/nvidia/p2894/p2894.c:84-111`). The simple-video driver accepts the address (`drivers/video/simplefb.c:13-40`), after which video initialization clears the framebuffer (`drivers/video/video-uclass.c:675-682`). Thus a parse/set-property failure can cause an 8.3 MiB write to an unverified physical range.

Even on success, only the base cells are patched; `fb_size` is saved but the DT size cells, dimensions, stride, and format remain hard-coded (`board/nvidia/p2894/p2894.c:65-81`, `board/nvidia/p2894/p2894.c:95-109`). **UNCERTAIN:** cboot may always leave exactly that 1080p surface, but this is not established by the handoff parser. If its surface is smaller or differently formatted, U-Boot can write past the carveout.

Make the video node non-bindable by default and enable it only after validating base, size, overflow, DRAM/carveout containment, and the exact mode. Patch both base and size; do not silently use the 2015 address. Also check the return from `fdt_setprop_inplace()` (`board/nvidia/p2894/p2894.c:109`).

### 5. HIGH — `CONFIG_TEGRA_GPU` makes an unguarded, write-locked VPR change after TOS

`CONFIG_TEGRA_GPU=y` (`configs/p2894_defconfig:13`) makes `board_init()` call `tegra_gpu_config()` (`arch/arm/mach-tegra/board2.c:122-134`). On T210 this writes VPR size zero, disables further writes to the VPR control register, and reads it back (`arch/arm/mach-tegra/gpu.c:18-36`). The non-secure guard cannot be enabled for T210; its Kconfig dependency is T114/T124 only (`arch/arm/mach-tegra/Kconfig:180-185`). It also causes `ft_system_setup()` to force every `nvidia,gm20b` node to okay (`arch/arm/mach-tegra/dt-setup.c:15-32`).

**UNCERTAIN:** TLK/TOS may make these MC registers inaccessible from cboot's handoff EL, causing a synchronous abort/hang; if writes are allowed, this still destroys and locks cboot's VPR policy for the remainder of the boot. Remove `CONFIG_TEGRA_GPU` for the first-stage proof. Add GPU/VPR only after establishing the execution EL, register permissions, required VPR policy, and a T210-aware non-secure path. Do not force-enable a DT node merely because the write was attempted.

### 6. HIGH — The “touches no hardware” premise is false beyond VPR

The generic Tegra path also:

- rewrites peripheral clock parents including HOST1X, all SDMMC controllers, SPI, PWM, and I2C (`arch/arm/mach-tegra/board2.c:127-145`; `arch/arm/mach-tegra/clock.c:791-828`; `arch/arm/mach-tegra/tegra210/clock.c:1291-1310`);
- configures UART pinmux/clock (`arch/arm/mach-tegra/board.c:213-230`, `arch/arm/mach-tegra/board2.c:207-235`);
- writes system-counter MMIO without a T210 non-secure guard (`arch/arm/mach-tegra/board2.c:222-228`, `arch/arm/mach-tegra/tegra210/clock.c:1077-1095`); and
- unconditionally changes XUSB/PCIe pad and PLL state immediately before Linux, even when no padctl node was processed (`arch/arm/mach-tegra/board2.c:194-198`, `arch/arm/mach-tegra/tegra210/xusb-padctl.c:417-475`).

**UNCERTAIN:** secure ownership and the effect on cboot's live HDMI/USB state are device-specific. These accesses may merely reprogram working hardware, or may abort/hang. Add a dedicated cboot-chainload mode that skips generic low-level initialization and XUSB cleanup unless a device is intentionally claimed.

The good news: the P2894 board has no strong `pin_mux_mmc`, `start_cpu_fan`, or GPIO override, so those weak hooks are no-ops (`arch/arm/mach-tegra/board2.c:57-63`). PMIC voltage writes are compiled out because `CONFIG_TEGRA_PMU`/`CONFIG_TEGRA_CLOCK_SCALING` are off; `CONFIG_SYS_I2C_TEGRA` alone does not trigger them (`arch/arm/mach-tegra/board2.c:150-162`).

### 7. MEDIUM — The effective configuration still exposes storage-write commands

The defconfig attempts to disable MMC, SPI, and networking (`configs/p2894_defconfig:27-32`), but `TEGRA_COMMON` selects MMC/SPI (`arch/arm/mach-tegra/Kconfig:43-61`) and the network choice defaults to `NET`, not “off” (`Kconfig:759-787`). The current generated config has `MMC_WRITE`, `CMD_SF`, generic filesystem `save`, `FAT_WRITE`, EFI loader/file-backed variables, and networking enabled (`build/u-boot/.config:324-335`, `build/u-boot/.config:711-824`, `build/u-boot/.config:916`, `build/u-boot/.config:1247-1293`, `build/u-boot/.config:1563`, `build/u-boot/.config:1798`). `save` can write through any block backend (`cmd/fs.c:43-58`, `fs/fs.c:898-937`), `sf` exposes SPI erase/write, and EFI's default variable backend writes `/ubootefi.var` (`lib/efi_loader/Kconfig:101-115`).

The custom `bootcmd` does not automatically invoke these paths, so this is not an observed automatic eMMC write. Still, for a first-stage safety loader remove write-capable commands/features (`BOOTSTD`, EFI/file variables, generic save/FAT write, SPI-flash commands, MMC write where Kconfig permits) and select `CONFIG_NO_NET=y` explicitly. Driver presence is less concerning than exposed write operations.

`ENV_IS_NOWHERE` itself is correct: its backend has only init/load and no save operation (`env/nowhere.c:22-48`). `CONFIG_CMD_SAVEENV=y` therefore cannot persist the U-Boot environment, although it should be removed to avoid ambiguity.

### 8. MEDIUM — FIT bounds are not validated; `bootm` detects one overlap only after writing

The handoff accepts any `end > start`, exports both values, then ignores the size in `bootm` (`board/nvidia/p2894/p2894.c:138-143`; `board/nvidia/p2894/p2894.env:7-10`). It does not verify alignment, integer overflow, containment in a mapped DRAM bank, FIT magic, or that `fdt_totalsize(FIT) <= end-start`. A corrupt/unexpected cboot property can therefore make `bootm` read outside the loaded ramdisk.

U-Boot checks a kernel destination/FIT overlap only after copying or decompressing the kernel, then requires reset (`boot/bootm.c:603-673`). That does not protect against earlier U-Boot relocation, nor prevent the destructive copy. Validate the complete interval before boot and make the image builder prove that FIT, kernel output, relocated DTB, initramfs, U-Boot, and malloc ranges are pairwise safe.

`CONFIG_SYS_BOOTM_LEN=0x4000000` is a 64 MiB maximum **decompressed OS image**, not a FIT-size limit (`boot/Kconfig:995-1004`). **UNCERTAIN:** it is sufficient until the actual mainline `Image` size is checked. `CONFIG_SYS_LOAD_ADDR=0x80080000` is not intrinsically wrong after U-Boot relocates, but it must be checked against the FIT and initramfs ranges.

### 9. LOW — Eight DRAM banks are probably enough, but overflow is silently truncated

Generic cboot parsing silently truncates `/memory/reg` to `CONFIG_NR_DRAM_BANKS` (`arch/arm/mach-tegra/cboot.c:100-105`); the P2894 defconfig chooses eight (`configs/p2894_defconfig:6`). The MMU array is correctly sized for that choice (`arch/arm/mach-tegra/arm64-mmu.c:13-31`). **UNCERTAIN:** the live, cboot-patched darcy DT bank count is unknown. If it exceeds eight, later banks disappear; a FIT in a dropped bank could be unmapped. Before boot, inspect a captured live cboot DT or add an explicit fatal diagnostic instead of truncating.

## Requested pre-relocation assessment

The `.data` placement is correct. `fb_base`/`fb_size` are written before BSS clearing (`board/nvidia/p2894/p2894.c:25-27`), matching upstream cboot's own `.data` globals (`arch/arm/mach-tegra/cboot.c:44-74`). AArch64 enters `save_boot_params` immediately (`arch/arm/cpu/armv8/start.S:55-59`); Tegra saves x0 whenever it is not the special SPL sentinel (`arch/arm/mach-tegra/board.c:48-70`). Thus cboot's x0 is available to `board_fix_fdt()` if cboot follows the normal arm64 DT handoff contract. **UNCERTAIN:** that exact darcy cboot contract still needs external confirmation, but the U-Boot plumbing is internally sound.

`board_fix_fdt()` runs on U-Boot's control FDT before relocation and before video reservation (`common/board_f.c:984-1001`). Updating the existing 16-byte `reg` property with `fdt_setprop_inplace()` is appropriate and does not grow the blob. The defect is ignoring its return and retaining an unsafe enabled fallback, not the in-place operation itself.

## `ft_board_setup()` failure behavior

`fdt_simplefb_add_node()` first creates a disabled node, then probes video and configures it (`boot/fdt_simplefb.c:68-86`). If video probing/configuration fails, the disabled node remains and the patch only logs a warning. It nevertheless adds a reservation whenever `fb_base != 0` (`board/nvidia/p2894/p2894.c:150-158`). Conversely, if U-Boot successfully used the hard-coded fallback while `fb_base == 0`, it advertises that fallback framebuffer but adds no reservation. Failure to add either the node or reservation is non-fatal, allowing Linux to overwrite a displayed surface.

Use `video_is_active()` semantics (as the existing helper does at `boot/fdt_simplefb.c:106-118`), reserve exactly the validated active range, and treat inability to create both a correct node and reservation as a boot-stopping error for a simplefb-dependent kernel. Also note that the helper reports every 32-bpp framebuffer as `a8r8g8b8` (`boot/fdt_simplefb.c:53-65`), while the control DT declares `a8b8g8r8` (`arch/arm/dts/tegra210-p2894.dts:35-42`); this is a color-order mismatch, not a hang risk.

## Minimum safe first-device sequence

1. First boot U-Boot **without a FIT**, with GPU/VPR, generic clock/UART/timer reinitialization, and XUSB cleanup either removed or explicitly audited for cboot-chainload safety.
2. Disable the framebuffer device unless the cboot handoff is fully validated; never use the 2015 fallback address.
3. Fix and prove the Android kernel/ramdisk load ranges from the generated header.
4. Reserve the cboot ramdisk before relocation, force the FIT DTB to a separate padded allocation, validate every payload interval, and only then enable `bootm`.
5. Strip storage-write/EFI/network command paths from the safety loader. Add VPR/GPU only as a separate, recoverable experiment after confirming EL/register ownership.
