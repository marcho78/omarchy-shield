#!/usr/bin/env bash
# Build the Linux kernel for the SHIELD TV 2017: the pinned stable release,
# arm64's defconfig with every platform but Tegra switched off, and
# kernel/darcy.config merged in. Only the image is built: the first
# payloads carry no modules.
#
# Output: build/linux/arch/arm64/boot/Image.gz
#
# Usage: scripts/11-build-kernel.sh
source "$(dirname "$0")/lib.sh"
need make aarch64-linux-gnu-gcc bc flex bison

"$ROOT/scripts/03-fetch-sources.sh" linux
src="$ROOT/vendor/linux"
out="$ROOT/build/linux"
kmake=(make -C "$src" O="$out" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)

mkdir -p "$out"
log "configuring: defconfig, Tegra only, kernel/darcy.config"
"${kmake[@]}" -s defconfig
{
  # Every platform but Tegra off: they only cost size and build time
  grep -oE '^config ARCH_[A-Z0-9_]+' "$src/arch/arm64/Kconfig.platforms" |
    awk '$2 != "ARCH_TEGRA" { print "# CONFIG_" $2 " is not set" }'
  cat "$ROOT/kernel/darcy.config"
} > "$out/darcy.fragment"
"$src/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "$out/darcy.fragment" > /dev/null
"${kmake[@]}" -s olddefconfig

# Kconfig silently drops what it cannot satisfy, so check the result
while read -r line; do
  if [[ $line =~ ^(CONFIG_[A-Z0-9_]+)=y$ ]] && ! grep -qx "$line" "$out/.config"; then
    die "${BASH_REMATCH[1]} did not end up built in"
  fi
done < "$ROOT/kernel/darcy.config"

log "building Image.gz"
"${kmake[@]}" -s -j"$(nproc)" Image.gz
log "built build/linux/arch/arm64/boot/Image.gz ($(stat -c %s "$out/arch/arm64/boot/Image.gz") bytes)"
