#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
frontend_dir="$project_dir/SquirrelFrontend"

if [ ! -d "$frontend_dir" ]; then
  echo "SquirrelFrontend source directory not found: $frontend_dir" >&2
  exit 1
fi

clone_dependency() {
  name=$1
  url=$2
  target="$frontend_dir/$name"

  if [ -d "$target/.git" ] || [ -f "$target/.git" ]; then
    echo "Already initialized: $name"
    return
  fi
  if [ -d "$target" ] && [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    rmdir "$target"
  fi
  if [ -e "$target" ]; then
    echo "Dependency path exists but is not a Git checkout: $target" >&2
    exit 1
  fi

  git clone --depth=1 "$url" "$target"
}

clone_dependency librime https://github.com/rime/librime.git
clone_dependency plum https://github.com/rime/plum.git
clone_dependency Sparkle https://github.com/sparkle-project/Sparkle.git

echo "Squirrel frontend dependencies are ready."
