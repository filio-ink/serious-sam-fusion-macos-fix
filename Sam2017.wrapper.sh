#!/bin/sh
# Installed by install.sh. Remove Steam's overlay before running any child process.
unset DYLD_INSERT_LIBRARIES
D=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && pwd -P) || exit 1
case "$D" in
  *:*) echo 'fusionfix: the game path must not contain a colon (dyld path separator).' >&2; exit 1 ;;
esac
case "${0##*/}" in
  Sam2017) REAL=Sam2017_real; LIBRARY=fusionfix.dylib ;;
  Sam2017_Unrestricted) REAL=Sam2017_Unrestricted_real; LIBRARY=fusionfix-unrestricted.dylib ;;
  *) echo 'fusionfix: unsupported launcher name.' >&2; exit 1 ;;
esac
if [ ! -f "$D/$REAL" ] || [ ! -x "$D/$REAL" ] || [ -L "$D/$REAL" ]; then
  echo "fusionfix: original executable $REAL missing or unsafe; restore the matching backup." >&2
  exit 1
fi
if [ -L "$D/$LIBRARY" ]; then
  echo "fusionfix: refusing a symbolic link in place of $LIBRARY." >&2
  exit 1
fi
if [ -f "$D/$LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$D/$LIBRARY"
fi
# No file redirects: Steam owns stderr. FUSIONFIX_LOG=1 opts into diagnostics.
# FUSIONFIX_NO_NOTCH=1 preserves AppKit's default fullscreen safe area.
exec "$D/$REAL" "$@"
