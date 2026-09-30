#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
native_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
bundle_name="SquirrelTranslate Input Bar.app"
bundle_id="org.owllinker.SquirrelTranslate.InputBar"
build_app="$native_dir/build/input-bar/$bundle_name"
installed_app="$HOME/Applications/$bundle_name"
agent="$HOME/Library/LaunchAgents/$bundle_id.plist"
domain="gui/$(id -u)"

build() {
  if [ -z "${ST_INPUT_BAR_SIGN_IDENTITY:-}" ] ||
      ! security find-identity -v -p codesigning |
          grep -Fq "\"$ST_INPUT_BAR_SIGN_IDENTITY\""; then
    echo "Set ST_INPUT_BAR_SIGN_IDENTITY to a valid stable Code Signing identity." >&2
    echo "Ad-hoc signing is disabled because it invalidates Accessibility authorization after rebuilds." >&2
    exit 2
  fi
  mkdir -p "$build_app/Contents/MacOS"
  install -m 644 "$native_dir/resources/input-bar-Info.plist" "$build_app/Contents/Info.plist"
  xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -framework AppKit -framework ApplicationServices -framework Carbon \
    "$native_dir/src/squirrel_input_bar.m" \
    -o "$build_app/Contents/MacOS/squirrel-input-bar"
  codesign --force --sign "$ST_INPUT_BAR_SIGN_IDENTITY" \
    --identifier "$bundle_id" "$build_app"
  printf 'Built: %s\n' "$build_app"
}

install_helper() {
  launchctl bootout "$domain/$bundle_id" 2>/dev/null || true
  mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
  ditto "$build_app" "$installed_app"
  install -m 644 "$native_dir/resources/input-bar-launchagent.plist" "$agent"
  # Replace the whole array: replacing index 0 can leave the placeholder as
  # an extra argument on macOS plutil. Insert into an explicitly empty array.
  plutil -replace ProgramArguments -xml '<array/>' "$agent"
  plutil -insert ProgramArguments.0 -string \
    "$installed_app/Contents/MacOS/squirrel-input-bar" "$agent"
  plutil -lint "$agent"
  launchctl bootstrap "$domain" "$agent"
  printf 'Installed: %s\nEnable this app in System Settings > Privacy & Security > Accessibility.\n' "$installed_app"
}

case "${1:-install}" in
  build)
    build
    ;;
  install)
    build
    install_helper
    ;;
  update)
    build
    install_helper
    ;;
  start)
    if ! launchctl print "$domain/$bundle_id" >/dev/null 2>&1; then
      launchctl bootstrap "$domain" "$agent"
    else
      launchctl kickstart -k "$domain/$bundle_id"
    fi
    ;;
  stop)
    launchctl bootout "$domain/$bundle_id" 2>/dev/null || true
    ;;
  check)
    "$installed_app/Contents/MacOS/squirrel-input-bar" --check
    ;;
  status)
    launchctl print "$domain/$bundle_id"
    ;;
  uninstall)
    launchctl bootout "$domain/$bundle_id" 2>/dev/null || true
    # Preserve the app as a recoverable copy; remove only this exact agent.
    if [ -f "$agent" ]; then rm -f "$agent"; fi
    if [ -d "$installed_app" ]; then
      mkdir -p "$HOME/.Trash"
      trash_target="$HOME/.Trash/SquirrelTranslate Input Bar-$(date +%Y%m%d-%H%M%S).app"
      mv "$installed_app" "$trash_target"
      printf 'Moved to Trash: %s\n' "$trash_target"
    fi
    ;;
  *)
    echo "Usage: $0 {build|install|update|start|stop|check|status|uninstall}" >&2
    exit 2
    ;;
esac
