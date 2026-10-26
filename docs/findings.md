# Findings

What we learned about the SHIELD TV 2017 under mainline Linux, area by area. Each finding gives the cause, the fix and the evidence: a commit, a patch, or a section of `NOTES.md`. [Lessons learned](lessons.md) has the constraints and what went wrong; [benchmarks](benchmarks.md) has the numbers.

## Boot chain: cboot → U-Boot → Linux

- **cboot**, NVIDIA's bootloader, can't start a mainline kernel by itself. It hands the kernel Android's device tree from the DTB partition, and flashing that partition has bricked SHIELDs. So cboot starts our U-Boot as if it were Android's kernel, and U-Boot starts Linux (`patches/u-boot/0001`, a524e39).
- **`fastboot boot`** answers OKAY, never boots the image, and freezes cboot until a power cycle. Test images go in the recovery partition instead (`scripts/09`, b7ddcb2).
- **Android restores stock recovery** on every boot (`vendor_flash_recovery`). The recovery slot has to be started straight from the bootloader menu (bbefde2). The installed system later goes in the boot slot (`scripts/14`).
- **U-Boot must be gzipped**, as NVIDIA's kernels are. A raw one made cboot fall back to fastboot (686b74f).
- **cboot reports no framebuffer.** U-Boot reads the address and format from display controller A, which shows cboot's logo (1216ac1). U-Boot's console shows on the TV (fa74230).
- **Size limits:** cboot takes at most 32 MiB per download, and the boot and recovery slots hold 25.5 MiB each (b7ddcb2).
- **No known way to reach a serial port, so the TV is the debug channel.** After any reset, U-Boot shows the end of the last kernel's log, read from RAM (ramoops), and then reboots into the bootloader menu. That makes a test loop that needs no Android (7b3709a, 092a153, c4660af).
- **A watchdog catches hangs.** U-Boot arms one for every kernel (150 s). It reset a deliberately hung kernel (d8ac237, 5453afb).

## Display (HDMI)

- **Keeping cboot's picture through the first Linux boot.** The framebuffer is reserved as no-map memory, so Linux can map it. Three always-on rails are marked boot-on, because the fixed-regulator driver otherwise pulses them off at probe. The HDMI 5 V and the fan stayed as cboot set them (371a6dc).
- **The first Linux boot went black.** Linux's power-controller driver (PMC) switches off every power partition that is on when it starts. One of them, `pd_sor`, feeds SOR1, the HDMI encoder cboot left running. n-codex and n-grok found it independently, and antigravity and Z.ai agreed (`research/*hdmi-link*`). The first suspect, the PMIC's HDMI power path, differed from stock but wasn't the cause (e91a6a4, then 06ec1f0).
- **Fix, in two stages:**
  - While the simple framebuffer drove the console, the device tree kept that partition away from the PMC (06ec1f0, e5503b4).
  - Then HDMI was described as on the Jetson TX1 and stock darcy (DPAUX1, SOR1's supplies, DDC on I2C4, hot-plug), and tegra-drm, the real display driver, drives 1080p from boot (7cf0d01, 6521017).
- **HDMI 2.0 works.** On a 4K LG TV, Omarchy's preferred-mode rule runs 3840x2160 at 60 Hz, over a 594 MHz link with scrambling. The first TV stopped at 1080p. The boot console stays at 1920x1080 (NOTES.md B10).
- **A mainline bug:** reading `/sys/kernel/debug/powergate` oopses in Linux 7.2.11, because `powergate_show()` takes the PMC from the wrong argument. We stopped reading it (f399551) and haven't reported it upstream yet.

## Audio (HDMI)

- **There was no sound card.** The drivers were built all along, but mainline's `tegra210.dtsi` leaves the HDMI audio controller disabled, and our device tree never turned it on. `kernel/dts/darcy.dts` now does, as Jetson TX1 and Nano do. Only the device tree changed; the kernel is still build #21 (NOTES.md B10).
- **Now:** the card is `NVIDIA SHIELD TV HDA`, with the output "LG TV". The TV reports stereo PCM up to 192 kHz, plus Dolby Digital, Dolby Digital Plus, DTS and TrueHD. PipeWire plays to it.
- **Checked end to end while the TV stayed silent:** the samples stream at 48 kHz. The HDMI encoder receives their format, turns on audio clock regeneration and sends a correct audio infoframe, and its registers match NVIDIA's own driver. The silence was the TV, which sent its sound to the soundbar.
- **Not done:** surround passthrough, the soundbar's volume from the remote over HDMI-CEC, and a fixed output volume for a soundbar.

## USB, network, Bluetooth

- **USB:** the host port near HDMI worked on the first try (XUSB pads, xHCI, linux-firmware's microcode; 53f2132, d8ac237).
- **Wi-Fi and Ethernet:**
  - Wi-Fi is a BCM4354 on SDMMC2, with NVIDIA's firmware, NVRAM and CLM blob from the recovery image. Ethernet is an RTL8168g on PCIe. Both were found on the first boot (6b37865, 23569ae).
  - iwd needed crypto options in the kernel.
  - The BCM4354 only takes a country code through a map. NVIDIA's darcy table (US → US/0) is what opens 5 GHz (7907e0f, 2778bdf).
- **Bluetooth:**
  - The UART driver refused UARTD without a `serial3` alias (a7a188d).
  - The firmware patch must be named `BCM4354.hcd` (c14b337).
  - It runs at 3 Mbaud, as on Android.
- **No real addresses:** the board's NCT storage holds no Wi-Fi or Bluetooth address, so both use placeholders (1726fc4).

## The installed system

- **Root filesystem:** Arch Linux ARM's image, built without root in a user namespace, running pacman through QEMU (`scripts/13`, 25fede8).
- **On a USB SSD,** so Android's partitions stay as they are. The eMMC's user data partition remains an option (a33f734).
- **The first cable powered the SSD but carried no data** (ed1a327). The SSD links at USB 2, 480 Mbit/s, most likely through its own cable (2c9e98a).
- **pacman needs Landlock** in the kernel for its download sandbox (31961db).
- **Updates go over SSH and USB** with nothing to press on the TV (`scripts/17`, 1726fc4). Modules are compared by hash, because the kernel's build stamp can stay the same (4d82b89).
- **Memory:** with the desktop idle, about 1.3 GB of the 2.8 GB is available. Omarchy's shell, with Uber TV inside it, is the largest program at about 460 MB. Chromium holds about 1.2 GB while Netflix plays, and an Omarchy update left 117 MB available. Swap is zram (NOTES.md B11).

## Heat and CPU power

- **The SHIELD overheated and shut itself off** (4d82b89):
  - It had no CPU power management yet, and idled at 83–89 °C.
  - Since mainline commit 5136f99b9a4a, soctherm sets its hardware throttle at the shutdown temperature, so the chip never throttles before it powers off. `patches/linux/0002` throttles at the hot trip again.
- **darcy has a fan, and it never ran** (d4cd616):
  - Its 5 V supply and PWM pin were off, and its PWM input is inverted.
  - With it running, the idle CPU sits at 43 °C instead of 67–70 °C.
- **Power management now:**
  - Idle cores sleep in C7 (7a322c8). The secure monitor turns down 1–4% of the attempts, at no cost. Power and heat didn't change, since the cores were already clock-gated when idle.
  - A thermal guard slows the CPUs at 86 °C and reboots at 92 °C (9736e5b).
  - The DFLL runs the CPU up to stock's 2014.5 MHz (`patches/linux/0003`, 5fc27a7 to 4a93eab).
  - Passive cooling starts at 82 °C (c16b710).

## GPU (GM20B, nouveau)

- **The first register read froze the board.** The GPU needs the SoC's fuse clock on. `patches/linux/0001` follows a posted upstream series for the Jetson TX1 (efb53a1, b09a55d).
- **Mesa crashed every OpenGL program on its first draw.** This is Mesa issue #14640, since 25.2. Upstream's merge request !45355 plus six fixes of ours make `mesa-darcy` (8e7e088, 2d4908d).
- **Stalls and rejected batches.** Since Linux 6.16, nouveau's progress counter sits in memory the CPU caches, so on Tegra the CPU read stale values (`0004`, kernel #12, 326afce).
- **Half-drawn frames.** tegra-drm didn't wait for nouveau's rendering before showing a frame (`0005`, kernel #13, e841f9b).
- **Limits of nouveau on GM20B:** no compression, 4 KiB GPU pages only, and the GPU's page tables behind the IOMMU (NOTES.md B6). NVK, Mesa's Vulkan driver, doesn't support Tegra.

## Desktop: Hyprland and Omarchy

- **Hyprland 0.56** runs on tegra-drm, with nouveau rendering through `mesa-darcy` and a pointer drawn in software (6415742).
- **omarchy-arm needed a Tegra210 platform** (`patches/omarchy-arm/0001`): detection, no Vulkan, the light look, the software pointer, and tegra-drm's card for Hyprland and the login screen (ae087db, f53a3c9).
- **Omarchy needed more from the kernel:** PSI and zram (kernel #14) and nf_tables for its firewall (#15) (f53a3c9, 47a3653).
- **The login screen refused every password.** Omarchy's SDDM theme logs in as the last user, which omarchy-arm records only in a first-boot step our install skips. `scripts/20` records it (54988ed).
- **The bar and menus lost their colours.** Qt 6.12's own `Color` singleton hid the shell's (`patches/omarchy-arm/0002`, 54988ed).

## Video and streaming

- **The CPU decodes video.** Mainline has no Tegra210 hardware decoding that players use (NOTES.md, "Media-center expectations"). Uber TV plays through Qt Multimedia. Which formats and sizes keep up isn't measured yet.
- **Netflix plays,** from Uber TV's launcher, in Chromium. Chromium fetches Google's Widevine for ARM64 Linux by itself, which is Widevine L3: decryption in software, so Netflix limits the resolution. Android's L1 doesn't carry over (NOTES.md B11).

## Memory clock (EMC)

- **cboot leaves the memory at 800 MHz**; stock Android goes up to 1600. Mainline's driver needs trained timing tables. cboot trains them at every boot and puts them in its own device tree. `patches/u-boot/0002` passes that tree on, and `0003` converts the table for this board's RAM code. `tools/emc-table.py` checks the conversion byte for byte (2b6a360, 4c8e65b).
- **Two refresh bugs in mainline's driver.** The refresh state was never stored. Then `REFRESH_SPEEDUP()` multiplied the refresh interval, so hot memory would have been refreshed less often, not more. `patches/linux/0007` fixes both (4c8e65b, d005f18).
- **At 1600 MHz**, glmark2's scenes run 50–100% faster and memory writes 88% faster. It isn't the boot default yet.

## Performance: nouveau's cache cleaning

- **The CPU spent its time cleaning caches.** Tegra's GPU doesn't see the CPU's caches, and nouveau cleaned every page of every buffer on every submit: 69% of SuperTuxKart's CPU time (NOTES.md B6).
- **Two rounds of `patches/linux/0006`:**
  - Kernel #16 cleans only the buffers the CPU may have written: 26% of the CPU time. Once the faster memory clock had sped the GPU up, cleaning was back to 41% (kernel #19). Every buffer Mesa had ever mapped was still cleaned whole.
  - Kernel #20 tracks the pages the CPU writes, through page faults, and cleans only those. Kernel #21 has n-codex's correctness fixes (f6abea2, d4401c6, 43a9559).
- **The result:** SuperTuxKart went from 20.7 to 37.2 FPS at the same settings.

## Logins

- **A new desktop user's password is the user's own.** `scripts/20` asks for it. An existing user with a usable password keeps it.
- **The default logins are locked.** `scripts/22` locks Arch Linux ARM's default root and alarm logins, after checking that root's SSH key keeps working (NOTES.md B9, 4c9d7a8).
- **Password prompts ask for the desktop user's password.** Uber TV's password check and its phone remote's firewall rule run through polkit (`pkexec`). polkit asked for the first `wheel` member's password, which was alarm's, locked, so every password was refused. `scripts/22` now also takes alarm out of `wheel` (NOTES.md B11).
