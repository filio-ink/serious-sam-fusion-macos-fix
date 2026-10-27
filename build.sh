#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
OUTPUT=${1:-"$REPO_DIR/fusionfix.dylib"}
SDK_PATH=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
exec xcrun clang -isysroot "$SDK_PATH" -arch x86_64 -dynamiclib -fobjc-arc -fblocks \
  -mmacosx-version-min=10.14 -O2 -Wall -Wextra -Wformat=2 -Werror \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  -o "$OUTPUT" "$REPO_DIR/fusionfix.m"
