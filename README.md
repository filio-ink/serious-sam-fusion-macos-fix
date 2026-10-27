# Serious Sam Fusion 2017: fixes for modern macOS / Apple Silicon

The Steam version of **Serious Sam Fusion 2017** (build 440323, last updated June 2019, x86_64, runs under
Rosetta 2) has been "windowed mode only, crashes a lot" on Macs for years. The engine logs and macOS crash
reports point at three separate problems, and each one has a small fix. With all three applied the game runs
in real fullscreen at the native panel resolution (3024x1890 on a 14" MacBook Pro) with Ultra settings and
4x MSAA, without crashes.

This fork hardens the original fix from [pajacloud/serious-sam-fusion-macos-fix](https://github.com/pajacloud/serious-sam-fusion-macos-fix).
The upstream author reported gameplay testing on a 14" M4 Pro MacBook Pro, macOS 27.0.1, in October 2026.
The changes in this fork have automated installation and object-lifetime tests; **gameplay testing of this
revision is still pending**. Fullscreen transitions and the first frame after an asynchronous render-layer
repair especially need a real-game check. Original executable bytes are preserved in a separate backup.

Upstream Steam guide (describes the original manual installation):
https://steamcommunity.com/sharedfiles/filedetails/?id=3824868534

## Changes in this fork

* Offline installer compiles and validates the fix before replacing the launcher, preserves the original,
  rejects repeat installation and rolls back caught installation failures.
* ARC zeroing weak references prevent stale pointers after render layers or fullscreen views are destroyed.
  Fullscreen state is recorded only after successful entry, and cleared before exit can re-enter a hook.
* Added view mutations run on the main thread. Render-thread repairs are queued asynchronously, without a
  synchronous wait that could deadlock the UI and renderer.
* Diagnostics are opt-in on stderr. Neither the wrapper nor the library opens a log path.
* The library checks the executable name before installing hooks, so inherited injection into helper
  processes does not change their graphics methods.

See [SECURITY.md](SECURITY.md) for trust assumptions and remaining limits.

## The three problems

### 1. Crash in windowed mode: the Steam Overlay

Symptom: the game dies a few seconds after reaching the menu, or as soon as you resize the window
(`Segmentation fault: 11`). The engine's own crash log (`Log/Sam2017.log` in the game folder) shows the stack:

```
libobjc.A.dylib
gameoverlayrenderer.dylib
gameoverlayrenderer.dylib
Sam2017
```

`gameoverlayrenderer.dylib` is the Steam Overlay, which Steam injects into every game with
`DYLD_INSERT_LIBRARIES`. In this 2019 build it crashes whenever the Metal layer is resized.

Two things that do **not** help on macOS:

* Unticking "Enable the Steam Overlay while in-game" in the game's properties. Steam still injects the dylib.
* The launch option `env -u DYLD_INSERT_LIBRARIES %command%`. The macOS client fails to launch the game with it
  (`AppError_46` in the Steam log).

What works: replace the game executable with a tiny `/bin/sh` wrapper that drops the variable and `exec`s the real
binary (`Sam2017.wrapper.sh` in this repo). Side effects: no Shift+Tab overlay and no F12 screenshots in this game.
Achievements and Steam Cloud saves work normally.

### 2. Crash in fullscreen: the 2007 fullscreen API

Symptom: white screen right after start, then the game is gone. The engine log ends with
`Failed creating pipeline state: rasterSampleCount (0) is not supported by device` and the macOS crash report says
`-[_MTLCommandBuffer presentDrawable:] failed assertion 'drawable must not be nil'`.

Cause: the engine calls `-[NSView enterFullScreenMode:withOptions:]`. On current macOS the view inside the
fullscreen window gets a default backing layer before the engine attaches its own `CAMetalLayer`, so the engine's
layer never ends up on screen (bounds 0x0, no superlayer), `nextDrawable` returns nil and Metal aborts the process.
This is why `+gfx_bFullScreen 0` (windowed only) has been the standard workaround.

Fix: `fusionfix.m`, a small Objective-C library injected through the same wrapper. It remembers the engine's
`CAMetalLayer` (the engine calls `setDevice:` on it) and attaches it to the fullscreen view as soon as both exist.
Set `FUSIONFIX_LOG=1` to write diagnostics to the existing stderr descriptor. No log file is created.

### 3. "Unable to detect graphics hardware" on every launch

`Content/Shared/Config/SystemCompatibility.lua` compares your hardware with the string stored in
`prj_strLastCompatibilityCheckSetup` and clears your "don't show this again" choice whenever they differ. A game
that crashes never saves its `.ini`, so that string stays empty and the dialog is back every time. Once the two
crashes above are fixed, answer Yes / Yes once and quit the game normally; the setting then sticks. Or, with the game
closed, set this in `~/Library/Application Support/Steam/userdata/<your id>/564310/local/SeriousSam2017.ini`:

```
prj_strDisabledCompatibilityCheckMessages = "*";
```

The script treats `"*"` as "all compatibility messages disabled".

## Install

Close the game before installing or uninstalling. Xcode command line tools are required (`xcode-select --install`).
Run as the Steam library owner, without `sudo`.

Choose and review a **specific full commit SHA** in this fork before running downloaded code. Replace the
placeholder below with that 40-character SHA. The block stops on any error and does not execute files from a
moving branch. A checksum manifest detects changed build inputs; it does not authenticate an untrusted repository.

```sh
(
  set -eu
  REVIEWED_COMMIT='REPLACE_WITH_THE_REVIEWED_40_CHARACTER_COMMIT_SHA'
  [ "${#REVIEWED_COMMIT}" -eq 40 ] || { echo 'Set REVIEWED_COMMIT first' >&2; exit 1; }
  case "$REVIEWED_COMMIT" in *[!0-9a-f]*) echo 'Expected a lowercase hexadecimal commit SHA' >&2; exit 1 ;; esac
  git clone --no-checkout https://github.com/filio-ink/serious-sam-fusion-macos-fix.git
  cd serious-sam-fusion-macos-fix
  git checkout --detach "$REVIEWED_COMMIT"
  shasum -a 256 -c SHA256SUMS
  ./install.sh
)
```

The default location is `~/Library/Application Support/Steam/steamapps/common/Serious Sam Fusion 2017`.
For another Steam library, use the checked-out installer with the **game root**, not `Bin/x64`:

```sh
./install.sh --game-dir '/Volumes/Games/steamapps/common/Serious Sam Fusion 2017'
```

Installation checks for a regular x86_64 Mach-O game executable, verifies build inputs and compiles locally
before replacing any game files. It keeps the original as `Bin/x64/Sam2017_real` and records checksums for
uninstall. An existing backup or library causes an error without overwriting it. To update a managed
installation, uninstall first, then install the newly reviewed revision. A legacy manual installation must
be restored to its original state first; the installer does not adopt unknown backups.

Then start the game from Steam as usual. Keep this source checkout for uninstalling and diagnostics.
`./build.sh` builds only the library without installing. ARC is required; old `-fno-objc-arc` commands are unsupported.
If your SDK and toolchain do not match, select a compatible installed SDK for a single command, for example
`SDKROOT=/path/to/MacOSX.sdk ./build.sh`; no global Xcode settings need to change.

To start in fullscreen, pick Fullscreen in Graphics Options (or set `gfx_bFullScreen = 1;` plus
`gfx_pixResWidth` / `gfx_pixResHeight` in the `.ini`). Remove any `+gfx_bFullScreen 0` launch option you added earlier.

On a MacBook with a notch you can use the whole panel (3024x1964 on the 14"): the library extends the fullscreen
window over the top safe area, so the picture is not cut off at the bottom and the notch just hides a sliver of
the top strip. Set `FUSIONFIX_NO_NOTCH=1` in the launch environment if you prefer AppKit's safe-area behaviour, or simply pick
a 16:10 mode such as 3024x1890.

## Uninstall

From the saved source checkout:

```sh
./install.sh --uninstall
# Or add --game-dir '/path/to/Serious Sam Fusion 2017' for a custom library.
```

The uninstaller verifies the original backup, installed wrapper and library against the saved installation
checksums before restoring the original. If Steam verification or manual edits changed them, it stops for
inspection. It does not remove saves or configuration files. Steam's "Verify integrity of game files" can
also restore the executable, but leaves unmanaged extra files which should be inspected before reinstalling.
If an operation was terminated without allowing cleanup, inspect `.fusionfix-lock` and the preserved
`Sam2017_real` before retrying; do not replace an original backup with a shell wrapper.

## Diagnostics and development

`FUSIONFIX_LOG=1` enables stderr messages. Other values, including old file paths, do not enable logging.
To capture diagnostics yourself, launch the wrapper from a terminal with stderr directed to a file you own.
The wrapper does not create or append `Log/stderr.log` or `Log/fusionfix.log`.

Run `./tests/run.sh` on macOS with Xcode tools and Python 3. It builds the target x86_64 library and runs
installer failure/rollback tests, zeroing weak-reference and main-thread tests, and an actual `dlopen` check
that helper processes are not hooked. Fixtures use temporary directories and model objects; no live game
files, GPU or window server are needed. These tests do not verify gameplay or Rosetta execution.
After intentionally changing build inputs, regenerate the manifest with
`shasum -a 256 fusionfix.m Sam2017.wrapper.sh build.sh > SHA256SUMS`.

## Notes

* Windowed mode renders at 1x, not Retina. The engine has no HiDPI support at all (no `contentsScale` or
  `backingScaleFactor` anywhere in the binary). Forcing `contentsScale = 2` makes it draw into one quadrant of the
  drawable, so fullscreen is the way to get the full resolution.
* Fullscreen uses the old display-capture API, so Cmd+Tab is clunky. That is how the game always behaved.
* Switching between windowed and fullscreen while the game is running has not been tested much. If the game
  stops starting after a settings change, accept the "safe mode" offer at the next start or add `+gfx_bFullScreen 0`
  to the launch options temporarily.
* The game has not been updated since 2019, so these notes should stay valid.

## License

MIT. No warranty. Serious Sam and the Serious Engine belong to Croteam.
