#!/bin/sh
# Installed by install.sh. Remove Steam's overlay before running any child process.
unset DYLD_INSERT_LIBRARIES
D=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && pwd -P) || exit 1
case "$D" in
  *:*) echo 'fusionfix: the game path must not contain a colon (dyld path separator).' >&2; exit 1 ;;
esac
if [ ! -f "$D/Sam2017_real" ] || [ ! -x "$D/Sam2017_real" ] || [ -L "$D/Sam2017_real" ]; then
  echo 'fusionfix: original executable missing or unsafe; restore it using install.sh --uninstall or Steam verification.' >&2
  exit 1
fi
if [ -L "$D/fusionfix.dylib" ]; then
  echo 'fusionfix: refusing a symbolic link in place of fusionfix.dylib.' >&2
  exit 1
fi
if [ -f "$D/fusionfix.dylib" ]; then
  export DYLD_INSERT_LIBRARIES="$D/fusionfix.dylib"
fi
# No file redirects: Steam owns stderr. FUSIONFIX_LOG=1 opts into diagnostics.
# FUSIONFIX_NO_NOTCH=1 preserves AppKit's default fullscreen safe area.
exec "$D/Sam2017_real" "$@"
