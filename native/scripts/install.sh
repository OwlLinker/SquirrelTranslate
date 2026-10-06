#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
project_root=$(CDPATH= cd -- "$project_dir/.." && pwd)
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
install_injector=${INSTALL_STATUS_INJECTOR:-0}
install_query_bridge=${INSTALL_QUERY_BRIDGE:-0}
restart_squirrel=${RESTART_SQUIRREL:-1}
plugin="$project_dir/build/out/librime-translation-refresh.dylib"
query_bridge="$project_dir/build/out/libsquirrel-query-bridge.dylib"
url_helper="$project_dir/build/out/squirrel-open-url"
url_helper_target="$HOME/Library/Rime/bin/squirrel-open-url"
target="$squirrel_app/Contents/Frameworks/rime-plugins/librime-translation-refresh.dylib"
target_query_bridge="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-query-bridge.dylib"
target_phone_data="$squirrel_app/Contents/Frameworks/rime-plugins/phone-region-phone.dat"
target_phone_license="$squirrel_app/Contents/Frameworks/rime-plugins/phone-region-LICENSE.txt"
phone_data="$project_dir/resources/phone-region-phone.dat"
phone_license="$project_dir/resources/phone-region-LICENSE.txt"
lua_filter_source="$project_root/lua/input_translation_filter.lua"
lua_filter_target="$HOME/Library/Rime/lua/input_translation_filter.lua"
lua_processor_source="$project_root/lua/input_translation_processor.lua"
lua_processor_target="$HOME/Library/Rime/lua/input_translation_processor.lua"
lua_help_source="$project_root/lua/input_translation_help.lua"
lua_help_target="$HOME/Library/Rime/lua/input_translation_help.lua"
injector_dir="$project_dir/build/injector"
injector_loader="$injector_dir/libsquirrel-status-injector-loader.dylib"
injector_swift="$injector_dir/libsquirrel-status-injector-arm64.dylib"
target_injector_loader="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-status-injector-loader.dylib"
target_injector_swift="$squirrel_app/Contents/Frameworks/rime-plugins/libsquirrel-status-injector-arm64.dylib"

if [ ! -f "$project_dir/src/translation_refresh.cc" ]; then
  echo "This public checkout contains provider implementations but not the private Rime integration; the full translation plugin cannot be installed from it." >&2
  exit 1
fi

if [ ! -d "$squirrel_app" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi

if [ ! -x "$squirrel_app/Contents/MacOS/Squirrel" ]; then
  echo "Squirrel executable not found: $squirrel_app/Contents/MacOS/Squirrel" >&2
  exit 1
fi

if [ ! -f "$plugin" ]; then
  echo "Build the extension first: $script_dir/build.sh" >&2
  exit 1
fi

if [ "$install_query_bridge" = "1" ] && [ ! -f "$query_bridge" ]; then
  echo "Build the query bridge first: $script_dir/build.sh" >&2
  exit 1
fi

if [ ! -x "$url_helper" ]; then
  echo "Build the URL helper first: $script_dir/build.sh" >&2
  exit 1
fi

if [ "$install_query_bridge" = "1" ]; then
  if [ ! -f "$phone_data" ] || [ ! -f "$phone_license" ]; then
    echo "Missing phone region database: $phone_data" >&2
    exit 1
  fi
fi
"$script_dir/sign_squirrel.sh" --check "$squirrel_app"

if [ "$install_injector" = "1" ]; then
  if [ "$(uname -m)" != "arm64" ]; then
    echo "The experimental status injector currently supports arm64 only." >&2
    exit 1
  fi
  if [ ! -f "$injector_loader" ] || [ ! -f "$injector_swift" ]; then
    "$script_dir/build_injector.sh"
  fi
fi

if ! strings "$squirrel_app/Contents/MacOS/Squirrel" | grep -qF _refresh_ui; then
  echo "This Squirrel build does not support _refresh_ui." >&2
  exit 1
fi

sudo mkdir -p "$(dirname "$target")"
sudo install -m 755 "$plugin" "$target"
if [ "$install_query_bridge" = "1" ]; then
  sudo install -m 755 "$query_bridge" "$target_query_bridge"
  sudo install -m 644 "$phone_data" "$target_phone_data"
  sudo install -m 644 "$phone_license" "$target_phone_license"
  mkdir -p "$HOME/Library/Rime"
  touch "$HOME/Library/Rime/input_translation.query_bridge.enabled"
else
  sudo rm -f "$target_query_bridge" "$target_phone_data" "$target_phone_license"
  rm -f "$HOME/Library/Rime/input_translation.query_bridge.enabled"
fi
if [ "$install_injector" = "1" ]; then
  sudo install -m 755 "$injector_loader" "$target_injector_loader"
  sudo install -m 755 "$injector_swift" "$target_injector_swift"
  mkdir -p "$HOME/Library/Rime"
  touch "$HOME/Library/Rime/input_translation.status_injector.enabled"
else
  sudo rm -f "$target_injector_loader" "$target_injector_swift"
  rm -f "$HOME/Library/Rime/input_translation.status_injector.enabled"
fi
if [ "$install_query_bridge" = "1" ]; then
  echo "In-process query bridge installed and enabled."
else
  echo "In-process query bridge not installed."
fi
"$script_dir/sign_squirrel.sh" "$squirrel_app"
mkdir -p "$(dirname "$lua_filter_target")"
install -m 644 "$lua_filter_source" "$lua_filter_target"
install -m 644 "$lua_processor_source" "$lua_processor_target"
install -m 644 "$lua_help_source" "$lua_help_target"
mkdir -p "$(dirname "$url_helper_target")"
install -m 755 "$url_helper" "$url_helper_target"

echo "Installed: $target"
echo "Updated: $lua_filter_target"
echo "Updated: $lua_processor_target"
echo "Updated: $lua_help_target"
echo "Installed: $url_helper_target"
if [ "$install_injector" = "1" ]; then
  echo "Experimental status injector installed and enabled."
else
  echo "Status injector not installed; normal public-safe mode is active."
fi
if [ "$restart_squirrel" = "1" ]; then
  sh "$script_dir/restart_squirrel.sh" "$squirrel_app"
else
  echo "Restart Squirrel manually, or rerun with RESTART_SQUIRREL=1."
fi
