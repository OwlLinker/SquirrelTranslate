#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir="$project_dir/build"
dependency_dir="$build_dir/deps/librime"
output_dir="$build_dir/out"
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}
private_translation=${BUILD_PRIVATE_TRANSLATION_INTEGRATION:-auto}
if [ "$private_translation" = "auto" ]; then
  if [ -f "$project_dir/src/translation_refresh.cc" ]; then
    private_translation=ON
  else
    private_translation=OFF
  fi
fi

if [ "${BUILD_PUBLIC_PROVIDERS_ONLY:-0}" = "1" ]; then
  cmake -S "$project_dir" -B "$output_dir" \
    -DBUILD_PUBLIC_PROVIDERS_ONLY=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
  cmake --build "$output_dir" --config Release
  artifact="$output_dir/librime-public-translation-providers.dylib"
  file "$artifact"
  otool -L "$artifact"
  exit 0
fi

if [ ! -d "$dependency_dir/.git" ]; then
  mkdir -p "$build_dir/deps"
  git clone --depth=1 --branch 1.17.0 \
    https://github.com/rime/librime.git "$dependency_dir"
fi

boost_prefix=$(brew --prefix boost)

cmake -S "$project_dir" -B "$output_dir" \
  -DBUILD_PUBLIC_PROVIDERS_ONLY=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DRIME_SOURCE_DIR="$dependency_dir" \
  -DBOOST_INCLUDE_DIR="$boost_prefix/include" \
  -DSQUIRREL_APP="$squirrel_app" \
  -DBUILD_PRIVATE_TRANSLATION_INTEGRATION="$private_translation"

cmake --build "$output_dir" --config Release

if [ "$private_translation" = "ON" ]; then
  artifact="$output_dir/librime-translation-refresh.dylib"
else
  artifact="$output_dir/librime-public-translation-providers.dylib"
  echo "Private translator integration is not included; built the public provider library only."
fi
file "$artifact"
otool -L "$artifact"
