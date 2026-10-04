#!/bin/sh
set -eu

squirrel_app=${1:-${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}}
squirrel_executable="$squirrel_app/Contents/MacOS/Squirrel"

if [ ! -x "$squirrel_executable" ]; then
  echo "Squirrel executable not found: $squirrel_executable" >&2
  exit 1
fi

old_pids=$(pgrep -x Squirrel || true)
if [ -n "$old_pids" ]; then
  "$squirrel_executable" --quit || true
  for attempt in $(seq 1 40); do
    still_running=0
    for pid in $old_pids; do
      if kill -0 "$pid" 2>/dev/null; then still_running=1; fi
    done
    [ "$still_running" -eq 0 ] && break
    sleep 0.25
  done

  still_running=0
  for pid in $old_pids; do
    if kill -0 "$pid" 2>/dev/null; then still_running=1; fi
  done
  if [ "$still_running" -eq 1 ]; then
    for pid in $old_pids; do kill -TERM "$pid" 2>/dev/null || true; done
    for attempt in $(seq 1 40); do
      still_running=0
      for pid in $old_pids; do
        if kill -0 "$pid" 2>/dev/null; then still_running=1; fi
      done
      [ "$still_running" -eq 0 ] && break
      sleep 0.25
    done
  fi

  for pid in $old_pids; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "Squirrel process $pid did not exit; close it manually, then retry." >&2
      exit 1
    fi
  done
fi

open "$squirrel_app"
for attempt in $(seq 1 40); do
  if pgrep -x Squirrel >/dev/null 2>&1; then
    echo "Squirrel restarted."
    exit 0
  fi
  sleep 0.25
done

echo "Squirrel did not restart; open it manually from Finder." >&2
exit 1
