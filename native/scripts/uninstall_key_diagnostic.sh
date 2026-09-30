#!/bin/sh
set -eu

squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
plugin_dir="$squirrel_app/Contents/Frameworks/rime-plugins"
marker="$HOME/Library/Rime/input_translation.key_diagnostic.enabled"

rm -f "$marker"
"$(dirname "$0")/sign_squirrel.sh" --check "$squirrel_app"
sudo rm -f "$plugin_dir/libsquirrel-input-diagnostic.dylib"
"$(dirname "$0")/sign_squirrel.sh" "$squirrel_app"

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then break; fi
  sleep 0.25
done
open "$squirrel_app"
echo "Diagnostic hook removed. Metadata log retained at /tmp/squirrel-input-diagnostic.log"
