#!/bin/sh
# Serious Sam Fusion 2017 (Steam, macOS) launcher wrapper.
# Install: in Bin/x64 rename the original executable "Sam2017" to "Sam2017_real", save this file as "Sam2017", chmod 755.
#
# 1) The Steam Overlay (gameoverlayrenderer.dylib) crashes this 2019 build whenever the Metal layer is resized.
#    Steam injects it with DYLD_INSERT_LIBRARIES, so we replace that variable before starting the real binary.
# 2) fusionfix.dylib (built from fusionfix.m) makes fullscreen work again on current macOS and logs to Log/fusionfix.log.
#    If the dylib is missing the game still starts, just without the overlay (windowed mode only).
#
# Uninstall: delete this file and fusionfix.dylib, rename Sam2017_real back to Sam2017 (or "Verify integrity of game files").
D="$(dirname "$0")"
LOGDIR="$D/../../Log"
echo "=== $(date '+%F %T') start: $*" >> "$LOGDIR/stderr.log"
export FUSIONFIX_LOG="$LOGDIR/fusionfix.log"
# On a MacBook with a notch the fullscreen picture covers the whole panel (the notch hides a sliver at the top).
# Uncomment the next line if you prefer the picture to stop below the notch (AppKit default, 16:10 area only):
# export FUSIONFIX_NO_NOTCH=1
if [ -f "$D/fusionfix.dylib" ]; then
  export DYLD_INSERT_LIBRARIES="$D/fusionfix.dylib"
else
  unset DYLD_INSERT_LIBRARIES
fi
exec "$D/Sam2017_real" "$@" 2>> "$LOGDIR/stderr.log"
