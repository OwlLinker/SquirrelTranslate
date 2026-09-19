#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
rime_dir=${RIME_DIR:-"$HOME/Library/Rime"}
lua_dir="$rime_dir/lua"

mkdir -p "$lua_dir"
install -m 644 "$project_dir/lua/input_translation_state.lua" "$lua_dir/"
install -m 644 "$project_dir/lua/input_translation_processor.lua" "$lua_dir/"
install -m 644 "$project_dir/lua/input_translation_filter.lua" "$lua_dir/"

echo "Installed Rime Lua files to: $lua_dir"
