#!/bin/sh
# Offline installer: prepare everything before replacing the game's executable.
set -eu
umask 077
REPO_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Serious Sam Fusion 2017"
ACTION=install
STAGE=
LOCK=
TRANSACTION=0
ORIGINAL_SHA=

fail() { echo "fusionfix: $*" >&2; exit 1; }
sha() { shasum -a 256 < "$1" | awk '{print $1}'; }
plain_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
valid_sha() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$TRANSACTION" -eq 1 ]; then
    # The backup is installed exclusively before any original file is replaced.
    if plain_file "$BACKUP" && [ "$BACKUP" -ef "$STAGE/original" ] && [ "$(sha "$BACKUP")" = "$ORIGINAL_SHA" ]; then
      if mv -f "$BACKUP" "$EXECUTABLE"; then
        rm -f "$LIBRARY" "$STATE"
        echo 'fusionfix: installation failed; original executable restored.' >&2
      else
        echo "fusionfix: rollback failed; original is preserved at $BACKUP" >&2
      fi
    else
      echo 'fusionfix: installation failed; original executable was not replaced.' >&2
    fi
  fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
  if [ -n "$LOCK" ]; then rmdir "$LOCK"; fi
  exit "$result"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION=uninstall; shift ;;
    --game-dir) [ "$#" -ge 2 ] || fail '--game-dir needs a path'; GAME_DIR=$2; shift 2 ;;
    -h|--help) echo 'Usage: ./install.sh [--uninstall] [--game-dir GAME_ROOT]'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ "$(id -u)" -ne 0 ] || fail 'run as the Steam library owner, without sudo'
[ -d "$GAME_DIR/Bin/x64" ] || fail 'game directory must contain Bin/x64'
BIN=$(CDPATH= cd -P "$GAME_DIR/Bin/x64" && pwd -P)
case "$BIN" in *:*) fail 'the game path must not contain a colon' ;; esac
[ -w "$BIN" ] || fail 'game directory is not writable'
EXECUTABLE="$BIN/Sam2017"
BACKUP="$BIN/Sam2017_real"
LIBRARY="$BIN/fusionfix.dylib"
STATE="$BIN/.fusionfix-state"
LOCK_PATH="$BIN/.fusionfix-lock"
mkdir "$LOCK_PATH" 2>/dev/null || fail 'another operation is active (or .fusionfix-lock needs inspection)'
LOCK=$LOCK_PATH
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$ACTION" = uninstall ]; then
  plain_file "$STATE" || fail 'no managed installation found; restore legacy installs using Steam verification'
  {
    IFS= read -r version
    IFS= read -r original
    IFS= read -r wrapper
    IFS= read -r library
    if IFS= read -r extra; then fail 'invalid installation state'; fi
  } < "$STATE"
  [ "$version" = fusionfix-install-v1 ] || fail 'unknown installation state version'
  valid_sha "$original" && valid_sha "$wrapper" && valid_sha "$library" || fail 'invalid saved checksums'
  plain_file "$BACKUP" && [ "$(sha "$BACKUP")" = "$original" ] || fail 'original backup changed; refusing to restore it'
  plain_file "$EXECUTABLE" && [ "$(sha "$EXECUTABLE")" = "$wrapper" ] || fail 'launcher changed (possibly Steam verification); inspect before uninstalling'
  plain_file "$LIBRARY" && [ "$(sha "$LIBRARY")" = "$library" ] || fail 'library changed; inspect before uninstalling'
  mv -f "$BACKUP" "$EXECUTABLE"
  rm "$LIBRARY" "$STATE"
  echo 'fusionfix: original executable restored.'
  exit 0
fi

absent "$BACKUP" || fail 'Sam2017_real already exists; uninstall first. The backup has not been changed.'
absent "$LIBRARY" || fail 'fusionfix.dylib already exists; inspect the previous installation first'
absent "$STATE" || fail 'installation state already exists; inspect the previous installation first'
plain_file "$EXECUTABLE" && [ -x "$EXECUTABLE" ] || fail 'Sam2017 must be a regular executable, not a symbolic link'
case "$(file -b "$EXECUTABLE")" in
  *Mach-O*executable*x86_64*) ;;
  *) fail 'Sam2017 must be the original x86_64 Mach-O executable' ;;
esac
for source in fusionfix.m Sam2017.wrapper.sh build.sh SHA256SUMS; do
  plain_file "$REPO_DIR/$source" || fail "missing or symbolic-linked source file: $source"
done
(cd "$REPO_DIR" && shasum -a 256 -c SHA256SUMS) || fail 'source checksum verification failed'
ORIGINAL_SHA=$(sha "$EXECUTABLE")
STAGE=$(mktemp -d "$BIN/.fusionfix-install.XXXXXX")
"$REPO_DIR/build.sh" "$STAGE/fusionfix.dylib"
cp -p "$EXECUTABLE" "$STAGE/original"
cp "$REPO_DIR/Sam2017.wrapper.sh" "$STAGE/Sam2017"
chmod 755 "$STAGE/Sam2017"
chmod 644 "$STAGE/fusionfix.dylib"
[ "$(sha "$STAGE/original")" = "$ORIGINAL_SHA" ] && [ "$(sha "$EXECUTABLE")" = "$ORIGINAL_SHA" ] || fail 'original executable changed during preparation'
printf 'fusionfix-install-v1\n%s\n%s\n%s\n' "$ORIGINAL_SHA" "$(sha "$STAGE/Sam2017")" "$(sha "$STAGE/fusionfix.dylib")" > "$STAGE/state"
# link() creates the backup exclusively: it cannot overwrite an existing backup.
# It links our private copy, not the live executable's inode.
TRANSACTION=1
ln "$STAGE/original" "$BACKUP"
mv "$STAGE/fusionfix.dylib" "$LIBRARY"
mv -f "$STAGE/Sam2017" "$EXECUTABLE"
mv "$STAGE/state" "$STATE"
TRANSACTION=0
echo 'fusionfix: installed. Start the game normally from Steam.'
