#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
cd "$REPO_DIR"
mkdir -p build
SDK_PATH=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
for script in build.sh install.sh Sam2017.wrapper.sh tests/run.sh; do /bin/sh -n "$script"; done
shasum -a 256 -c SHA256SUMS
./build.sh "$REPO_DIR/build/fusionfix.dylib"
printf 'int main(void) { return 0; }\n' > build/fixture-game.c
xcrun clang -isysroot "$SDK_PATH" -arch x86_64 build/fixture-game.c -o build/fixture-game
python3 tests/test_installer.py
xcrun clang -isysroot "$SDK_PATH" -fobjc-arc -fblocks -O1 -Wall -Wextra -Wno-unused-function -Werror \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  tests/runtime_tests.m -o build/runtime-tests
./build/runtime-tests
xcrun clang -isysroot "$SDK_PATH" -fobjc-arc -fblocks -O2 -Wall -Wextra -Wformat=2 -Werror -dynamiclib \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  fusionfix.m -o build/fusionfix-native.dylib
xcrun clang -isysroot "$SDK_PATH" -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework QuartzCore tests/helper_guard.m -o build/helper-guard
./build/helper-guard "$REPO_DIR/build/fusionfix-native.dylib"
