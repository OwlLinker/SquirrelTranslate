#!/bin/sh
set -eu

squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
marker="$HOME/Library/Rime/input_translation.escape_guard.enabled"

rm -f "$marker"
"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then break; fi
  sleep 0.25
done
open "$squirrel_app"
echo "Disabled the Escape guard. The installed dylib remains inert without its marker."
