#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
plugin="$project_dir/build/out/librime-translation-refresh.dylib"
diagnostic="$project_dir/build/out/libsquirrel-input-diagnostic.dylib"
plugin_dir="$squirrel_app/Contents/Frameworks/rime-plugins"
marker="$HOME/Library/Rime/input_translation.key_diagnostic.enabled"

if [ ! -x "$squirrel_app/Contents/MacOS/Squirrel" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi

if [ ! -f "$plugin" ] || [ ! -f "$diagnostic" ]; then
  echo "Build the project first: $script_dir/build.sh" >&2
  exit 1
fi
"$script_dir/sign_squirrel.sh" --check "$squirrel_app"

sudo install -m 755 "$plugin" "$plugin_dir/librime-translation-refresh.dylib"
sudo install -m 755 "$diagnostic" "$plugin_dir/libsquirrel-input-diagnostic.dylib"
mkdir -p "$(dirname "$marker")"
touch "$marker"
"$script_dir/sign_squirrel.sh" "$squirrel_app"

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then break; fi
  sleep 0.25
done
open "$squirrel_app"
echo "Diagnostic enabled. Reproduce the issue; metadata-only log: /tmp/squirrel-input-diagnostic.log"
