#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir="$project_dir/build"
dependency_dir="$build_dir/deps/librime"
output_dir="$build_dir/out"
squirrel_app=${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}

if [ ! -d "$dependency_dir/.git" ]; then
  mkdir -p "$build_dir/deps"
  git clone --depth=1 --branch 1.17.0 \
    https://github.com/rime/librime.git "$dependency_dir"
fi

boost_prefix=$(brew --prefix boost)

cmake -S "$project_dir" -B "$output_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DRIME_SOURCE_DIR="$dependency_dir" \
  -DBOOST_INCLUDE_DIR="$boost_prefix/include" \
  -DSQUIRREL_APP="$squirrel_app"

cmake --build "$output_dir" --config Release

plugin="$output_dir/librime-translation-refresh.dylib"
file "$plugin"
otool -L "$plugin"
