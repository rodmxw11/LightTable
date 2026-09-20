# Upgrade LightTable from Electron 13.1.2 to latest

## Context

LightTable does not run on modern Linux distributions. It pins **Electron 13.1.2** (May 2021, Chromium 91 / Node 14) in `deploy/electron/package.json:5` and `deploy/core/version.json`. That release is EOL: `doc/developer-install.md:55` documents a hard dependency on `libgconf-2.so.4` (dropped from current distros), and Electron 13 predates the sandbox changes required by modern kernels' unprivileged-user-namespace restrictions (Ubuntu 24.04+ AppArmor, current Fedora).

The goal is to get LightTable running on current Linux while keeping Windows working. macOS is explicitly out of scope.

**Decisions already made:**
1. **Compat mode, not a contextBridge rewrite.** The renderer is a full Node context (`js/require`, `js/__dirname`, `js/global`, `process.*` throughout `src/`). We explicitly opt into `nodeIntegration:true` / `contextIsolation:false` / `sandbox:false` / `webviewTag:true` and replace the removed `remote` module with `@electron/remote`. A contextBridge port would break every third-party plugin, since plugins call `js/require` directly. Hardening is recorded as backlog, not done here.
2. **Single jump to latest stable.** `remote` was removed in Electron 14, so no intermediate version avoids the main breaking change, and only recent Chromium fixes the Linux problem.
3. **Linux + Windows.** macOS codesigning/notarization is untouched and left unverified.
4. **Fix two pre-existing blockers** first, so post-upgrade regressions are attributable.

**Good news on scope:** there is **no ABI work**. No `binding.gyp`, no `.node` files anywhere. The only native deps (`bufferutil`, `utf-8-validate`, via `socket.io`→`engine.io`→`ws`) are optional with pure-JS fallbacks. No `electron-rebuild`. All the pain is API pain.

---

## Phase 0 — Toolchain (no repo changes)

`lein` is not installed on this machine, so the ClojureScript build cannot currently run.

- Install **Temurin JDK 17** (safest for `clojure 1.10.3` / `clojurescript 1.10.844`).
- Install **Leiningen** (`scoop install leiningen` or `choco install lein`); verify `lein version` ≥ 2.1.

**Blocker you will hit immediately:** `script/build-app.sh:28` detects Windows via `uname -s` starting with `CYGWIN_NT`. Under Git Bash `uname -s` returns `MINGW64_NT-10.0`, so the script dies at `:34` with "Cannot detect a supported OS." Same at `script/build.sh:34` and `script/light.sh:16`. Fixed in Phase 1.

---

## Phase 1 — Make the build runnable + fix stale paths

Build-script hygiene only, no behavior change.

- **`script/build-app.sh:28`** — broaden Windows detection to `CYGWIN_NT*|MINGW*|MSYS*`. Keep `RESOURCES="resources"`, `PLATFORM_DIR="deploy/platform/win"`.
- **`script/build-app.sh:126`** — replace the hardcoded `/cygdrive/c/Program Files/7-Zip/7z.exe` with a `command -v 7z` lookup falling back to PowerShell `Compress-Archive`. Only affects `--release`.
- **`script/build.sh:34-37`** — same detection fix. **Also stop it leaving `project.clj` dirty**: it `sed`s out `:source-map` in a checked-in file and never restores it. Add a `trap` to restore on exit, or move source-map control into a lein profile. This looks cosmetic but will silently poison a mid-upgrade build.
- **`script/light.sh:12,14,16`** — points at `deploy/electron/electron/...`; the real install is `deploy/electron/node_modules/electron/dist/...` (per `build-app.sh:14`). Fix all three and add the MINGW branch. This is the fastest dev loop available (`LT_DEV_CLI=true "$CLI" deploy/core`, consumed at `cli.cljs:47`) and is worth having before Phase 5.

**Verify:** `script/build.sh` completes and `builds/lighttable-0.9.0-windows/LightTable.exe` launches on Electron 13. This is the baseline.

---

## Phase 2 — Fix the two pre-existing blockers

### 2a. Restore the `codemirror_addons` forks — do NOT repoint to upstream

Three call sites load a directory that no longer exists (deleted in `5442e92`): `editor.cljs:1004`, `find.cljs:159`, `auto_complete.cljs:357`, all via `(load/js "core/node_modules/codemirror_addons/<f>" :sync)`.

The in-repo TODOs suggest using stock CodeMirror addons, but **two of the three are forks with divergent APIs** (verified against `5442e92^`):

- **`search.js`** defines `CodeMirror.commands.find = function(cm, query, rev)` — 3-arg and dialog-free — plus `getSearchState` and a 4-arg `replace`. `find.cljs:139` calls exactly that 3-arg form. Upstream `addon/search/search.js` defines `find(cm)` and opens a `dialog.js` prompt. **Repointing breaks Find/Replace.** Restore the fork.
- **`show-hint.js`** is not the CodeMirror addon at all — 43 lines defining only `CodeMirror.positionHint` and `CodeMirror.ensureHintVisible`. `auto_complete.cljs:278` calls `positionHint`; upstream `addon/hint/show-hint.js` provides neither. **Restore verbatim.**
- **`overlay.js`** *is* a verbatim copy of CodeMirror 4.1.1's `addon/mode/overlay.js`, and CM5's version is API-compatible. This is the only one where the `;; TODO: use addon/mode/overlay.js` at `editor.cljs:1003` is actionable.

**Action:**
1. Recover `search.js` and `show-hint.js` from `git show 5442e92^:deploy/core/node_modules/codemirror_addons/<f>` into a **committed** directory: `deploy/core/lighttable/codemirror/`. Do **not** restore them under `deploy/core/node_modules/` — `.gitignore:1` ignores that whole tree and `build.sh:28-30` now repopulates it from `npm install`, so anything there vanishes. `deploy/core/lighttable/` is already the committed home for LT's vendored JS.
2. Repoint `find.cljs:159` → `core/lighttable/codemirror/search.js` and `auto_complete.cljs:357` → `core/lighttable/codemirror/show-hint.js`.
3. Repoint `editor.cljs:1004` → `core/node_modules/codemirror/addon/mode/overlay.js`; drop the TODO at `:1003`.
4. Add a short README in the new directory noting these are LT forks with divergent APIs, so they don't get "cleaned up" again.

**Verify:** Ctrl-F find / next / prev / replace / replace-all; autocomplete popup appears and positions correctly near the window edge.

### 2b. Build `cljsDeps.js`

`script/build.sh:41-44` has `lein cljsbuild once cljsdeps` commented out, but `deploy/core/lighttable/background/threadworker.js:29` unconditionally reads `core/node_modules/clojurescript/cljsDeps.js`. Every `background` macro call site is dead: `search.cljs:23`, `sidebar/navigate.cljs:23`, `langs/behaviors.cljs:13`, `auto_complete.cljs:93`.

Uncomment it and **order it after both `npm install` calls** — `project.clj:21-26` outputs into `deploy/core/node_modules/clojurescript/`, which `npm install` can wipe. Replace the interactive `rm -i -rf` at `:42` (it would hang CI) with a plain `rm -rf`:

```
npm install (deploy/electron) → npm install (deploy/core)
  → rm -rf deploy/core/node_modules/clojurescript
  → lein cljsbuild once cljsdeps
  → lein cljsbuild once app
```

**Verify:** `cljsDeps.js` exists under `builds/.../resources/app/core/node_modules/clojurescript/`; workspace search and the fuzzy-navigate sidebar work (both use `background` workers). Watch the LT console for `thread` stderr.

---

## Phase 2c — Discovered during Phase 2 verification: app was already broken on Electron 13

CDP-driven verification of Phase 2a/2b (see "Working in sessions" below) surfaced two independent, pre-existing defects that had nothing to do with codemirror/cljsdeps, but blocked verifying them. Both are fixed and confirmed via a real running instance:

1. **`deploy/core/package.json`'s `webPreferences` never set `nodeIntegration`/`contextIsolation`/`enableRemoteModule`.** On Electron 13's actual defaults (`nodeIntegration:false`, `contextIsolation:true`, `enableRemoteModule:false`), the renderer's `js/global` usage in `src/lt/util/cljs.cljs:24,36,44` threw `ReferenceError: global is not defined` at namespace-load time, before almost anything else in the bundle ran. Fixed by adding all three to `deploy/core/package.json`'s `webPreferences` (the `enableRemoteModule` flag is Electron-<14-only; it goes away in Phase 4/5 when `remote` is replaced by `@electron/remote`).
2. **ClojureScript's own compiled bootstrap clobbers Electron's real `process` object.** `process.env.cljs` in the ClojureScript 1.10.844 standard library (part of `cljs.core`'s environment-target detection, pulled in unconditionally, not tied to any app-level require) compiles to `var process = {env:{}};` near the top of `bootstrap.js`. Since it's a top-level `var`, it overwrites `window.process` — including the fully-populated object Electron had just injected — for the rest of the script's lifetime. Fixed by:
   - `LightTable.html` stashing the real object as `window.__electronProcess` in an inline script, before `bootstrap.js` loads.
   - A new leaf namespace `src/lt/util/process.cljs` exposing `process`, `env`, `platform`, `argv`, `exec-path`, `versions`, `version`, `cwd`, `next-tick`.
   - Updating every other namespace that read `js/process` directly to go through it instead: `platform.cljs`, `ipc.cljs`, `cli.cljs`, `deploy.cljs`, `console.cljs`, `files.cljs`, `proc.cljs`, `settings.cljs`, `thread.cljs`.

This is unrelated to Electron version and would affect any build with this ClojureScript toolchain — it just happened to be masked until fix #1 above let execution get far enough to hit it.

**Also found, not fixed (confirmed harmless):** the restored `search.js` fork's `CodeMirror.commands.replaceAll` wrapper has a parameter-shadowing bug (`function(cm, query, replace) { replace(cm, query, replace, true); }` — the `replace` parameter shadows the outer `replace` function). Verified this is dead code: `find.cljs:124` always calls `CodeMirror.commands.replace(cm, text, rev, all?)` directly, never `replaceAll`. Left as-is since fixing it would deviate from the verbatim-restored historic file for no functional benefit; noted here in case it's ever called directly.

**Verification performed:** live CDP (Chrome DevTools Protocol) session against a running packaged build, connecting to the app's own `--remote-debugging-port 8315` (already exposed by `main.js`). Confirmed via `Runtime.evaluate`: no uncaught exceptions on load, UI renders (`#wrapper` opacity 1, full DOM built), `lt.objs.command` and other namespaces load. Functionally exercised the actual `find.cljs` code path — `CodeMirror.commands.find` then `CodeMirror.commands.replace(cm, text, rev, true)` correctly replaced all 3 occurrences of a test string; `all?=false` correctly replaced only the first. Autocomplete's restored functions (`positionHint`, `ensureHintVisible`) confirmed present with correct signatures and execute without error when `:hint` is raised on a real editor object; full UI-trigger verification (the hint corpus builds incrementally from real keystrokes via a debounced `:change` behavior, not from bulk content changes) needs manual testing.

---

## Phase 3 — Electron smoke test in isolation (throwaway, no commit)

**Target: pin `electron` to `44.4.3` exactly** (Electron supports the latest three majors — 42/43/44). Anything ≥40 fixes the Linux problem.

**Unverified assumption that must be proven here:** `@electron/remote` 2.1.3 (published 2025-07-07) declares `peerDependencies.electron: ">= 13.0.0"` but its devDependencies pin Electron 28 — it has **not** been CI-tested against 40+.

In a scratch directory, `npm i electron@44.4.3 @electron/remote@2.1.3` and write a ~30-line main + renderer that exercises the riskiest surfaces: `initialize()` + `enable(win.webContents)`, then from the renderer `getCurrentWindow().getSize()`, construct a `Menu`/`MenuItem` **with a click callback** and `.popup()` (function proxying back into main — this is what `menu.cljs:12-14,46` does), and `dialog.showOpenDialogSync`.

- Passes → proceed with 44.4.3.
- Fails → retry on 42.11.6.
- Fails everywhere → the compat-mode strategy needs rethinking before any CLJS work.

**Result: PASS.** All five checks succeeded on Electron 44.4.3 with `@electron/remote@2.1.3`: module loads, `getCurrentWindow().getSize()` returns correctly, `dialog.showOpenDialogSync` exists, `Menu`/`MenuItem` construct and a click callback round-trips main→renderer→main (confirmed asynchronously — the synchronous return value inside the click handler reads stale, but the main process's own delayed check confirmed the flag was set), and `Menu.setApplicationMenu` succeeds. No fallback to 42.11.6 needed.

---

## Phase 4 — Main process + packaging

App is not expected to fully work at the end of this phase; Phase 5 fixes the renderer.

**Result: done.** Applied everything below plus one addition found during a full `script/build.sh` run: the `electron` npm package's postinstall binary download was observed to silently no-op (no error, no binary) in both the Phase 3 scratch test and the real build — `script/build.sh` now checks for the dist binary after `npm install` and forces `node node_modules/electron/install.js` if it's missing.

**`deploy/electron/package.json:5`** → `"electron": "44.4.3"`. Delete and regenerate `deploy/electron/package-lock.json`.

**`deploy/core/package.json`**
- Add `"@electron/remote": "2.1.3"` to `dependencies`. It must live here, not in `deploy/electron` — both the renderer's `js/require` and `main.js` resolve against this tree (`resources/app/core/node_modules` when packaged).
- Replace the `webPreferences` block at `:11-16` (currently `webgl`/`webaudio`/`plugins`, all three long-removed no-ops) with the explicit compat set:
  ```json
  "webPreferences": {
    "nodeIntegration": true,
    "contextIsolation": false,
    "sandbox": false,
    "webviewTag": true,
    "spellcheck": false,
    "backgroundThrottling": false
  }
  ```
  All four leading keys are now **required** — Electron 44 defaults every one of them the other way, and each is individually fatal. `enableRemoteModule` no longer exists; `@electron/remote` gates per-`webContents`.

**`deploy/core/version.json`** → `{"version":"0.9.0","electron":"44.4.3"}`. Must stay in lockstep with `deploy/electron/package.json` or `deploy.cljs:190-192` pops a "binary update!" nag on every launch (`doc/for-committers.md:81-82` documents this invariant).

**`deploy/core/main.js`**
- `:4-8` — add `require('@electron/remote/main').initialize();` after the destructure, before any window is created.
- `:24-25` — after `new BrowserWindow(...)`, add `require('@electron/remote/main').enable(window.webContents);`. Per-window, mandatory.
- `:22-24` — `browserWindowOptions` is read by reference from the cached `require`d package.json and mutated at `:23`, so the **second** window double-prefixes the icon path. Pre-existing; clone the object or guard with `path.isAbsolute`.
- `:87` — latent bug: `windows[windowId].toggleDevTools()` → `windows[windowId].webContents.toggleDevTools()`. Never a `BrowserWindow` method.
- `:112` — keep `remote-debugging-port 8315`, **add `app.commandLine.appendSwitch('remote-allow-origins', 'http://localhost:8315')`**. Chromium 111+ rejects CDP WebSocket upgrades whose Origin isn't allow-listed.
- `:113` — drop `appendSwitch('js-flags','--harmony')`; meaningless on modern V8.
- `:66-68` — `windows[window.id] = null` leaves null holes and `:80` indexes `windows[id]` unguarded. Use `delete windows[window.id]`.
- `:141-159` `IPC_DEBUG` monkey-patches `webContents.send` by assignment; fragile on modern Electron but gated behind an env var. Leave or delete — don't let it block.
- No `new-window` handler exists anywhere, so there is nothing to port to `setWindowOpenHandler`.

**`script/build-app.sh` — Linux `chrome-sandbox`.** This is the most likely reason a correctly-built app still refuses to launch. `cp -R` at `:63` does not preserve the setuid bit, and tarballs don't carry root-owned setuid either. In the linux branch at `:94-98`:
- `chmod 4755 $RELEASE_DIR/chrome-sandbox || true` (only effective when building as root).
- **Rewrite `deploy/platform/linux/light`**: delete the entire `libudev.so.0` symlink hack at `:6-35` (Chromium-30 era; `:32`'s `exit 1` hard-fails on any distro missing both libs). Replace with a launcher that detects whether `chrome-sandbox` is root:setuid and, if not, exports `ELECTRON_DISABLE_SANDBOX=1` / appends `--no-sandbox`. Drop the trailing `&` at `:37` — backgrounding breaks exit codes and `--wait`-style usage.
- Update `doc/developer-install.md`: delete the `libgconf-2.so.4` line at `:55`, document the `chrome-sandbox` post-extract `chown root:root && chmod 4755` option vs. accepting `--no-sandbox`.

**Windows branch (`:100-114`)** — no Electron-44-specific changes; `rcedit` still works and Electron still ships `electron.exe` at the dist root.

**macOS (`:81-92`)** — out of scope, left untouched. Note in the commit message that the mac path is unverified.

---

## Phase 5 — The `remote` swap (ClojureScript)

**Introduce `src/lt/util/remote.cljs` rather than five one-line edits.** Reasons specific to this codebase:

1. `@electron/remote` throws at `require` time if main-process setup was missed. All five namespaces require it at **namespace-load** time (`cli.cljs:31,34,36` even *call* `getGlobal` at load), so five independent throw sites give five unhelpful bootstrap stack traces. One seam gives one clear error.
2. It is exactly the seam a future contextBridge port needs, making the deferred hardening cheap instead of theoretical. Put the backlog note in this file's docstring.
3. It makes a fallback to a different remote implementation a one-file change.

Must be a **leaf namespace** — it can require nothing from `lt.objs.*`, since `lt.objs.app`, `lt.objs.platform` and `lt.objs.cli` all depend on it. Expose: `remote`, `current-window`, `Menu`, `MenuItem`, `dialog`, `app`, `get-global`, `remote-process`.

| File | Change |
|---|---|
| `app.cljs:14-15` | `(def win (remote/current-window))`, drop the local `remote` def. Everything downstream (`:24,41,42,114-134,145,266,271,276`) is unchanged — all still-valid `BrowserWindow` methods. |
| `menu.cljs:12-14,46,58` | Use `remote/Menu`, `remote/MenuItem`. At `:46`, `Menu.popup` now takes an options object: `(.popup m #js {:window (remote/current-window)})`. |
| `dialogs.cljs:8-9,12,17,22` | `(def dialog remote/dialog)`, then **`showOpenDialog`→`showOpenDialogSync`, `showSaveDialog`→`showSaveDialogSync`**. These preserve the synchronous return shape the existing code relies on — a 3-identifier change, not a promise refactor. They return `undefined` on cancel, so the `doseq` at `:13,18` is already safe. |
| `platform.cljs:10,15` | `(.getAppPath remote/app)`. |
| `cli.cljs:14,31,34,36` | `(remote/get-global "browserParsedArgs")`, `(remote/get-global "browserOpenFiles")`, `(.-argv remote/remote-process)`. |

**Result: done and verified live.** Full `script/build.sh` run on Electron 44.4.3, launched, driven via CDP against the actual running app: `app/win.getSize()` → `[1024,700]`, `isFullScreen()` → `false`, `window-number` → `1`, `platform/get-data-path` → correct app path, `menu.cljs` Menu/MenuItem construction succeeded, both `dialog.showOpenDialogSync`/`showSaveDialogSync` exist, `cli/argv` correctly proxied from the main process. No uncaught exceptions beyond the already-known, pre-existing `ws.cljs` socket.io mismatch (Risk #10). Find/replace re-verified working identically to the Electron 13 baseline.

---

## Phase 6 — API-level fixes

All are hard breaks independent of `remote`.

| Location | Change |
|---|---|
| `platform.cljs:31` | `.openItem` (removed in E9) → `.openPath`. Returns a Promise resolving to an error string — log it via `lt.objs.console` rather than dropping it. |
| `files.cljs:405` | `.moveItemTotrash` (note the mis-cased `to`) → `.trashItem`. Now async; update the docstring and check callers of `files/trash!` for anyone branching on the return value. |
| `platform.cljs:24` | `.openExternal` returns a Promise since E9 — add a rejection handler so failures surface instead of becoming unhandled rejections. |
| `browser.cljs:241` | `.getUrl` → `.getURL`. |
| `thread.cljs:69-72` | `ATOM_SHELL_INTERNAL_RUN_AS_NODE` → `ELECTRON_RUN_AS_NODE`. **Also**: `:env` currently *replaces* the child's whole environment with one variable, so the worker runs with no `PATH`/`HOME`/`TMPDIR` — merge via `(js/Object.assign #js {} js/process.env ...)`. Drop the `"--harmony"` arg at `:69`; keep `:execPath js/process.execPath`. |
| `files.cljs:74` | `wmic logicaldisk get name` — `wmic` was removed in Windows 11 24H2+. Replace with a `Get-PSDrive` PowerShell call (adjusting the `(str (.trim %) separator)` at `:77`, since output is already `C:\` form) or simply enumerate `A:`–`Z:` with `fs.existsSync`. Windows is in scope, and this currently fails silently. |

**Result: done and verified live.** Implemented the drive enumeration with `(seq "ABC...Z")` rather than `(range (int \A) (inc (int \Z)))` — the latter silently breaks in ClojureScript, since `\A` compiles to the plain string `"A"` (cljs has no char type) and `int` on a non-numeric string bit-or-coerces to `0`, so the whole range collapsed to a single null character. Caught this via live CDP verification (`available-drives` came back `[]` against a machine with two real drives) rather than shipping it. After the fix: `["C:\\", "G:\\"]`, matching the actual drives. `platform/open`, `platform/open-url`, and `files/trash!` all verified to expose the correct Promise-returning methods without throwing.

---

## Phase 7 — `<webview>` / `browserInjection.js`

`deploy/core/lighttable/browserInjection.js` is currently **dead code**: `:3` destructures `ipcMain` from `require('electron')`, which is `undefined` in a renderer/preload, so `:13` throws on load.

- `:3` → `const { ipcRenderer } = require('electron');`
- `:13,35` → `ipcRenderer.on(...)`. **Signature change matters**: `ipcRenderer.on` prepends an `event` argument, so the payload from `browser.cljs:338,346` lands in the *second* parameter.
- `sendToHost` at `:43,45,59,65,104` is unchanged.

**`browser.cljs:94-101` (`defui webview`)** — two changes:
1. `:preload` must be an absolute `file://` URL, not the bare path `(files/lt-home "core/lighttable/browserInjection.js")`. Windows needs the extra leading slash (`file:///C:/...`); `load.cljs:44-46` already contains this platform-conditional logic — mirror it.
2. Add `:webpreferences "contextIsolation=no,sandbox=no,nodeIntegration=yes"` on the `:webview` element. **Without `contextIsolation=no` the preload runs in an isolated world**, so `eval.call(window, ...)` at `browserInjection.js:41` evaluates into the wrong world and `window.cljs` / `window.jQuery` are never visible. Failure mode is *silent* — browser-tab CLJS eval returns undefined — and is easy to misdiagnose as a CDP problem.

**Verify:** open a browser tab, eval a CSS file (live style swap), eval a CLJS form (result returns via `sendToHost "browser-raise"`).

**Result: done and verified live, end-to-end.** Via CDP: opened a real browser tab (`:add-browser-tab`), sent `editor.eval.css` through the webview exactly as `browser.cljs:339` does — guest page background changed color as expected. Sent `editor.eval.cljs.exec` exactly as `browser.cljs:347` does — the guest page evaluated the code and the result correctly round-tripped back via `sendToHost "browser-raise"` and was observed on an `ipc-message` listener attached to the webview.

**Discovered during Phase 8, fixed after real Linux use (see "Post-launch fix" below):** Electron's own internal `<webview>` guest-view implementation (`electron/js2c/renderer_init.js`, not LightTable code) threw `TypeError: t.process.listenerCount is not a function` during webview creation and ipc-message dispatch. Root cause: Electron's internal code also expects the renderer's global `window.process` to be the real, nodeIntegration-provided object, but the Phase 2c fix only stashed a *copy* under `window.__electronProcess` for LightTable's own namespaces to use — it never restored the global `window.process` binding itself, which ClojureScript's compiled bootstrap permanently overwrites with its bare `{env:{}}` shim early in page load. This didn't block CSS/CLJS eval in Phase 8 testing, so it shipped as a documented non-blocker — until real Linux usage found a second, blocking symptom of the exact same root cause (Clojure InstaRepl never appearing). Both are now fixed together; see below.

### Post-launch fix: restore `window.process` globally, not just a stashed copy

**Symptom reported after real Ubuntu use:** InstaRepl never appeared in a Clojure editor. Root cause, confirmed via the Windows dev box (same underlying bug, reproducible without Linux): the Clojure plugin (`deploy/plugins/Clojure/src/lt/plugins/clojure.cljs`, a separate repo, untouched by this upgrade) does its own Java auto-detection with `(or (:java-exe @clj-lang) (aget js/process.env "JAVA_HOME") (.which shell "java"))` — reading `js/process.env` directly rather than through `lt.util.process`, since it's third-party code with no reason to know about that seam. `shelljs`'s `which()` implementation (`node_modules/shelljs/src/which.js:61`) reads `process.env.PATH` *lazily, at call time* — long after the ClojureScript shim has already clobbered `window.process` — so it always returns nothing. With all three fallbacks dead, `check-java` in the plugin never finds a JDK, `notify` shows a "couldn't find java" popup instead of connecting, and InstaRepl (which only activates once a client is connected) never appears.

This is not Clojure-specific — it would silently break Java/interpreter auto-detection for **any** plugin using the same common `shelljs.which()` pattern, and it's the same root cause as the Phase 8 webview issue above. Given it now had a confirmed, concrete, user-facing symptom rather than just console noise, fixed it properly: `deploy/core/LightTable.html`'s `bootstrap.js` `onload` handler now does `window.process = window.__electronProcess;` immediately before calling `lt.objs.app.init()` — restoring the real, nodeIntegration-provided object globally for everything that runs from that point on (third-party plugins, other bundled npm libraries, Electron's own internal code), while leaving `lt.util.process`'s already-captured values (used by LightTable's own core) unaffected either way, since those were captured once at namespace-load time regardless of what `window.process` later points to.

**Verified via live CDP on the Windows build:** no regressions (`lt` still loads, UI still renders, find/replace still works); `process.env.PATH`/`process.platform` are real values again; `shelljs.which("java")` now correctly resolves a real JDK path where it previously returned nothing; `lt.util.process`-based platform detection (`lt.objs.platform.platform`) is unaffected.

---

## Phase 8 — DevTools / CDP (land last, isolatable)

**Recommendation: fix the transport, do NOT migrate to `webContents.executeJavaScript`.** `Runtime.evaluate` is only one of four things this subsystem does — `changelive!` (`devtools.cljs:176-188`) needs `Debugger.setScriptSource`, which has no `executeJavaScript` equivalent, and the `:scripts` map is populated by `Debugger.scriptParsed` (`:236-240`). A migration would replace ~10% of the subsystem and orphan the rest. The client at `:171` also targets LightTable's *own* window, where IPC would be circular.

Ordered, cheapest first:
1. **WebSocket origin** — handled in Phase 4 via `--remote-allow-origins`. Without it Chromium 111+ returns 403 on the upgrade at `:37`.
2. **Replace the `/json` discovery XHR with Node `http`.** `:262` does an XHR to `http://localhost:8315/json` from a `file://` page; the endpoint sends no CORS headers and a `file://` origin serializes to `null`. Since `nodeIntegration` is on, use `(js/require "http")` directly — ~10 lines, no CORS. Highest-value fix in the phase. Also add a retry cap: `:268` reschedules every 1000ms forever, so permanent failure becomes an infinite busy loop.
3. **`Debugger.canSetScriptSource` is removed.** `script-exists?` (`:166-169`) now gets an error reply, so `changelive!` at `:181` takes the `remove-script!` branch and **infinitely recurses** (and has an arity bug: a 4-arg recursive call into a 5-arg fn). Delete `script-exists?`; check the local `(:scripts @client)` map instead and let `setScriptSource` fail through the existing `handle-message` routing at `:226-233`.
4. **`Console.*` domain is deprecated.** Migrate `::connect!` (`:210-212`) to `Runtime.enable` + `Log.enable` (keeping `Debugger.enable` and `Network.setCacheDisabled`), and adapt `Runtime.consoleAPICalled` / `Log.entryAdded` into the existing `handle-log-msg` multimethod (`:140-144`) — note params differ (`args` array of `RemoteObject` vs `text`, `stackTrace.callFrames` vs `url`/`line`). `Console.clearMessages` at `:250` → `Runtime.discardConsoleEntries`.

**If Phase 8 drags, ship Phases 0–7 and file it.** What degrades: JS eval in browser tabs, JS live-reload-on-save, JS watches/instarepl in browser tabs, and Chromium-level console messages reaching the LT console. What is **unaffected**: ClojureScript eval, every language plugin client (those use LT's own WebSocket server in `lt.objs.clients.ws`), CSS/CLJS eval in browser tabs (Phase 7 path, not CDP), and the editor / workspace / find / autocomplete / sidebar / settings — i.e. ~95% of normal use.

**Result: done and verified live for all four items.**
1. Origin — already fixed in Phase 4, but needed a follow-up correction discovered during Phase 8 testing: `--remote-allow-origins http://localhost:8315` still rejected LT's own connection, because a `file://` page's WebSocket `Origin` header is the literal string `"null"`, not a URL that could be allow-listed. Changed to `--remote-allow-origins *` (this port is used only by LT itself, bound to localhost).
2. HTTP discovery — implemented `fetch-debugger-info` via `js/require "http"`, with a 30-attempt retry cap (`max-reconnect-attempts`) replacing the unbounded `wait 1000` loop.
3. `script-exists?` deleted; `changelive!` now calls `Debugger.setScriptSource` directly and drops the stale `:scripts` entry on an error reply instead of pre-checking and hitting the arity bug.
4. `Console.enable` → `Runtime.enable` + `Log.enable`; added `console-api-called->msg`/`log-entry-added->msg` adapters feeding the existing `handle-log-msg` multimethod unchanged; `Console.clearMessages` → `Runtime.discardConsoleEntries`.

**Blocker found and fixed during verification, unrelated to the four items above:** LightTable's behavior-wiring file (`deploy/settings/default/default.behaviors`) explicitly maps trigger tags to behavior IDs by fully-qualified keyword — `(behavior ...)` forms are inert until an entry like `[:clients.devtools :lt.objs.clients.devtools/console-log]` attaches them to a tag (see `doc/BOT.md`). Renaming `::console-log` into the two new `::runtime-console-api-called`/`::log-entry-added` behaviors silently orphaned that mapping — the old keyword no longer resolved to anything, and the new ones were never wired in, so console messages compiled and ran with no errors but never reached LT's console panel. Caught only because verification checked for the message actually appearing, not just the absence of exceptions. Fixed by updating the two `default.behaviors` entries to match.

Verified end-to-end via CDP against a live instance: the local devtools client (`lt.objs.clients.devtools/local`, which targets LightTable's own window) successfully connects (`:connected true`) and populates `:scripts` via `Debugger.scriptParsed`. `console.log`/`console.error`/`console.warn` triggered in the page all correctly appear in LT's own console panel with the right level styling. `:clear!` (`Runtime.discardConsoleEntries`) executes without error.

---

## Phase 9 — Docs and cleanup

- `doc/developer-install.md:55` — delete the `libgconf-2.so.4` requirement; document `chrome-sandbox`.
- `doc/for-committers.md:81-82` — restate the `deploy/electron/package.json` ↔ `deploy/core/version.json` sync rule with the new version; consider a build-time check that fails on divergence.
- Update `CLAUDE.md`: it currently describes `deploy/core/node_modules/` as vendored/forked (no longer true after `000cc9b`) and `threadworker.js` as a Web Worker (it is a `child_process.fork`).
- Backlog notes (docstring in `lt/util/remote.cljs` + issues): contextIsolation hardening, deliberately deferred; `ws.cljs:57` uses socket.io v0.9 API against socket.io 4 (already broken, orthogonal); `request@2.88.2` is deprecated and is most of the 140-package tree.

**Result: done.**
- `doc/developer-install.md` — already updated in Phase 4 (chrome-sandbox docs, libgconf line removed).
- `doc/for-committers.md` — restated the version-sync rule explicitly (two separate files, nothing enforces they match), and added the `request@2.88.2` backlog note.
- `script/build.sh` — added a real build-time check (not just documentation): compares `deploy/electron/package.json`'s pinned Electron version against `deploy/core/version.json`'s, warns on divergence before the build proceeds.
- `CLAUDE.md` — corrected the Web-Worker mischaracterization of `threadworker.js` (it's a `child_process.fork`), corrected the stale vendored/forked `node_modules` description (empty since `000cc9b`; LT's own JS lives in the committed `deploy/core/lighttable/`), added JDK/`LT_JAVA_HOME` and Git-Bash-works-now notes, and pointed at this plan document for upgrade history.
- `src/lt/objs/clients/ws.cljs` — added an in-place comment on the `(def server ...)` block explaining the pre-existing socket.io v0.9-vs-v4 API mismatch, so a future reader hits an explanation instead of a mystery `TypeError`.
- `lt/util/remote.cljs`'s contextIsolation backlog note was already written when the namespace was created in Phase 5.

---

## Post-9: a real, pre-existing bug found via actual InstaRepl use (not the Electron upgrade)

After all nine phases shipped, real usage on Ubuntu (and reproduced on Windows) found that InstaRepl never activates for the Clojure language plugin. Root cause, found through extensive live CDP tracing, turned out to be **two-layered** and **entirely unrelated to Electron** — a latent bug in LightTable's own BOT (Behaviors/Objects/Tags) core that's been there since whenever core's ClojureScript version and the bundled `Clojure` plugin's pre-built JS drifted apart:

1. **Behavior-name keywords.** The Clojure plugin ships a pre-compiled `deploy/plugins/Clojure/clojure_compiled.js` built by an old ClojureScript compiler (the plugin's own `lein-light-nrepl` pins `clojurescript "0.0-3308"`, hundreds of releases behind core's `1.10.844`). ClojureScript keywords carry a precomputed hash baked in at compile time, and the hashing algorithm changed between these versions. `lt.object`'s global behavior registry (`(def behaviors (atom {}))`) is keyed by these keyword objects — a stale-hash keyword from the plugin doesn't hash-match a fresh keyword for the same `ns/name` read from `clojure.behaviors` (EDN) by core's current reader, so `->behavior` misses entries that are genuinely registered. Confirmed by linear-scanning the map by name instead of by keyed lookup, and by decompiling the exact baked-in hash values in `clojure_compiled.js`.
2. **Trigger keywords.** The same staleness affects the `:triggers #{:eval}`-style sets *inside* each behavior definition. `lt.object`'s per-object `:listeners` map (trigger keyword → behavior list, built by `->triggers`) is keyed the same way, so `object/raise`/`object/raise-reduce` calling with a freshly-compiled trigger keyword (e.g. `:eval.one`, compiled fresh into core's `bootstrap.js`) also misses the entry.

Rebuilding the plugin properly was investigated and ruled out: `deploy/plugins/Clojure/build.sh` only builds the JVM-side jar, not `clojure_compiled.js` — there is no preserved build config anywhere in the repo for the JS side, so a rebuild would mean reverse-engineering an undocumented process with real risk of breaking the ~69 *other* plugin behaviors that currently work fine.

**Fix, entirely within `src/lt/object.cljs`** (general — fixes this class of bug for any plugin with the same staleness, not just Clojure):
- `add-behavior`/`->behavior`/`trigger->behaviors`: key the behavior registry by `(str name)` instead of the raw keyword.
- `->triggers`: key the per-trigger map by `(str t)` instead of the raw trigger keyword.
- `raise`/`raise-reduce`: look up `:listeners` via `(get listeners (str k))` instead of a raw keyword-as-function call.
- `update-listeners`'s `:object.instant`/`:object.instant-load` handling updated to match (was silently no-op-ing on `dissoc` with the old keys — a correctness bug not to reintroduce).

**Verified extensively via live CDP** before and after each layer of the fix (isolating the exact failure point — `tags->behaviors` was correct, `->triggers` was the actual break — is what surfaced the second, deeper hash issue): the full pre-existing regression suite re-run clean (find/replace, autocomplete, browser tab CSS/CLJS eval, console log migration all still pass identically), the previously-`nil` `:eval`/`:eval.one` listeners now correctly resolve to `on-eval.clj`/`on-eval.one`, and triggering eval on a real `.clj` file spawns real `java.exe` processes running the bundled nREPL jar (confirmed via `tasklist`) — the connection flow that was completely dead before now genuinely runs.

---

## Verification

**On Windows (dev box) — covers Phases 0–2, 4–7:**
- After Phase 1, `script/light.sh` gives a sub-second edit/reload loop against `deploy/core` without packaging. Use it throughout Phases 5–7.
- Phase 3's throwaway `@electron/remote` smoke test runs here.
- Full `script/build.sh` → launch `builds/lighttable-0.9.0-windows/LightTable.exe`.
- Windows-specific: drive enumeration in the file-open dialog (`files.cljs:74`), the `win32` blur/focus branch (`main.js:32-40`), `rcedit` branding.

**On Linux — mandatory, not optional.** Nothing about the sandbox, `chrome-sandbox` SUID, or `libgconf` can be tested from Windows. **WSL2 is not sufficient** for the userns question and its GUI stack is atypical. Use a real VM or a container with an X/Wayland socket on **Ubuntu 24.04+** (its AppArmor unprivileged-userns restriction is precisely the class of thing that kills old Electron), ideally plus Fedora 41+.

1. Unpacked `builds/lighttable-0.9.0-linux/LightTable` launches — this alone proves the thesis.
2. The `./light` wrapper launches, including where `chrome-sandbox` is not setuid-root.
3. Extract from the `--release` **tarball**, not just the build dir — that is where the SUID bit is lost.
4. `<webview>` renders (GPU/compositing differences bite here).
5. `keyevents.js` (Mousetrap 1.6 fork, LT deviations fenced at `:230-238,720-724,753-769,1029-1037`) against a non-US layout and an IME — Mousetrap 1.6 predates the `KeyboardEvent.keyCode` deprecation and Chromium 91→146 shifted dead-key/IME behavior. Will not reproduce on a US-layout Windows box.

**Manual smoke checklist (every platform, in dependency order)** — there is no automated test suite, so budget for this pass:
window opens → add workspace folder (`dialogs.cljs`) → open file → edit/save → find/replace (2a) → autocomplete (2a) → workspace search + fuzzy navigate (2b) → CLJS eval → Clojure plugin connects → browser tab with CSS + CLJS eval (7) → toggle devtools (`main.js:87`) → window size/position/fullscreen persistence (`app.cljs:114-134`) → close and reopen (the `close`/`preventDefault`/`destroy` dance at `main.js:60-63` + `app.cljs:41-42`).

---

## Risks

**Showstoppers**
1. **`@electron/remote` 2.1.3 may not work on Electron 44** — last published July 2025, dev-tested against 28. Blast radius is the whole compat-mode strategy. Mitigated by running Phase 3 *before* any CLJS work.
2. **`chrome-sandbox` SUID / userns on Linux** — most likely reason a correctly-built app still won't start. `--no-sandbox` is the always-available escape hatch, acceptable for a tool that already runs full Node in the renderer.
3. **Part of the compat set stops being honoured.** `nodeIntegration:true` + `contextIsolation:false` + `sandbox:false` is supported-but-unloved. If any of it regresses, `cljs.cljs:24,36,44` touches `js/global` at namespace-load and the app dies before rendering a pixel. Test this at the very start of Phase 4.
4. **`build.sh` leaving `project.clj` dirty** — sounds cosmetic, will cost an afternoon. Fixed in Phase 1.

**Significant but recoverable**
5. **CDP subsystem** (Phase 8) — four stacked breakages. Degradation is well-bounded; shippable without.
6. **`<webview>` contextIsolation** — if the `:webpreferences` attribute is missed, browser-tab CLJS eval fails *silently* and looks like a CDP bug.
7. **`keyevents.js` on non-US layouts / IMEs** — won't show up in testing, will show up in a bug report.
8. **`background`-macro workers** — Phase 2b turns on code dead for years; expect it to be broken in its own right on top of the Phase 6 fixes.

**Cosmetic**
9. macOS untouched and unverified; `--deep` ad-hoc codesign at `build-app.sh:92` won't satisfy modern Gatekeeper.
10. `request@2.88.2` deprecated; `ws.cljs:57` socket.io v0.9 API — both pre-existing and orthogonal.
