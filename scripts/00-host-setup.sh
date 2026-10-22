#!/usr/bin/env bash
# Install the host tools listed in config.sh (Arch Linux / Omarchy, x86_64).
source "$(dirname "$0")/lib.sh"

command -v pacman >/dev/null || die "this script expects an Arch-based host with pacman"
log "installing: ${HOST_PACKAGES[*]}"
sudo pacman -S --needed "${HOST_PACKAGES[@]}"
