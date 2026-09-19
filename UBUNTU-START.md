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
