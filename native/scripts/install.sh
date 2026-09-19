#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
plugin="$project_dir/build/out/librime-translation-refresh.dylib"
target="$squirrel_app/Contents/Frameworks/rime-plugins/librime-translation-refresh.dylib"
helper="$project_dir/src/deepl_web_session.py"
target_helper="$squirrel_app/Contents/Frameworks/rime-plugins/deepl_web_session.py"

if [ ! -f "$plugin" ]; then
  echo "Build the extension first: $script_dir/build.sh" >&2
  exit 1
fi

if ! strings "$squirrel_app/Contents/MacOS/Squirrel" | grep -qF _refresh_ui; then
  echo "This Squirrel build does not support _refresh_ui." >&2
  exit 1
fi

if ! /usr/bin/python3 -c 'from websockets.sync.client import connect' >/dev/null 2>&1; then
  echo "Install Python module websockets for DeepL web translation." >&2
  exit 1
fi

sudo install -m 755 "$plugin" "$target"
sudo install -m 755 "$helper" "$target_helper"
sudo codesign --force --deep --sign - \
  --preserve-metadata=entitlements,requirements,flags,runtime \
  "$squirrel_app"

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
open "$squirrel_app"

echo "Installed: $target"
