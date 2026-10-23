# Review brief: the Omarchy shell's colours on the SHIELD (Qt 6.12)

Repo: `~/projects/nvidia` (commit 54988ed). Device: NVIDIA SHIELD TV 2017 running Arch Linux ARM, mainline Linux 7.2.11, Hyprland 0.56.2, Quickshell 0.3.2-1, qt6-declarative 6.12.0-2. Omarchy comes from the community omarchy-arm port (`vendor/omarchy-arm`, pin 579f15c, Omarchy 4.0.0.alpha), with our patches in `patches/omarchy-arm/` applied by `scripts/20-install-omarchy.sh`. The user's laptop runs upstream Omarchy 4.5.0rc1 (x86, quickshell 0.3.2.r7.g2b4501a, qt6-declarative 6.12.0-1), where the bar works.

## What happened

After the first boot into Omarchy, the top bar had no background and its text was nearly invisible. With `transparent: false` it became a black strip, still with no text. Each time the shell started it logged about 1100 errors, in the bar, the lock screen, the polkit dialog and the menus:

- `@plugins/bar/Bar.qml[66:3]: Unable to assign [undefined] to QColor`
- `TypeError: Cannot read property 'text' of undefined` (also `'background'`, `'border'`, `'active'`)
- `Commons/Border.qml[25]: Cannot read property 'polkit.border-alpha' of undefined`

## Evidence

- A minimal test shell with three imports (`import Quickshell`, `import QtQuick`, `import qs.Commons`) logged `Color` as `QQuickColor(0x...)`, `Color.bar` as undefined, and `Color.shellValues` as undefined.
- `/usr/lib/qt6/qml/QtQuick/plugins.qmltypes:3551` (on the SHIELD and on the laptop) declares `name: "QQuickColor"`, `exports: ["QtQuick/Color 6.12"]`, `isSingleton: true`, with methods such as `rgba`. So Qt 6.12 adds a `Color` singleton to QtQuick.
- On the laptop, Omarchy 4.5's shell has `import qs.Commons as Commons` in 75 files and writes `Commons.Color` 346 times, with no bare `Color.` left. That includes Commons' own `Border.qml` and `Style.qml`. omarchy-arm's 4.0 alpha had bare `Color.` in 54 files.
- I compared every singleton and type name in the shell's qmldirs with the types exported by QtQuick, QtQml, QtQuick.Layouts and Quickshell 6.12. `Color` was the only clash.

## The fix (please review)

- `patches/omarchy-arm/0002-shell-name-the-Color-singleton-through-its-module.patch` was made with the commands in its message:
  - perl replaces `Color.<identifier>` (excluding `Color.qml`) with `Commons.Color.<identifier>`.
  - It adds `import qs.Commons as Commons` after the last import line where that import is missing.
  - It updates the one test that matched `color: Color.accent`.
- I checked that no replacement landed inside a string literal.
- omarchy-arm's `./test/shell`: 2472 tests pass. 3 fail because they need an omarchy-pkgs checkout; they fail without the patch too.
- On the SHIELD I copied the 54 files into `/usr/share/omarchy/shell` and ran `omarchy-restart-shell`. No colour errors appeared at startup, the bar shows tokyo-night's `#1a1b26` background with readable text and icons, and the lock screen has its colours. The user confirmed the bar is visible.
- `scripts/20` change: SDDM's Omarchy theme (`default/sddm/omarchy/Main.qml:10,106`) has only a password field and logs in as `userModel.lastUser`. omarchy-arm writes `/var/lib/sddm/state.conf` only in its first-boot `omarchy-provision-owner` (`configure_login`). scripts/20 creates the user itself, so login failed with "User name not set" until state.conf was written. scripts/20 now writes `[Last] Session=omarchy.desktop User=$user` with `install -d -m 750 -o sddm -g sddm`.

## Questions

1. Why does QtQuick's `Color` win over `qs.Commons`' `Color`, even when `import qs.Commons` comes after `import QtQuick`? In Commons' own files, Color comes from the implicit directory import. Is this documented QML import precedence, a Qt 6.12 change, or a Quickshell `qs.` module quirk? Is qualifying the name (what Omarchy 4.5 does) the right fix, or would something smaller be better, such as import order or a qmldir change?
2. Could the transformation have missed anything that still resolves `Color` to QtQuick's? For example: non-library JS that shares a QML context, `Qt.createQmlObject` strings, Loader `source` components, user plugins under `~/.config/omarchy/plugins`, or the SDDM theme (I grep'd the whole tree for `Color.` in .qml and .js: none left).
3. Do you see other Qt 6.12 or Quickshell 0.3.2 incompatibilities in this 4.0-alpha shell? These warnings remain at startup, both before and after the patch:
   - 4x per target: `Handler was registered but will not be used because another handler is registered for target omarchy.clock` (also weather, power, network, bluetooth, audio, indicators, system-update, monitor, agents)
   - 6x `Layershell screen does not correspond to a real screen. Letting the compositor pick.`
   - `Got removal for monitor "FALLBACK" which was not previously tracked.`
   - `Not creating lock surface for screen QScreen(..., name="") as it is not backed by a valid wayland output.`
4. Restarting the shell while the session was locked (the idle lock, with the TV's DPMS off) killed the lock client. The new shell took the lock and reported `secure: true` within 7 s, but `omarchy-restart-shell` still gave up after 30 s ("the session lock was not re-secured"). When DPMS came back on, Hyprland showed its "lockscreen app died" screen for up to half a minute before the shell's lock screen. Any idea why? Is there a safe way to restart the shell on a locked session?
5. The scripts/20 state.conf approach: is it right? For a media center, would SDDM autologin (as `omarchy-provision-owner` does for the first boot) be a better default?

Analysis only: change nothing in the repo or on the SHIELD.
