#!/usr/bin/env bash
# Build Mesa for the SHIELD on the SHIELD, as a pacman package
# (packages/mesa-darcy: Arch Linux ARM's release for Tegra210 alone, with
# patches/mesa), and put it in place of Arch Linux ARM's mesa. Without the
# patch every OpenGL program crashes in the tegra driver (NOTES.md).
#   1. The build tools, and a user "build": makepkg doesn't run as root.
#   2. 4 GiB of swap for the build, when the SHIELD has none (3 GB of RAM).
#   3. makepkg runs as a service, so it outlives a dropped SSH session; this
#      waits for it. About an hour.
#   4. Unless --no-install, mesa-darcy replaces mesa. Arch Linux ARM's comes
#      back with: pacman -S mesa
#
# Needs SSH as root with device-info/ssh/id_ed25519 (scripts/13).
#
# Usage: scripts/19-build-mesa.sh [--no-install] <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh tar

install=true
if [[ ${1:-} == --no-install ]]; then
  install=false
  shift
fi
host=${1:-}
[[ -n $host ]] || die "usage: $0 [--no-install] <the SHIELD's address>"
[[ -f $ROOT/device-info/ssh/id_ed25519 ]] ||
  die "no device-info/ssh/id_ed25519: scripts/13 makes it, with the root filesystem"

dir=/home/build/mesa-darcy
deps=$(source "$ROOT/packages/mesa-darcy/PKGBUILD" && echo "${depends[*]} ${makedepends[*]}")

log "build tools, and the user that builds"
on_shield "pacman -S --needed --noconfirm base-devel $deps && { id build >/dev/null 2>&1 || useradd -m build; }"

log "the recipe and patches/mesa, in $dir"
tar -cf - -C "$ROOT/packages/mesa-darcy" PKGBUILD -C "$ROOT/patches/mesa" . |
  on_shield "rm -rf $dir && mkdir -p $dir && tar -xf - -C $dir --no-same-owner && chown -R build: $dir"

log "swap for the build"
on_shield '[ -n "$(swapon --noheadings)" ] || { fallocate -l 4G /swapfile-build && chmod 600 /swapfile-build &&
  mkswap -q /swapfile-build && swapon /swapfile-build; }'

log "building, about an hour (the log: $dir/build.log)"
on_shield "systemctl reset-failed darcy-mesa-build 2>/dev/null; systemd-run --quiet --unit=darcy-mesa-build \
  --uid=build --working-directory=$dir -p StandardOutput=file:$dir/build.log -p StandardError=inherit \
  makepkg -f --noconfirm"
while :; do
  sleep 60
  status=0
  on_shield 'systemctl is-active --quiet darcy-mesa-build' || status=$?
  ((status == 0)) && continue
  # 255: no SSH (the SHIELD's Wi-Fi drops now and then); ask again
  ((status == 255)) || break
done
on_shield '[ ! -e /swapfile-build ] || { swapoff /swapfile-build && rm /swapfile-build; }'

# Arch Linux ARM's makepkg.conf makes .pkg.tar.xz
pkg=$(on_shield "cd $dir && ls mesa-darcy-*-aarch64.pkg.tar.* 2>/dev/null | tail -1")
if [[ -z $pkg ]]; then
  on_shield "tail -n 25 $dir/build.log" >&2 || true
  die "makepkg didn't make a package (above: the end of $dir/build.log)"
fi
log "built $pkg"

if $install; then
  # pacman -U alone asks whether to remove the mesa it conflicts with, and
  # --noconfirm answers no
  log "mesa-darcy in place of mesa"
  on_shield "! pacman -Q mesa >/dev/null 2>&1 || pacman -Rdd --noconfirm mesa; pacman -U --noconfirm $dir/$pkg"
  on_shield 'pacman -Q mesa-darcy'
fi
