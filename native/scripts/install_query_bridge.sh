#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
project_root=$(CDPATH= cd -- "$project_dir/.." && pwd)
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
bridge="$project_dir/build/out/libsquirrel-query-bridge.dylib"
url_helper="$project_dir/build/out/squirrel-open-url"
url_helper_target="$HOME/Library/Rime/bin/squirrel-open-url"
plugin_dir="$squirrel_app/Contents/Frameworks/rime-plugins"
target="$plugin_dir/libsquirrel-query-bridge.dylib"
phone_data="$project_dir/resources/phone-region-phone.dat"
phone_license="$project_dir/resources/phone-region-LICENSE.txt"
provider_config="$project_root/rime/translation.providers.public.yaml.example"
provider_config_target="$HOME/Library/Rime/translation.providers.yaml"
marker="$HOME/Library/Rime/input_translation.query_bridge.enabled"

if [ ! -x "$squirrel_app/Contents/MacOS/Squirrel" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi
if [ ! -f "$bridge" ]; then
  echo "Build the extension first: $script_dir/build.sh" >&2
  exit 1
fi
if [ ! -x "$url_helper" ]; then
  echo "Build the URL helper first: $script_dir/build.sh" >&2
  exit 1
fi
if [ ! -f "$phone_data" ] || [ ! -f "$phone_license" ]; then
  echo "Missing phone region database: $phone_data" >&2
  exit 1
fi
if [ ! -f "$provider_config" ]; then
  echo "Missing public provider configuration example: $provider_config" >&2
  exit 1
fi
"$script_dir/sign_squirrel.sh" --check "$squirrel_app"

sudo mkdir -p "$plugin_dir"
sudo install -m 755 "$bridge" "$target"
sudo install -m 644 "$phone_data" "$plugin_dir/phone-region-phone.dat"
sudo install -m 644 "$phone_license" "$plugin_dir/phone-region-LICENSE.txt"
mkdir -p "$(dirname "$marker")"
touch "$marker"
mkdir -p "$(dirname "$provider_config_target")"
if [ ! -e "$provider_config_target" ]; then
  install -m 600 "$provider_config" "$provider_config_target"
fi
mkdir -p "$(dirname "$url_helper_target")"
install -m 755 "$url_helper" "$url_helper_target"
"$script_dir/sign_squirrel.sh" "$squirrel_app"

"$squirrel_app/Contents/MacOS/Squirrel" --quit || true
for attempt in $(seq 1 40); do
  if ! pgrep -x Squirrel >/dev/null 2>&1; then break; fi
  sleep 0.25
done
open "$squirrel_app"
echo "Installed and enabled the in-process query bridge."
echo "Installed: $url_helper_target"
echo "Stop the standalone input bar before testing: $project_root/native/scripts/input_bar.sh stop"
