#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
project_root=$(CDPATH= cd -- "$project_dir/.." && pwd)
version=${1:-}
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
output_dir=${PREVIEW_RELEASE_OUTPUT_DIR:-"$project_dir/build/release"}

if [ -z "$version" ]; then
  echo "Usage: $0 <release-version>" >&2
  exit 2
fi
case "$version" in
  *[!A-Za-z0-9._-]*|.*|*-|"")
    echo "Invalid release version: $version" >&2
    exit 2
    ;;
esac

if [ "$(sw_vers -productVersion)" != "26.6.2" ]; then
  echo "Preview packages must be built on the recorded test host macOS 26.6.2." >&2
  exit 1
fi
if [ ! -x "$squirrel_app/Contents/MacOS/Squirrel" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi
squirrel_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$squirrel_app/Contents/Info.plist")
if [ "$squirrel_version" != "1.1.2" ]; then
  echo "Preview package requires the verified Squirrel 1.1.2 build; found $squirrel_version." >&2
  exit 1
fi

# Do not let ignored local/private sources influence the public release build.
BUILD_PRIVATE_TRANSLATION_INTEGRATION=OFF \
  SQUIRREL_APP="$squirrel_app" "$script_dir/build.sh"
ctest --test-dir "$project_dir/build/out" --output-on-failure

for artifact in \
  "$project_dir/build/out/libsquirrel-query-bridge.dylib" \
  "$project_dir/build/out/squirrel-open-url"; do
  if [ ! -f "$artifact" ]; then
    echo "Missing release artifact: $artifact" >&2
    exit 1
  fi
  lipo -verify_arch arm64 x86_64 "$artifact"
done

mkdir -p "$output_dir"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/squirreltranslate-preview.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM

git -C "$project_root" archive --format=tar HEAD | tar -xf - -C "$stage_dir"
if [ -e "$stage_dir/native/src/translation_refresh.cc" ]; then
  echo "Refusing to package private translation integration source." >&2
  exit 1
fi
mkdir -p "$stage_dir/native/build/out"
cp "$project_dir/build/out/libsquirrel-query-bridge.dylib" \
  "$project_dir/build/out/squirrel-open-url" \
  "$stage_dir/native/build/out/"

archive="$output_dir/SquirrelTranslate-${version}-macos-universal-preview.zip"
if [ -e "$archive" ]; then
  echo "Release archive already exists: $archive" >&2
  exit 1
fi
(cd "$stage_dir" && zip -qry "$archive" .)

echo "Created unsigned, non-notarized preview package: $archive"
echo "SHA-256: $(shasum -a 256 "$archive" | awk '{print $1}')"
echo "This package still requires a valid local stable signing identity at installation."
