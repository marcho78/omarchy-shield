# Review: Omarchy shell colours under Qt 6.12

## Verdict and ranked findings

The `0002` colour patch is correct, appropriately scoped, and is the right long-term repair. Qt 6.12 exposed an existing unqualified-name collision by adding `QtQuick.Color`; naming the Omarchy singleton as `Commons.Color` removes the ambiguity instead of depending on import order. I found no missed executable `Color` references in the shipped shell.

1. **High (availability, not confidentiality): locked-session restart is fail-open on an indeterminate IPC result.** A healthy locker can be killed whenever the compositor reports locked but `omarchy-shell lock status` times out, fails, or returns malformed output. That matches the observed path much better than a failure to detect the compositor lock.
2. **Medium/low: there is no global regression test for bare `Color` references.** The mechanical edit is complete now, but the one adjusted test only checks a particular bar expression.
3. **Low: duplicate IPC warnings are real but largely intentional architectural noise.** The per-screen widget design explicitly anticipates one handler winning and broadcasting to peers. It is not a Qt 6.12 incompatibility.
4. **Low: output/FALLBACK/invalid-lock-surface warnings describe monitor lifecycle churn.** They are independent of the colour collision. Persistent warnings would merit a Quickshell/HDMI investigation, but the listed messages alone do not establish another incompatibility.

## 1. Why `QtQuick.Color` wins, and whether this is the right fix

Qt 6.12 is the trigger: it added the [`Color` singleton to `QtQuick`](https://doc.qt.io/qt-6.12/qml-qtquick-color.html). Omarchy already exports its own singleton as `Color` in `shell/Commons/qmldir:1-4`, and that object contains the expected palette fields in `shell/Commons/Color.qml:19-28`.

The exact observed winner should **not** be explained as a supported “first import wins” or “last import wins” rule. Qt's public import documentation does not offer source order as a collision-resolution contract; it explicitly presents [qualified imports as the way to make conflicting type names unambiguous](https://doc.qt.io/qt-6/qtqml-syntax-imports.html). Qt 6.12's private resolver walks an internally ordered import list and returns the first match (`qqmlimport.cpp`, `QQmlImportNamespace::resolveType`); the loader also gives the implicit `.` import special treatment and prepends normal imports in load order (`qqmltypedata.cpp:677-686` in the [Qt 6.12 source](https://github.com/qt/qtdeclarative/blob/v6.12.0/src/qml/qml/qqmltypedata.cpp)). Quickshell additionally maps `qs.<path>` to a directory relative to `shell.qml`, rather than treating it as an ordinary Qt module import ([Quickshell QML imports](https://quickshell.org/docs/v0.3.0/guide/qml-language/#manual-imports)).

**UNCERTAIN:** without `QML_IMPORT_TRACE` or instrumenting the exact Qt/Quickshell build, I cannot prove which internal insertion/caching path makes the native QtQuick singleton beat the composite `qs.Commons` singleton—especially in `Border.qml` and `Style.qml`, where the latter is also available from the implicit directory import. The empirical minimal reproducer is stronger evidence than a guessed precedence rule. This looks like Qt 6.12 adding a new conflicting candidate, not evidence that Qt 6.12 globally changed documented import precedence; Quickshell's `qs.` mapping may affect the exact resolution.

`import qs.Commons as Commons` plus `Commons.Color` is the best fix:

- It is unambiguous by language design, agrees with upstream Omarchy 4.5, and has passed both the shell tests and device validation described in the brief.
- Import order would be brittle and has already failed empirically. Pinning every `QtQuick` import to 6.11 merely hides the collision and prevents intentional 6.12 API use.
- Renaming the qmldir type would still require a tree-wide call-site migration. Adding a second qmldir alias does not fix old bare `Color`, and could make singleton identity less obvious.
- Importing the same identified module both unqualified and qualified does not create an independent palette object: QML singletons are at most one instance per engine ([Qt singleton documentation](https://doc.qt.io/qt-6.12/qml-singleton.html)). Self-importing `qs.Commons as Commons` from `Border.qml` and `Style.qml` is slightly unusual but valid, matches upstream, and is verified in practice (`patches/omarchy-arm/0002-…patch:32-81`).

## 2. Transformation coverage

The checked-out, patched tree has 54 QML files containing `Commons.Color`, and every one has `import qs.Commons as Commons`. A scan of all shell `.qml` and `.js` files found no executable bare `Color.`, `Color[`, or `Color(` occurrence; the remaining matches are comments and the `Color.qml` filename. I also found no `Qt.createQmlObject` use and no `Color` reference in the SDDM QML.

The dynamic-loading cases do not reveal a shipped-tree miss:

- `Loader.source` and `Qt.createComponent(url, …)` compile the target QML document with that document's imports. The in-tree plugin entry points used at `shell/shell.qml:295-321`, `shell/shell.qml:611-653`, and `shell/shell.qml:789-812` were part of the scan.
- `Loader.sourceComponent` uses a component declared in the enclosing QML document, which was also transformed.
- External JavaScript files contain no bare use. Inline JavaScript expressions live in their QML document and were transformed with it.
- SDDM is a separate greeter engine/theme and has no dependency on `qs.Commons`; its literal lowercase `color` properties are unrelated (`default/sddm/omarchy/Main.qml:1-18`).

The real boundary is user-installed code. The registry loads plugins from `~/.config/omarchy/plugins` (`shell/services/PluginRegistry.qml:10-14,93-108`), so an old clone or third-party plugin that imports both modules and writes bare `Color` can still fail. The migration note for plugin authors should be exactly: add `import qs.Commons as Commons` and use `Commons.Color`. Locally copied first-party plugins are likewise outside this patch's reach.

I would add a static regression test over `shell/**/*.qml` and `shell/**/*.js` that rejects executable bare `Color` access and rejects `Commons.Color` in a file lacking the alias import. The change to `test/shell.d/bar-test.sh` only updates one expected expression (`0002…patch:1932-1942`); it does not protect the global invariant. A token-aware test or `qmllint` under Qt 6.12 is preferable to a grep that mistakes comments for code.

## 3. Remaining warnings

### Duplicate `IpcHandler` targets

Quickshell requires an IPC target to be unique per instance ([`IpcHandler` documentation](https://quickshell.org/docs/v0.3.0/types/Quickshell.Io/IpcHandler/)). Its implementation keeps the first handler and warns that later handlers are unused; if the active one disappears it promotes another ([Quickshell source](https://git.outfoxxed.me/quickshell/quickshell/src/commit/cddb4f061bab495f4473ca5f2c571b6c710efef7/src/io/ipchandler.cpp)).

The shell deliberately creates bar panels per `Quickshell.screens` (`shell/plugins/bar/Bar.qml:952-988`) and places fixed-target handlers inside widgets, for example clock at `plugins/panels/clock/BarWidget.qml:133-144`, indicators at `plugins/bar/widgets/Indicators.qml:168-174`, and system-update at `plugins/bar/widgets/SystemUpdate.qml:27-37`. `Ui/BarWidget.qml:25-35` explicitly says one handler receives IPC and broadcasts the action to live peers. Thus these warnings are expected design debt, not evidence of a Qt 6.12 break.

**UNCERTAIN:** four warnings per target may mean five simultaneously live copies, or repeated registrations during screen/plugin churn; the log excerpt alone cannot distinguish them. If IPC actions work on every display, lower the priority. A cleaner eventual design is one shell/service-level handler per target that dispatches to screen instances, but it is not needed for the colour fix.

### Fake screen, `FALLBACK`, and lock surface

These messages form a coherent zero-real-output/transient-output episode: Quickshell has a placeholder `QScreen`, layer-shell windows cannot associate it with a `wl_output`, Hyprland's `FALLBACK` monitor disappears, and the lock cannot create a surface for the nameless screen. `Service.qml` already filters screens by nonempty name and positive geometry (`plugins/lock/Service.qml:41-54`), defers lock acquisition with timers (`:57-78,435-447`), and retries on `screensChanged` (`:468-476`).

Quickshell 0.3.2 explicitly added Qt 6.12 support and fixed a `WlSessionLockSurface.screen` that remained null after monitor plug, along with session-lock crashes ([0.3.2 changelog](https://quickshell.org/changelog/#v032)). Therefore these warnings are not, by themselves, another unsupported-version symptom. On this SHIELD they are more plausibly HDMI/DPMS output churn. **UNCERTAIN:** the exact six-warning count cannot be mapped reliably to the three per-screen bar window variants without a timestamped object-lifetime trace. If the warnings stop once HDMI stabilizes and all UI/lock surfaces appear, they are mostly cosmetic; if they persist on a stable output, collect `QML_IMPORT_TRACE`/Quickshell scene logging and Hyprland monitor events as a separate bug.

## 4. Restarting while locked

There is no generally safe seamless handoff between two lock clients. Under `ext-session-lock-v1`, if the active client dies the compositor **must not** unlock; it may show a solid colour and may optionally let a new client recover the lock ([protocol, client-death behavior](https://wayland.app/protocols/ext-session-lock-v1#ext_session_lock_v1)). Quickshell gives the same warning: destroying a locked `WlSessionLock` leaves a secure but potentially inoperable session ([WlSessionLock docs](https://quickshell.org/docs/v0.3.0/types/Quickshell.Wayland/WlSessionLock/)). The safe normal procedure is therefore: wake the output, unlock, then restart the shell.

The observed error narrows the script failure. Because `omarchy-restart-shell` printed “not re-secured,” `omarchy-hyprland-session-locked` must have returned success and set `relock=1`; the failure was then that the old shell's status did not parse as `.secure or .requested == true` (`bin/omarchy-restart-shell:28-37`). A 0.5-second IPC call is piped through `jq` with errors discarded. Timeout, wrong Quickshell/display selection, empty output, invalid JSON, and a real `false` all become the same empty/non-`true` value. The script then assumes a stranded lock and kills the shell (`:64-70`). The same conflation occurs in the 30-second relock loop (`:45-61`). `omarchy-shell` itself uses `timeout` and guesses the newest Wayland socket when none is exported (`bin/omarchy-shell:43-65`).

**UNCERTAIN:** the immediate cause was likely an IPC timeout or selection of the wrong instance/display during DPMS/output churn, but the current logs cannot choose between them. The fact that QML logged `secure=true` while the polling shell never accepted it particularly warrants logging the raw IPC stdout, exit status, selected shell instance, `WAYLAND_DISPLAY`, and `HYPRLAND_INSTANCE_SIGNATURE` before `jq`/stderr suppression.

The conservative repair is fail-closed operationally:

- Treat the helper's exit 2 (“undetermined,” documented at `bin/omarchy-hyprland-session-locked:10-13`) as “refuse restart,” not unlocked.
- If the compositor says locked and lock IPC is missing, timed out, or malformed, refuse by default. Recovery of a genuinely dead locker should require an explicit `--recover-stranded-lock` from SSH/TTY.
- Increase the 0.5-second status timeout on this ARM machine and preserve distinct `secure`, `requested`, `false`, and `unreadable` states.
- Do not report recovery success until both the intended new shell instance answers and its lock status is observed as secure. The QML status endpoint already exposes all relevant fields (`plugins/lock/Service.qml:511-537`).

This preserves security either way—the compositor did remain locked—but avoids turning a healthy lock into Hyprland's failsafe screen.

## 5. SDDM state and autologin

Writing `/var/lib/sddm/state.conf` is the correct fix for this install path. The theme hard-codes `currentUser: userModel.lastUser` and submits it without a username field (`default/sddm/omarchy/Main.qml:10-18,104-107`). SDDM itself defines `[Last] User` and `Session` as the preselected login state ([SDDM `Configuration.h`](https://github.com/sddm/sddm/blob/develop/src/common/Configuration.h)). The values and location exactly match omarchy-arm's own `configure_login` implementation (`bin/omarchy-provision-owner:752-766`), and `scripts/20-install-omarchy.sh:150-156` creates/chowns the state directory and file appropriately.

Two minor hardening notes:

- `$user` is interpolated unquoted into the remote `printf` command at `scripts/20-install-omarchy.sh:154-156`. The pinned `OMARCHY_USER=devsecai` is safe (`config.sh:125-127`), but a configurable value should eventually be validated as a Linux username or shell-quoted.
- An atomic temporary-file-plus-rename would be cleaner, though this runs before normal SDDM use and is unlikely to race.

Permanent autologin should not be the default merely because this is a media center. The port's existing policy is sound: persistent autologin only when disk encryption is the authentication boundary; otherwise first-boot-only autologin is removed before the next boot (`bin/omarchy-provision-owner:757-795`). This `scripts/20` path did not just authenticate the owner in an interactive provisioning wizard, and the SHIELD installation is **UNCERTAIN** to have equivalent full-disk protection. Keep password login as the secure default and expose autologin as an explicit user choice. If enabled, use the standard `[Autologin] User=… Session=omarchy.desktop` drop-in rather than overloading `state.conf`.
