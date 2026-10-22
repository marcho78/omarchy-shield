## Bottom line

The best route is to retain NVIDIA’s early firmware and chainload a Shield-tested U-Boot/ATF stack. Avoid replacing the DTB partition during development: a mismatched DTB can hang cboot before fastboot becomes usable.

### 1. Boot-chain ranking

1. **(d) LineageOS-derived U-Boot + ATF chainload.** Current LineageOS Shield work uses a 6.12 kernel and explicitly depends on NVIDIA-targeted [U-Boot and ARM Trusted Firmware](https://github.com/LineageOS/android_device_nvidia_foster/blob/lineage-23.2/lineage.dependencies). Its build wraps `u-boot-dtb.bin` as the outer boot-image kernel and an Android boot image inside the ramdisk, proving this chainload model on Shield hardware ([packaging logic](https://github.com/LineageOS/android_device_nvidia_foster/blob/lineage-23.2/mkbootimg.mk)). Adapt that U-Boot to load Arch via extlinux/FIT from USB, with your mainline DTB.

2. **(b) Upstream p3450/p2371 U-Boot derivative.** Architecturally sound and preserves nvtboot/cboot/TOS initialization, but it needs P2894-specific board support. Prefer p3450 as the T210 reference because it already enables eMMC, USB, PCIe/RTL8169, SOR/HDMI and GM20B ([upstream DTS](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts)). Do not assume its UPHY lanes, regulators or GPIOs match Darcy.

3. **(a) Direct mainline kernel boot image.** Useful only as an early CPU/serial smoke test. Evidence strongly indicates Darcy cboot selects the kernel DT from the separate `dtb` partition: NVIDIA recovery flows flash it separately, while Lineage’s header-v1 packaging supplies no normal-boot DTB. **UNCERTAIN:** exact Shield cboot handling of an appended DTB or the boot-image `second` field is undocumented. `fastboot boot` is also reported broken on newer firmware by the Shield-specific [shieldTV_loader](https://github.com/andreiw/shieldTV_loader).

   NVIDIA documents cboot mutating the live DT for carveouts, VPR, EEPROM/plugin data and passing it onward; `/chosen` bootargs and memory reservations must therefore be preserved ([CBoot features](https://docs.nvidia.com/jetson/archives/l4t-archived/l4t-3275/Tegra%20Linux%20Driver%20Package%20Development%20Guide/software_features_tx1.html)). **UNCERTAIN:** the complete Darcy-specific mutation list. Have U-Boot preserve the cboot FDT or copy its `/memory`, `/reserved-memory`, `/chosen` and firmware data into your mainline FDT.

4. **(c) RCM/Fusée Gelée.** Last resort, primarily unbricking. The fastboot menu’s **Forced Recovery** appears to enter APX/RCM, but **UNCERTAIN:** no well-documented Darcy-specific cold-entry strap exists. Hekate is Switch-specific, not a generic Shield loader. A Shield-compatible Fusee launcher needs different offsets; this was demonstrated for the 2015 Shield, not verified for P2894 ([unbrick research](https://yifan.lu/2022/06/17/unbricking-shield-tv-2015-with-a-bootrom-exploit/)). Skipping NVIDIA stages also loses DRAM/EMC initialization, pinmux, DFLL setup and the secure monitor. Raw U-Boot alone does not replace EL3 PSCI; use correctly ported TF-A or expect SMP/hotplug/suspend failures.

### 2. DT porting order

- **UART/eMMC/PMIC first:** retain the minimal upstream P2894 base and verify the cboot memory map.
- **USB:** port exact P2894 padctl lane ownership, XUSB firmware, VBUS supplies, hub resets and port modes from downstream. Use p3450 only for mainline binding structure.
- **HDMI KMS:** host1x → display controller → SOR1 → HDMI connector, plus exact DDC bus, HPD GPIO/polarity, CEC and `vdd-hdmi-dp`.
- **GPU:** enable GM20B with the correct GPU rail, clocks/resets, IOMMU and firmware. Mesa NVK now covers Maxwell and requires Linux ≥6.6, but **UNCERTAIN:** GM20B/Tegra stability for Hyprland should be proven with `vulkaninfo` and a compositor before running Omarchy ([NVK status](https://docs.mesa3d.org/drivers/nvk.html)).

Use NVIDIA’s [9.2.2 GPL source drop](https://developer.nvidia.com/shield-open-source) and current Lineage Shield DTs as hardware oracles; translate their downstream properties to mainline bindings. **UNCERTAIN until confirmed from the DTS:** Ethernet controller/bus, Broadcom module model, fan PWM/tach GPIOs, and Darcy’s exact HPD/DDC wiring.

### 3. Blind debugging

**UNCERTAIN:** UART-A is physically reachable on retail P2894; no reliable pad map was found. Do not probe presumed UART pads without voltage/continuity checks.

Best fallback stack:

- U-Boot USB gadget console/fastboot.
- Built-in XUDC plus ACM serial or ECM networking in initramfs; gadget serial exposes `/dev/ttyGS0` ([kernel documentation](https://docs.kernel.org/usb/gadget_serial.html)).
- Ramoops in a fixed, reserved, non-carveout region, then warm-reboot to Android and read `/sys/fs/pstore`; cold power loss may destroy it ([ramoops documentation](https://docs.kernel.org/6.2/admin-guide/ramoops.html)).
- Netconsole after USB Ethernet initializes; it will not capture very early crashes.
- Initramfs watchdog/reboot timeout so failed boots return to fastboot/Android.

### 4. Recovery discipline

- Unlocking wipes userdata; never relock while any custom boot/DT image is installed.
- First obtain the exact Darcy recovery package and verify entry into both fastboot and Forced Recovery.
- Keep Arch/rootfs on USB; do not repartition eMMC.
- During development, modify only the RAM-loaded image—or, if unavoidable, only `boot`.
- Never experimentally flash `dtb`, `staging/blob`, BCT, bootloader/EBT, TOS, EKS, GPT or eMMC boot hardware partitions. A wrong DTB has previously dead-looped Shield cboot and required RCM exploitation to recover.
- Use only the exact 2017 Darcy recovery image; never substitute Foster, MDarcy or Sif artifacts. NVIDIA publishes a stock [2017 recovery image](https://developer.nvidia.com/tools-downloads).

No system or Shield changes were made.
