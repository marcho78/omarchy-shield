# Problems, constraints and open issues

This page covers what limits the project, what went wrong on the way, the claims we got wrong and corrected, and what is still open. [Findings](findings.md) has the fixes.

## Constraints

These are facts we work within.

- **Android stays whole.** The user chose this, so Linux runs from a USB SSD, and only the boot and recovery partitions are ever written. The never-flash list in `NOTES.md` covers the DTB, the bootloader blob, BCT, TOS, EKS and the partition table, since a bad DTB has bricked SHIELDs.
- **Unlocking the bootloader erases Android's user data.** NVIDIA's recovery image restores everything.
- **NVIDIA's files can't go in the repo.** That covers the recovery image and the Wi-Fi, Bluetooth and GPU firmware. Each user downloads the image, and `scripts/04` takes the firmware from it.
- **No serial port.** We debug with photos of the TV, the kernel's log kept in RAM (shown by U-Boot after a reset), and SSH once the system is up.
- **cboot's limits:**
  - `fastboot boot` doesn't work.
  - A download can be 32 MiB at most, and a slot holds 25.5 MiB.
  - `fastboot reboot` answers FAILED but resets anyway, and `fastboot reboot recovery` isn't supported.
  - The bootloader menu clears the RAM that holds the kernel's log.
  - Once, the menu went on by itself after 15–18 s, so `scripts/17` flashes at once.
- **USB:** the laptop needs a USB-A male-to-male cable to the port far from HDMI; a phone cable won't do. The bootloader menu needs a USB keyboard or controller in the port near HDMI, as it has no Bluetooth.
- **The GPU stack** is nouveau and Mesa, without NVIDIA's own driver. On GM20B that means no compression, 4 KiB GPU pages only, and no Vulkan (NVK doesn't support Tegra), so no GPU compute.
- **No real network addresses.** The board stores no Wi-Fi or Bluetooth address, so both use the firmware's placeholder addresses. Two SHIELDs on one network could clash.
- **Review agents have quotas.** n-grok ran out of credits, Z.ai hit its usage limit, and antigravity is out of quota until about Oct 29. Agents also make confident wrong claims, so we check each one in the source before acting. NOTES lists the ones that were wrong.

## What went wrong, and what it taught us

| Problem | Cause | What fixed it |
|---|---|---|
| `fastboot boot` froze the bootloader | Broken on this firmware | Test from the recovery slot (b7ddcb2) |
| The test image vanished | Booting Android restores stock recovery | Start recovery from the bootloader menu (bbefde2) |
| U-Boot never showed | cboot wants a gzipped kernel, and reports no framebuffer | gzip, and read the framebuffer from the display controller (686b74f, 1216ac1) |
| The first Linux boot went black | The power driver cut the HDMI encoder's power partition | Keep that partition away from it, then tegra-drm (06ec1f0, 6521017) |
| The SSD didn't show up | The cable carried power, not data | Another cable (ed1a327) |
| tegra-drm blanked the TV | HDMI wasn't described in the device tree yet | Kept out until it was described (fd5f1a9, 7cf0d01) |
| pacman refused to download | Its sandbox needs Landlock | Kernel #7 (31961db) |
| The first GPU access froze the board | The fuse clock was off | `patches/linux/0001` (b09a55d) |
| The SHIELD overheated and shut down | The fan never ran, and the hardware throttle was set at the shutdown temperature | Fan, `0002`, then CPU power management (4d82b89, d4cd616) |
| Every OpenGL program crashed | Mesa's tegra driver since 25.2 | `patches/mesa`, `mesa-darcy` (8e7e088, 2d4908d) |
| GPU stalls, then half-drawn frames | Stale progress reads, then tegra-drm not waiting for the GPU | Kernels #12 and #13 (326afce, e841f9b) |
| Omarchy's install stopped at the firewall | The kernel had no nf_tables | Kernel #15 (47a3653) |
| The login screen refused the password | SDDM's last user was never recorded | `scripts/20` records it (54988ed) |
| The bar and menus lost their colours | Qt 6.12's `Color` hid the shell's | `patches/omarchy-arm/0002` (54988ed) |
| SuperTuxKart at 3 FPS | nouveau cleaned caches for every buffer, every submit | `0006`, twice (f6abea2, d4401c6, 43a9559) |
| Hot memory would have been refreshed less often | Two bugs in mainline's EMC driver | `0007` (4c8e65b, d005f18) |
| Two benchmark runs read about 10 FPS | The screen was locked, and Hyprland slows hidden windows | Runs only with the user at the TV (NOTES.md B7) |

## Claims we got wrong, and the corrections

| What was said | What turned out true |
|---|---|
| LineageOS boots darcy through U-Boot (NOTES.md "What we know") | It flashes its own blob and DTB. archeYR's 2015 SHIELD port is the precedent. Marked in NOTES. |
| The plan's "try `fastboot boot`" (NOTES.md "Plan") | It freezes cboot; the recovery slot is the way (b7ddcb2) |
| U-Boot "touches no hardware" (a524e39) | Tegra's generic U-Boot init still sets clocks, the UART, the timer and USB pads (NOTES.md "Boot chain design") |
| The root filesystem goes on the eMMC (NOTES.md) | Changed the same day to a USB disk, to leave Android whole (a33f734) |
| "The PMIC probe drops HDMI" (NOTES.md heading) | The power controller cutting `pd_sor` did (06ec1f0) |
| The fan can stay as cboot left it, and darcy has none (NOTES.md) | It never ran, darcy has one, and the board overheated (d4cd616) |
| The GPU's flapping clock caused the stalls (8e7e088) | Stale progress reads did (326afce) |
| `0007` makes the refresh follow the temperature (4c8e65b) | It then multiplied the interval, the wrong way (d005f18) |
| Kernel #20 revokes mappings with `ttm_bo_unmap_virtual()` (d4401c6) | That also freed I/O mappings; #21 uses `drm_vma_node_unmap()` (43a9559) |
| The hub holds the SSD to USB 2 (0b5f5c0) | The hub is USB 3; the SSD's own link is USB 2 (2c9e98a) |
| Memory writes at 19.6 GB/s (0b5f5c0, the results card) | 19,632 MiB/s, which is 20.6 GB/s (0ca6d06) |

## Open issues

- **The SSD runs at USB 2** (480 Mbit/s, 25–28 MiB/s). Try a USB 3 cable, with the SHIELD off, since it runs from that SSD.
- **1600 MHz memory isn't the boot default.** Each boot starts at 800 MHz, and `tools/emc-rate.sh` raises it. To do before making it the default: an overnight soak, cold boots, then a service that sets the rate last.
- **Wi-Fi is weak, and it drops.**
  - The signal is −67 dBm. The access point dropped the SHIELD twice in an hour under iwd, and it reconnected about 90 s later. Why is still open; Wi-Fi power saving is one suspect.
  - It hasn't been re-checked since the move to NetworkManager.
- **Untested or not started:** an Ethernet link (no switch to plug into), audio, video playback and decoding, and Bluetooth keyboard pairing.
- **Omarchy isn't trimmed** for the media center.
- **Restarting Omarchy's shell while the screen is locked** kills its lock screen, so unlock first (NOTES.md B5).
- **SuperTuxKart with dynamic lighting** is 5.6 times slower. The GPU-side causes haven't been measured yet: compression, big pages, the IOMMU.
- **Nothing has gone upstream yet:** the kernel fixes, the Mesa fixes, the omarchy-arm patches, and the debugfs oops. That's the user's call.
- **Losses from locking root:** no root login at the TV (the desktop user's sudo instead), and no emergency shell (NOTES.md B9).
- **Antigravity's review of these docs** waits until its quota resets, and then for the user's go.
