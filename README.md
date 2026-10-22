# Serious Sam Fusion 2017: fixes for modern macOS / Apple Silicon

The Steam version of **Serious Sam Fusion 2017** (build 440323, last updated June 2019, x86_64, runs under
Rosetta 2) has been "windowed mode only, crashes a lot" on Macs for years. The engine logs and macOS crash
reports point at three separate problems, and each one has a small fix. With all three applied the game runs
in real fullscreen at the native panel resolution (3024x1890 on a 14" MacBook Pro) with Ultra settings and
4x MSAA, without crashes.

Tested on a MacBook Pro 14" (M4 Pro, 24 GB), macOS 27.0.1, current Steam client, October 2026.
Nothing in the game binary is modified; everything is reversible.

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

Fix: `fusionfix.m`, about 100 lines of Objective-C injected through the same wrapper. It remembers the engine's
`CAMetalLayer` (the engine calls `setDevice:` on it) and attaches it to the fullscreen view as soon as both exist.
It also writes what it did to `Log/fusionfix.log`.

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

Needs the Xcode command line tools (`xcode-select --install`) for the one-line compile.

```sh
cd ~/Library/Application\ Support/Steam/steamapps/common/Serious\ Sam\ Fusion\ 2017/Bin/x64
mv Sam2017 Sam2017_real
curl -LO https://raw.githubusercontent.com/pajacloud/serious-sam-fusion-macos-fix/main/fusionfix.m
curl -LO https://raw.githubusercontent.com/pajacloud/serious-sam-fusion-macos-fix/main/Sam2017.wrapper.sh
xcrun clang -arch x86_64 -dynamiclib -fno-objc-arc -mmacosx-version-min=10.14 -O2 \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  -o fusionfix.dylib fusionfix.m
mv Sam2017.wrapper.sh Sam2017 && chmod 755 Sam2017
```

Then start the game from Steam as usual. Please compile the library yourself from the source instead of downloading
a binary from someone you don't know; that is the whole point of keeping it this small.

To start in fullscreen, pick Fullscreen in Graphics Options (or set `gfx_bFullScreen = 1;` plus
`gfx_pixResWidth` / `gfx_pixResHeight` in the `.ini`). Remove any `+gfx_bFullScreen 0` launch option you added earlier.

## Uninstall

Delete `Sam2017` (the wrapper) and `fusionfix.dylib`, rename `Sam2017_real` back to `Sam2017`.
Or use "Verify integrity of game files" in Steam, which restores the original executable (and therefore also
brings the crashes back).

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
