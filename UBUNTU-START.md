# Cloning and running on Ubuntu

This is the setup for building and running LightTable on Ubuntu after the
Electron 13 → 44.4.3 upgrade (see `ELECTRON-UPDATE-PLAN.md`). Ubuntu 24.04+
is the recommended target — its AppArmor unprivileged-userns restriction is
exactly the class of thing that made Electron 13 stop working, so it's the
distro that actually proves the upgrade fixed the problem.

## 1. Prerequisites

```bash
sudo apt update
sudo apt install -y git curl openjdk-17-jdk build-essential
```

Leiningen (not reliably available via apt — install directly):

```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein -o ~/bin/lein
chmod +x ~/bin/lein
export PATH="$HOME/bin:$PATH"   # add to ~/.bashrc to persist
lein version   # first run downloads lein's own jar
```

Node.js (use nvm rather than apt's outdated package):

```bash
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source ~/.bashrc
nvm install --lts
```

## 2. Clone

```bash
git clone https://github.com/rodmxw11/LightTable.git
cd LightTable
git checkout claude-lighttable
```

## 3. Build

```bash
script/build.sh
```

This downloads Electron 44.4.3, installs npm dependencies, compiles the
ClojureScript, clones the bundled language plugins, and packages everything
into `builds/lighttable-0.9.0-linux/`. Takes a few minutes the first time.

## 4. Run

```bash
cd builds/lighttable-0.9.0-linux
./light
```

Use `./light`, not `./LightTable` directly — the wrapper script detects
whether `chrome-sandbox` is properly setuid-root and falls back to
`--no-sandbox` automatically if not (which it won't be, straight out of a
fresh build/clone).

To get the real sandbox instead of the fallback:

```bash
sudo chown root:root builds/lighttable-0.9.0-linux/chrome-sandbox
sudo chmod 4755 builds/lighttable-0.9.0-linux/chrome-sandbox
```

## Using the Clojure plugin / InstaRepl

There are two distinct paths, depending on what you're editing. Which one
applies is decided automatically by whether a `project.clj` exists in a
parent directory of the file you have open — you don't choose it explicitly.

InstaRepl itself only appears once a client actually connects; opening a
`.clj` file alone doesn't trigger it. Eval something (place the cursor at
the end of an expression and hit **Ctrl+Enter**) to trigger the connection.

### Path A — just trying it out (no setup beyond a JDK)

The Clojure plugin ships its own self-contained runtime —
`deploy/plugins/Clojure/runner/target/lein-light-standalone.jar` — with
Clojure 1.5.1 and nREPL already bundled in. If the open `.clj` file has
**no `project.clj`** anywhere above it (including a brand-new, unsaved
buffer), the plugin automatically falls back to this bundled
"LightTable-REPL". No Leiningen, no separate Clojure install, nothing to
configure — the only external dependency is a JDK on `PATH`, which the
Prerequisites step above already installs.

1. Open or create a `.clj` file.
2. Type an expression, e.g. `(+ 1 2)`.
3. Cursor at the end of it, **Ctrl+Enter**.

### Path B — a real project with your own dependencies

If you want your own libraries rather than the bundled Clojure 1.5.1
sandbox, put a real `project.clj` at the root of a project and open a
`.clj` file from inside it — the plugin walks up from the file, finds that
`project.clj`, and spawns the JVM in that project's directory (with its
actual declared `:dependencies`) instead of the sandboxed fallback.

```bash
lein version      # you already have this from the Prerequisites step
lein new app my-project
cd my-project
```

Then open a file under `my-project/src/...` in LightTable.

### If it still doesn't connect

- The plugin auto-detects Java via (in order) a manual override, then
  `JAVA_HOME`, then `which java` on `PATH`. Confirm `which java` on the
  Ubuntu machine actually resolves to a JDK 11+ binary.
- A manual override is available via **Settings > User Behaviors** if
  auto-detection ever points at the wrong Java ("Clojure: set the path to
  the Java executable for clients").
- If you still see a "couldn't find java" popup after pulling the latest
  `claude-lighttable` and rebuilding (`script/build-app.sh` is enough —
  this particular fix doesn't touch ClojureScript), that's worth reporting
  back with the exact error text.

## What to actually verify

Per `ELECTRON-UPDATE-PLAN.md`'s verification section, these are the things
that could not be tested from Windows and matter most:

1. **It launches at all** — this is the entire point; Electron 13 doesn't
   run on modern Ubuntu, 44 should.
2. Also test from a **`--release` tarball** (`script/build.sh --release`,
   extract it fresh, run `./light`) — extraction is where the setuid bit
   is actually lost, unlike testing straight out of `builds/`.
3. `<webview>` (the browser tab feature) renders correctly — GPU/compositing
   differs from Windows.
4. Keyboard input on a non-US layout, if available — the bundled Mousetrap
   fork predates some Chromium keyboard-event changes.

If `./light` fails to launch, or throws a specific sandbox-related error,
capture the exact output — it's diagnosable even without a Linux environment
to reproduce it in.
