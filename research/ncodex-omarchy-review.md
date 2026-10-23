# Review: first Omarchy boot on darcy

## Bottom line

I would **not reboot the current plan unchanged**. The bootloader/FIT path itself is well protected, but four first-boot dependencies need attention:

1. Validate a NetworkManager association and DNS resolution with a rollback path before retiring the only working Wi-Fi stack.
2. Keep the proven `AQ_DRM_DEVICES` setting for the first Omarchy boot, and place it in each compositor's **launch environment**, not in Hyprland Lua.
3. Fix the SDDM Tegra test: its direct `os.execute()` result is unreliable inside Hyprland, so the software-cursor branch may not run.
4. Do not enable `linux-modules-cleanup.service` on this manually managed kernel. Also either enable zram/PSI in kernel #13 or disable the corresponding Omarchy facilities.

The reassuring part is that the ARM installer deliberately excludes the mkinitcpio and Limine configuration trees (`vendor/omarchy-arm/install/arm/settings.sh:11-19,86-97`), x86 NVIDIA and Snapper/Limine leaves are gated (`vendor/omarchy-arm/install/hardware/all.sh:17-23`; `vendor/omarchy-arm/install/config/all.sh:12`), and the package path does not install the `linux`, `limine`, or `limine-mkinitcpio-hook` entries merely because they appear in `omarchy-other.packages`. Plymouth is installed and themed, but its initramfs hook is skipped. I found no first-install systemd-boot operation.

## 1. Remote-access and boot hazards

### High: the network change is deferred but still a one-shot cutover

`network.sh` disables iwd and all networkd units without stopping the currently working stack (`vendor/omarchy-arm/install/hardware/network.sh:1-18`); it only stops networkd if NetworkManager is already active (`:41-43`). NetworkManager and resolved are merely enabled for the reboot (`vendor/omarchy-arm/install/config/enable-services.sh:8-14`). That explains why the install remains reachable, but it also means a syntactically present profile is not evidence that the next boot will associate.

Before reboot, require all of these:

- `sshd.service`, `NetworkManager.service`, `systemd-resolved.service`, and `avahi-daemon.service` are enabled.
- `sshd -T` reports the expected port and public-key policy.
- NetworkManager can load and activate the profile during a controlled handover, with a transient rollback unit that re-enables/starts iwd and networkd if connectivity is not confirmed. A TV keyboard is useful recovery, but should not be the test plan.
- After the test, verify an address/default route, `resolvectl query` for a public name, and a new SSH login from the host; do not treat the pre-existing SSH connection as proof.

The firewall is armed for the next boot with default-deny input (`vendor/omarchy-arm/install/config/firewall.sh:1-3,60-63`). The SSH exception runs only afterward (`vendor/omarchy-arm/install.sh:434-444`), and its fallback depends on `sshd` already being enabled when `SSH_CONNECTION` is absent (`vendor/omarchy-arm/install/arm/firewall-ssh.sh:20-32`). That environment variable will not necessarily exist in the detached `systemd-run --uid=devsecai` service used by `scripts/20-install-omarchy.sh:103-108`, so **confirm `systemctl is-enabled sshd` before the real run**. Also, the helper parses only the main `sshd_config`, not included drop-ins (`firewall-ssh.sh:37-42`); this device uses default port 22, so that limitation is harmless only while the port remains default. Confirm the actual rule with `ufw show added` before reboot.

Root's `authorized_keys` and the server's key-only configuration are not modified by Omarchy. The SSH-related Omarchy leaves change client keepalives and PAM command `PATH`, not `sshd` authentication (`install/config/ssh-keepalive.sh:1-16`; `install/config/ssh-command-path.sh:1-11`).

### High for the next kernel: module cleanup is wrong for this boot model

The base package list installs `kernel-modules-hook` and Omarchy unconditionally enables its cleanup unit (`install/omarchy-base.packages:67`; `install/config/enable-services.sh:6`). The upstream unit preserves the *currently running* `%v` and pacman-owned module trees, but moves other unowned `/usr/lib/modules/<release>` trees away. That makes the first reboot with the current 7.2.11 directory safe, but a future newly staged custom-kernel module tree can be removed **before** U-Boot first boots that kernel. See the [unit's actual `ExecStart`](https://github.com/saber-nyan/kernel-modules-hook/blob/master/linux-modules-cleanup.service).

This package/service is actively wrong here: exclude it and gate the enable line. At minimum leave `linux-modules-cleanup.service` disabled. This is more important than saving RAM.

### High: current kernel cannot provide Omarchy's zram or oomd policy

The running build has `# CONFIG_PSI is not set` and `# CONFIG_ZRAM is not set` (`build/linux/.config:140,2209`). Omarchy nevertheless installs a zram device sized to RAM with zstd (`default/systemd/zram-generator.conf.d/90-omarchy.conf:1-9`) and enables systemd-oomd (`install/config/enable-services.sh:17-20`). The memory-pressure policy needs PSI (`etc/systemd/oomd.conf.d/10-omarchy.conf:9-21`).

Thus zram creation and PSI-based oomd protection cannot work. **UNCERTAIN:** their failed units should not make the machine enter emergency mode, but they may produce a boot delay/failure state; either outcome leaves the intended 3 GB memory protection absent. Preferred fix: build `CONFIG_PSI=y`, `CONFIG_ZRAM=m` (or `y`), and `CONFIG_ZRAM_BACKEND_ZSTD=y`; this tree's zram Kconfig selects ZSMALLOC (`vendor/linux/drivers/block/zram/Kconfig:2-15,29-33`). A rootfs-loaded zram module need not be in the FIT initramfs. Otherwise omit the generator package/config and disable oomd for the first boot.

The app-slice policy correctly keeps the compositor outside the oomd kill candidate (`default/systemd/user/app.slice.d/10-oomd.conf:1-16`). Its comment says a global `SwapUsedLimit=90%` is in the oomd file (`:10-13`), but that file only sets pressure duration/limit (`etc/systemd/oomd.conf.d/10-omarchy.conf:19-21`); **UNCERTAIN:** this appears to rely on systemd's default rather than the claimed explicit setting.

### Medium: DNS and discovery need explicit preflight

The installer copies `nsswitch.conf` but does not normalize `/etc/resolv.conf` (`install/arm/settings.sh:86-97`). The original rootfs deliberately inherited a symlink into `/run/systemd/resolve` (`scripts/13-make-rootfs.sh:95-103`), so this particular image is likely fine, but verify the live link and that its target will be produced by resolved. The upgrade path explicitly creates the stub symlink while the fresh installer does not (`vendor/omarchy-arm/bin/omarchy-upgrade-to-quattro:1346`), which is a consistency gap.

Using Avahi with `mdns_minimal` is coherent: resolved's own multicast DNS is disabled (`etc/systemd/resolved.conf.d/10-disable-multicast.conf:1-3`), Avahi is enabled (`install/config/enable-services.sh:5`), and NSS sends `.local` lookups to mDNS (`etc/nsswitch.conf:11`). However, this host's NSS configuration does not itself guarantee that another computer discovers `darcy.local`. **UNCERTAIN:** upstream UFW usually admits mDNS in its before-rules, but the Omarchy rules do not explicitly allow UDP 5353 (`install/config/firewall.sh:1-11`). Add/verify a LAN-scoped 5353/UDP rule or retain a second discovery method (router lease table/permanent MAC).

`DNSStubListenerExtra=172.17.0.1` is installed even though only `docker.socket`, not dockerd, starts at boot (`etc/systemd/resolved.conf.d/20-docker-dns.conf:1-2`; `install/config/enable-services.sh:7-9`). **UNCERTAIN:** confirm resolved tolerates that not-yet-present bridge address on this systemd build; otherwise gate the Docker listener or start Docker before resolved.

### Lower risk

- SDDM failure should leave boot and SSH alive; it is enabled directly (`install/config/enable-services.sh:16`). The PAM edits affect SDDM/lock authentication, not SSH keys (`install/login/sddm.sh:1-6`; `install/config/increase-lockout-limit.sh:1-12`).
- Omarchy changes the power key to “ignore” (`etc/systemd/logind.conf.d/10-ignore-power-button.conf:1-2`), reducing local graceful-recovery options, though forced power cycling remains.
- Validate every temporary sudoers file with `visudo -cf`, install it mode 0440, and remove it through a remote cleanup unit as well as the host-side trap. The present trap can leave `NOPASSWD: ALL` behind if the host loses SSH (`scripts/20-install-omarchy.sh:103-105`).
- Confirm the pacman transaction retains `mesa-darcy`; its `provides=(mesa opengl-driver)` should satisfy consumers, but **UNCERTAIN** until the actual transaction shows no replacement/removal.

## 2. NetworkManager handover

Use NetworkManager's default **wpa_supplicant** backend for the first cutover. Upstream says that is the default and calls the iwd backend experimental; the current ALARM `networkmanager` package hard-depends on wpa_supplicant, while iwd is optional ([NetworkManager configuration](https://www.networkmanager.dev/docs/api/latest/NetworkManager.conf.html), [ALARM package metadata](https://archlinuxarm.org/packages/aarch64/networkmanager)). This removes an unnecessary variable on brcmfmac. Do not add `wifi.backend=iwd` yet.

The generated file location and protection are right: `/etc/NetworkManager/system-connections`, root-created, mode 0600 (`scripts/20-install-omarchy.sh:55-60,68-90`). A UUID is optional; NetworkManager derives one from the filename. The current image builder always wrote a simple `[Security] Passphrase=` iwd profile (`scripts/13-make-rootfs.sh:157-169`), so the extraction is correct for the measured `secnet` case. iwd also permits a 64-hex `PreSharedKey`, which NetworkManager accepts as a PSK ([iwd format](https://kernel.googlesource.com/pub/scm/network/wireless/iwd/+/refs/tags/3.4/src/iwd.network.rst), [NetworkManager keyfile format](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html)).

The script is not a general converter: filename decoding is skipped for encoded SSIDs, and raw here-doc values do not safely cover every GLib keyfile escape (`scripts/20-install-omarchy.sh:60-81`). Prefer generating the profile with `nmcli --offline connection add ...` or validate/load it with NetworkManager. Including `security=802-11-wireless-security` under `[wifi]` is good compatibility hygiene, although current NetworkManager documents that property as deprecated/no-effect.

Set `cloned-mac-address=permanent` explicitly. iwd defaults to no association-MAC randomization, and NetworkManager normally preserves it, but the explicit setting prevents a global default from changing the address. For DHCP, do **not** promise the old lease: systemd-networkd defaults to a DUID client identifier, while NetworkManager's internal DHCP client defaults to MAC when unset ([systemd `ClientIdentifier`](https://www.freedesktop.org/software/systemd/man/262/systemd.network.html), [NetworkManager `ipv4.dhcp-client-id`](https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html)). Copying an address from the old lease as a static address risks a conflict. A router reservation keyed to the permanent MAC is the clean stable-address solution; otherwise rely on tested mDNS and expect the IPv4 address may change.

## 3. Tegra platform and SDDM

Most of the platform wiring is complete and well placed: DT-compatible detection (`bin/omarchy-hw-platform:18-44`), a predicate, installer case/help, ARM Vulkan no-op (`install/hardware/arm/vulkan.sh:9-25`), hardware leaf/state, runtime Hyprland dispatch, and fixture/gating tests. The broad `nvidia,tegra210` match intentionally covers more than darcy; **UNCERTAIN:** if this is intended as darcy support rather than a Tegra210-family policy, match `nvidia,darcy`/P2894 first because Jetson/Pixel C may not share the same display-node path or patched Mesa stack.

Two corrections are needed:

1. **The SDDM software-cursor predicate is unreliable.** The greeter config calls `os.execute()` and tests its return (`default/sddm/hyprland.lua:15-25`), while this same codebase explicitly records that Hyprland reaps its children and `os.execute()` cannot retrieve their exit status (`default/hypr/helpers.lua:21-34`). Use the same stdout-marker approach, or better have the Tegra hardware leaf install/select a Tegra-specific greeter config with the cursor setting unconditional. The current hardcoded `/usr/share/omarchy` also ignores `--target`. SDDM launches this separate minimal config directly and never loads `default/hypr/platform.lua` (`etc/sddm.conf.d/10-wayland.conf:1-5`; `default/sddm/hyprland.lua:1-13`).
2. **Keep `AQ_DRM_DEVICES` for first boot.** The observed Aquamarine log makes automatic selection plausible: nouveau's render-only card is rejected as non-KMS and tegra-drm is the only KMS card. But the successful test always supplied the variable (`tools/hyprland-try.sh:75-81`), so omitting it remains **UNCERTAIN**, not measured. The stable path has no colon and is exactly the safe syntax Aquamarine documents ([Aquamarine environment variables](https://github.com/hyprwm/aquamarine/blob/main/docs/env.md)).

`AQ_DRM_DEVICES` must exist **before Aquamarine initializes**. `default/hypr/platform/tegra.lua` and `hl.env()` are too late for backend selection. For the user session, export it conditionally from the UWSM environment (`default/uwsm/env.d/10-omarchy:1-19`), which is processed before the session command (`default/wayland-sessions/omarchy.desktop:1-5`). For SDDM, place it in the compositor launch environment, e.g. a Tegra-specific wrapper/override for `CompositorCommand`, or an SDDM service drop-in. `GreeterEnvironment` affects the greeter client and should not be assumed to configure the already-starting compositor. The SDDM command itself runs as the `sddm` user in Wayland mode ([SDDM `CompositorCommand` documentation](https://github.com/sddm/sddm/blob/develop/data/man/sddm.conf.rst.in)).

The generic nouveau cursor fixer uses `lspci` (`install/user/hardware/fix-nouveau-cursor.sh:9-24`) and will not identify this SoC GPU; the Tegra Lua profile therefore remains necessary. Add a test for the SDDM Tegra branch, not only the platform predicate.

## 4. Package set on 3 GB

`--skip-packages` is all-or-nothing (`install.sh:47-56,219-220`); there is no per-run exclusion option. `packages.exclude` is applied only while reading the base list (`install.sh:228,241-256`), not to `packages.extra` (`:276-296`). Therefore selective omission is a source patch, and dependent setup leaves must be gated too.

- **Remove/gate `kernel-modules-hook` first**, for correctness rather than memory.
- **zram is desirable on 3 GB**, but only after the kernel support above exists. Its advertised size does not allocate 3 GB up front. If kernel support is deferred, removing it from `packages.extra` is necessary; `packages.exclude` alone cannot suppress it.
- Docker is not a large idle-RAM cost because only `docker.socket` is enabled, but it adds packages, firewall mutation, and membership in the root-equivalent `docker` group (`install/config/docker.sh:1-10`). It cannot currently be omitted cleanly: `docker.sh` assumes the group and `enable-services.sh:7` assumes the unit. Gate those plus Docker DNS/UFW handling before excluding `docker`, `docker-buildx`, `docker-compose`, and `lazydocker`.
- Chromium is heavy only when run, and Omarchy assumes it as the default browser (`bin/omarchy-provision-user:109-113`; `default/applications/mimeapps.list:13-14`). Omission needs a replacement/default-browser patch. For a first functional desktop, keep it and limit tabs.
- `clang` and `llvm` primarily cost storage, not idle RAM, and no first-install leaf directly invokes them. They are the cleanest large packages to exclude if disk space matters, subject to checking the final pacman dependency closure. **UNCERTAIN:** some selected development packages may still pull `llvm-libs`, which is separate.
- Do not pass `--with-aur`; the installer already leaves the expensive optional AUR set until last/off by default (`install.sh:464-491`). Required mise setup downloads Node at runtime (`install/user/mise-work.sh:15-49`) but the AI tools are lazy wrappers, not all installed during first boot (`install/user/mise.sh:1-14`; `bin/omarchy-mise-install:17-27`).

My preferred first pass is: keep the normal userland, disable the module cleanup, enable PSI+zram in the custom kernel, retain the proven DRM pin, fix SDDM cursor detection, perform a rollback-protected NetworkManager cutover, and only then reboot into SDDM.
