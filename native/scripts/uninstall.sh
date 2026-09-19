#!/bin/sh
set -eu

squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
target="$squirrel_app/Contents/Frameworks/rime-plugins/librime-translation-refresh.dylib"

if [ -f "$target" ]; then
  sudo rm -f "$target"
  sudo codesign --force --deep --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$squirrel_app"
fi

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
open "$squirrel_app"

echo "Removed: $target"
