#!/bin/sh
set -eu

mode=${1:-}
if [ "$mode" = "--check" ]; then
  squirrel_app=${2:-${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}}
else
  squirrel_app=${1:-${SQUIRREL_APP:-/Library/Input Methods/Squirrel.app}}
fi
identity=${SQUIRREL_SIGN_IDENTITY:-${ST_INPUT_BAR_SIGN_IDENTITY:-}}

if [ -z "$identity" ]; then
  echo "A stable code-signing identity is required; refusing ad-hoc re-signing." >&2
  echo "Create/use a Code Signing identity in Keychain Access, then set SQUIRREL_SIGN_IDENTITY." >&2
  exit 2
fi
if [ ! -d "$squirrel_app" ]; then
  echo "Squirrel.app not found: $squirrel_app" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning |
    grep -Fq "\"$identity\""; then
  echo "The selected identity is not a valid local code-signing identity." >&2
  echo "Check its exact name with: security find-identity -v -p codesigning" >&2
  exit 2
fi
if [ "$mode" = "--check" ]; then
  exit 0
fi

# Do not preserve the old ad-hoc designated requirement: it can contain
# architecture cdhashes and would keep TCC authorization tied to each build.
sudo codesign --force --deep --sign "$identity" \
  --preserve-metadata=entitlements,flags,runtime "$squirrel_app"
sudo codesign --verify --deep --strict "$squirrel_app"
requirement=$(codesign -dr - "$squirrel_app" 2>&1 || true)
case "$requirement" in
  *cdhash*)
    echo "The resulting designated requirement still pins a cdhash; refusing this signature." >&2
    exit 1
    ;;
esac
echo "Squirrel signed with a stable identity."
