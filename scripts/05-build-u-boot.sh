#!/usr/bin/env bash
# Build U-Boot for the SHIELD TV 2017: the pinned LineageOS U-Boot plus our
# board patches in patches/u-boot/. The source tree is reset to the pinned
# commit first, so every build starts from the same code.
#
# Output: build/u-boot/u-boot-dtb.bin, the image cboot starts as the
# "kernel" of an Android boot image (see scripts/06).
#
# Usage: scripts/05-build-u-boot.sh
source "$(dirname "$0")/lib.sh"
need git make aarch64-linux-gnu-gcc

"$ROOT/scripts/03-fetch-sources.sh" lineage-u-boot
src="$ROOT/vendor/lineage-u-boot"
out="$ROOT/build/u-boot"
make_=(make -C "$src" O="$out" CROSS_COMPILE=aarch64-linux-gnu-)

log "resetting vendor/lineage-u-boot and applying patches/u-boot/"
git -C "$src" -c advice.detachedHead=false checkout -q -f "$(source_commit lineage-u-boot)"
git -C "$src" clean -q -fd
for p in "$ROOT"/patches/u-boot/*.patch; do
  git -C "$src" apply --whitespace=nowarn "$p"
done

log "building"
"${make_[@]}" -s p2894_defconfig
"${make_[@]}" -s -j"$(nproc)" u-boot-dtb.bin 2> "$out/build-warnings.log" ||
  { cat "$out/build-warnings.log" >&2; die "U-Boot build failed"; }
"${make_[@]}" -s u-boot-initial-env

# Safety invariants for code that runs on the SHIELD; Kconfig can silently
# flip options when others change, so check the result, not the defconfig.
log "checking safety invariants"
grep -qx 'bootcmd=run darcy_boot' "$out/u-boot-initial-env" || die "bootcmd is not 'run darcy_boot'"
grep -qx 'CONFIG_ENV_IS_NOWHERE=y' "$out/.config" || die "the environment must never be saved"
for opt in TEGRA_GPU NET EFI_LOADER CMD_SAVEENV CMD_MMC CMD_SF MMC_WRITE; do
  if grep -qx "CONFIG_$opt=y" "$out/.config"; then
    die "CONFIG_$opt must be off"
  fi
done
[[ $(fdtget "$out/arch/arm/dts/tegra210-p2894.dtb" /framebuffer status) == disabled ]] ||
  die "the framebuffer must stay disabled until cboot reports one"

log "built build/u-boot/u-boot-dtb.bin ($(stat -c %s "$out/u-boot-dtb.bin") bytes)"
