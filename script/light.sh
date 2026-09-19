#!/usr/bin/env bash
set -e

# Opens current LightTable without needing to build it.
# Assumes script/build.sh has been run at least once

# Ensure we start in project root
cd "$(dirname "${BASH_SOURCE[0]}")"; cd ..
DIR=$(pwd)

ELECTRON_DIR="${DIR}/deploy/electron/node_modules/electron/dist"

case "$(uname -s)" in
  Darwin)
    CLI="${ELECTRON_DIR}/Electron.app/Contents/MacOS/Electron"
    ;;
  Linux*)
    CLI="${ELECTRON_DIR}/electron"
    ;;
  CYGWIN_NT*|MINGW*|MSYS*)
    CLI="${ELECTRON_DIR}/electron.exe"
    ;;
  *)
    echo "Cannot detect a supported OS."
    exit 1
    ;;
esac

LT_DEV_CLI=true "$CLI" deploy/core "$@"
