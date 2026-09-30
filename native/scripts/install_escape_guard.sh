#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
plugin_dir="$squirrel_app/Contents/Frameworks/rime-plugins"
translation_plugin="$project_dir/build/out/librime-translation-refresh.dylib"
escape_guard="$project_dir/build/out/libsquirrel-escape-guard.dylib"
marker="$HOME/Library/Rime/input_translation.escape_guard.enabled"
diagnostic_marker="$HOME/Library/Rime/input_translation.key_diagnostic.enabled"
trace_marker="$HOME/Library/Rime/input_translation.escape_guard.trace"

if [ ! -x "$squirrel_app/Contents/MacOS/Squirrel" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi

if [ ! -f "$translation_plugin" ] || [ ! -f "$escape_guard" ]; then
  echo "Build the project first: $script_dir/build.sh" >&2
  exit 1
fi
"$script_dir/sign_squirrel.sh" --check "$squirrel_app"

sudo install -m 755 "$translation_plugin" \
  "$plugin_dir/librime-translation-refresh.dylib"
sudo install -m 755 "$escape_guard" \
  "$plugin_dir/libsquirrel-escape-guard.dylib"
mkdir -p "$(dirname "$marker")"
touch "$marker"
# Remove the temporary tracer; Rime may load every dylib in this directory
# independently of the opt-in marker, so clearing the marker alone is not enough.
rm -f "$diagnostic_marker"
sudo rm -f "$plugin_dir/libsquirrel-input-diagnostic.dylib"
if [ "${ESCAPE_GUARD_TRACE:-0}" = "1" ]; then
  touch "$trace_marker"
  : > /tmp/squirrel-escape-guard.log
else
  rm -f "$trace_marker"
fi
"$script_dir/sign_squirrel.sh" "$squirrel_app"

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then break; fi
  sleep 0.25
done
open "$squirrel_app"
echo "Installed and enabled the conditional Escape guard."
