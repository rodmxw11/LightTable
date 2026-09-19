#!/usr/bin/env bash
set -e

# Build LightTable app and CLI and place in builds/.
# Specify $VERSION to override default build version.
# Pass `--release` to build a release version.
# This script primarily installs dependencies and sets up
# the app before calling build-app.sh to build it.

# Optional: point at a specific JDK for this build via LT_JAVA_HOME,
# without changing the system JAVA_HOME. project.clj targets an old
# Clojure/ClojureScript toolchain that is safest on JDK 17.
if [ -n "$LT_JAVA_HOME" ]; then
  export JAVA_HOME="$LT_JAVA_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# Check if lein is installed
[ "`which lein`" ] || { echo >&2 "Please install leiningen before running this script."; exit 1; }
if [ "$(echo `lein version` | grep 'Leiningen \(1.\|2.0\)')" ]; then
  echo "lein version must be 2.1 or above. Do a lein upgrade first"; exit 1;
fi

# Check if npm is installed
[ "`which npm`" ] || { echo >&2 "Please install npm before running this script."; exit 1; }

# Ensure we start in project root
cd "$(dirname "${BASH_SOURCE[0]}")"; cd ..

# deploy/electron/package.json pins the Electron version actually downloaded
# and packaged; deploy/core/version.json's "electron" key is what
# lt.objs.deploy compares against process.versions.electron at runtime to
# decide whether to nag the user about a stale binary. Nothing else keeps
# these two files in sync.
PINNED_ELECTRON=$(node -pe "require('./deploy/electron/package.json').devDependencies.electron")
VERSION_JSON_ELECTRON=$(node -pe "require('./deploy/core/version.json').electron")
if [ "$PINNED_ELECTRON" != "$VERSION_JSON_ELECTRON" ]; then
  echo >&2 "WARNING: deploy/electron/package.json pins Electron $PINNED_ELECTRON but deploy/core/version.json says $VERSION_JSON_ELECTRON. Update both, or every launch will show a spurious binary-update nag."
fi

# Ensure we have current version of electron
pushd deploy/electron
  npm install
  # electron's postinstall binary download has been observed to silently
  # no-op in some environments without npm reporting an error; force it
  # if the dist binary didn't materialize.
  if [ ! -f node_modules/electron/dist/electron.exe ] && [ ! -f node_modules/electron/dist/electron ] && [ ! -f node_modules/electron/dist/Electron.app/Contents/MacOS/Electron ]; then
    echo "Electron binary missing after npm install, forcing install.js..."
    node node_modules/electron/install.js
  fi
popd

# Ensure we have current version of core
pushd deploy/core
  npm install
popd

# Build cljsDeps.js, consumed by the background worker thread
# (deploy/core/lighttable/background/threadworker.js). Must run after
# npm install, since npm install can wipe deploy/core/node_modules/.
rm -rf deploy/core/node_modules/clojurescript
lein cljsbuild once cljsdeps

# Build the core cljs

# Workaround for #1025 windows bug. project.clj is checked in, so restore
# it on exit rather than leaving the working tree dirty after every build.
case "$(uname -s)" in
  CYGWIN_NT*|MINGW*|MSYS*)
    trap 'git checkout -- project.clj' EXIT
    sed -i 's/:source-map/;;:source-map/' project.clj
    ;;
esac
rm -f deploy/core/lighttable/bootstrap.js
lein cljsbuild once app

# Fetch plugins
PLUGINS=("Clojure,0.3.3" "CSS,0.0.6" "HTML,0.1.0" "Javascript,0.2.0"
         "Paredit,0.0.4" "Python,0.0.7" "Rainbow,0.0.8")

# Plugins cache
mkdir -p deploy/plugins

pushd deploy/plugins
  for plugin in "${PLUGINS[@]}" ; do
      NAME="${plugin%%,*}"
      VERSION="${plugin##*,}"
      if [ -d $NAME ]; then
        echo "Updating plugin $NAME $VERSION..."
        cd $NAME
        git checkout --quiet master
        git pull --quiet
        git checkout --quiet $VERSION
        cd -
      else
        echo "Cloning plugin $NAME $VERSION..."
        git clone "https://github.com/LightTable/$NAME"
        cd $NAME
        git checkout --quiet $VERSION
        cd -
      fi
  done
popd

script/build-app.sh $@
