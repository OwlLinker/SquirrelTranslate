#!/bin/sh
set -eu

squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
target="$squirrel_app/Contents/Frameworks/rime-plugins/librime-translation-refresh.dylib"
target_query_bridge="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-query-bridge.dylib"
target_phone_data="$squirrel_app/Contents/Frameworks/rime-plugins/phone-region-phone.dat"
target_phone_license="$squirrel_app/Contents/Frameworks/rime-plugins/phone-region-LICENSE.txt"
target_injector_loader="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-status-injector-loader.dylib"
target_injector_swift="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-status-injector-arm64.dylib"
restart_squirrel=${RESTART_SQUIRREL:-0}
url_helper_target="$HOME/Library/Rime/bin/squirrel-open-url"

if [ ! -d "$squirrel_app" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi

if [ -f "$target" ] || [ -f "$target_query_bridge" ] ||
   [ -f "$target_phone_data" ] || [ -f "$target_phone_license" ] ||
   [ -f "$target_injector_loader" ] || [ -f "$target_injector_swift" ]; then
  "$(dirname "$0")/sign_squirrel.sh" --check "$squirrel_app"
  sudo rm -f "$target" "$target_query_bridge" "$target_phone_data" \
    "$target_phone_license" \
    "$target_injector_loader" "$target_injector_swift"
  "$(dirname "$0")/sign_squirrel.sh" "$squirrel_app"
fi

rm -f "$HOME/Library/Rime/input_translation.status_injector.enabled"
rm -f "$HOME/Library/Rime/input_translation.query_bridge.enabled"
rm -f "$url_helper_target"

echo "Removed: $target"
if [ "$restart_squirrel" = "1" ]; then
  "$squirrel_app/Contents/MacOS/Squirrel" --quit || true
  open "$squirrel_app"
else
  echo "Restart Squirrel manually, or rerun with RESTART_SQUIRREL=1."
fi
