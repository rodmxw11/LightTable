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

JDK 17 is for *building* (it matches the pinned `clojurescript 1.10.844`).
If you also want the Clojure plugin's REPL, add `openjdk-8-jdk` — the
bundled nREPL runner cannot run on anything newer. See
"Using the Clojure plugin / InstaRepl" below for why.

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

### You need a Java 8 JDK for this (only for this)

Read this first — nothing below works without it.

The bundled nREPL runner (`lein-light-standalone.jar`) embeds Leiningen
2.5.2, whose `dynapath` references `sun.misc.Launcher$ExtClassLoader`. That
class was **removed in Java 9**, so the runner dies at startup with
`ClassNotFoundException` on JDK 11, 17 and 21 alike (all three verified). No
JVM flag works around it — the class simply isn't there.

Everything else in Light Table is happy on a modern JDK; this applies only to
the Clojure client. Install a JDK 8 alongside whatever you already have:

```bash
sudo apt install openjdk-8-jdk
```

Then either launch Light Table with that `java` first on `PATH`:

```bash
PATH=/usr/lib/jvm/java-8-openjdk-amd64/bin:$PATH ./LightTable
```

or point just the Clojure client at it, in **Settings > User Behaviors**:

```clojure
[:clojure.lang :lt.plugins.clojure/java-exe "/usr/lib/jvm/java-8-openjdk-amd64/bin/java"]
```

The behavior route has one wrinkle: it takes effect only after behaviors are
re-applied, which happens whenever a `.behaviors` file is saved. On a cold
start the Clojure plugin builds its language object before the behavior can
run, so the first connection attempt still uses `java` from `PATH`. Saving
`user.behaviors` once (Ctrl+S in that tab) applies it for the rest of the
session. The `PATH` route has no such caveat, which is why it's listed first.

### Opening an InstaRepl

InstaRepl is a *separate plugin* (`ClojureInstarepl`), split out of the
Clojure plugin in its 0.3.0 release. `script/build.sh` installs it. It does
not appear on its own — open one explicitly with **Ctrl+Space** →
`Instarepl: Open a clojure instarepl`. Type an expression and it evaluates
as you type; the `live` toggle in the top right turns that off.

To turn an existing `.clj` editor into one instead, use
`Instarepl: Make current editor an instarepl`.

### Path A — just trying it out (no project)

The Clojure plugin ships its own self-contained runtime —
`deploy/plugins/Clojure/runner/target/lein-light-standalone.jar` — with
Clojure 1.5.1 and nREPL already bundled in. If the open `.clj` file has
**no `project.clj`** anywhere above it (including a brand-new, unsaved
buffer), the plugin automatically falls back to this bundled
"LightTable-REPL". No Leiningen, no separate Clojure install, nothing to
configure beyond the Java 8 requirement above.

The first connection is slow — the runner resolves its dependencies from
Maven Central and Clojars into `~/.m2` on first launch. Later ones are fast.

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

- **Check the Java version first.** By far the most likely cause is the
  runner getting a JDK 9+; the status bar shows "Failed to connect". Run the
  jar by hand to see the real error:
  ```bash
  cd deploy/plugins/Clojure/runner/resources
  java -jar ../target/lein-light-standalone.jar LightTable-REPL
  ```
  A working Java 8 prints `nREPL server started on port ...`. A too-new JDK
  prints `ExceptionInInitializerError` /
  `ClassNotFoundException: sun.misc.Launcher$ExtClassLoader`.
- The plugin resolves Java via (in order) the `java-exe` behavior above, then
  `JAVA_HOME`, then `java` on `PATH`.
- Open the Light Table console (**Ctrl+Space** → `Console: Toggle console`)
  and read the actual error rather than guessing — connection failures are
  reported there, not in a popup.

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
