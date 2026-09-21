# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Light Table is a code editor built on Electron. The application logic (core objects, behaviors, editor, plugins) is written in ClojureScript (`src/`), compiled to JavaScript (`deploy/core/lighttable/bootstrap.js`), and run inside Electron alongside a large tree of Node/JS dependencies in `deploy/`.

## Build / run commands

Prerequisites: Leiningen 2.1+, node.js + npm, git, a JDK (17 is the safest match for the pinned `clojure 1.10.3`/`clojurescript 1.10.844`). On Windows, Git Bash/MSYS works directly (the build scripts detect `MINGW*`/`MSYS*` as well as Cygwin's `CYGWIN_NT*`); Cygwin is no longer required. To build with a JDK other than your system default without changing `JAVA_HOME` globally, set `LT_JAVA_HOME` before running `script/build.sh`.

- Full build (installs electron + core node deps, compiles ClojureScript, assembles an app under `builds/`): `script/build.sh`
  - Override output version: `VERSION=0.8.1-pre script/build.sh`
  - Release build: `script/build.sh --release`
- Faster rebuild after the first full build (skips updating plugins/electron): `script/build-app.sh`
- Recompile ClojureScript only, after editing `src/`: `lein cljsbuild once app`
  - On Windows, `script/build.sh` handles the `:source-map` workaround (issue #1025) itself and restores `project.clj` afterward; running `lein cljsbuild once app` directly does not need it.
- Run without a full rebuild (assumes `script/build.sh` has run at least once): `script/light.sh`
- Launch the packaged build on Windows with a Java 8 runtime on `PATH` so the Clojure plugin works: `script/light-windows.cmd` (double-clickable; auto-detects a JDK 8, `LT_JAVA8_HOME` overrides). The Linux `light` wrapper in the build does the same detection itself.
- Build API docs locally (creates `codox/`, not for commit): `lein with-profile doc codox`
- Rebuild `cljsDeps.js` (needed after a ClojureScript version upgrade, or after editing anything under `src-cljsdeps/`): `lein cljsbuild once cljsdeps` — `script/build.sh` already does this on every run, after `npm install` (which can otherwise wipe `deploy/core/node_modules/clojurescript/`).

There are no automated tests in this repo; QA is manual (see the release checklist in `doc/for-committers.md`). The app currently targets Electron 44.4.3 (see `ELECTRON-UPDATE-PLAN.md` for the migration history from the previous Electron 13.1.2 pin, including known non-blocking issues).

## Architecture

### Behaviors, Objects, Tags (BOT)

The whole app is organized around this pattern (fully explained in `doc/BOT.md`):

- **Objects** (`lt.object`) are plain data structures held in an atom with a globally unique id, created from a template via `object/object*` + `object/create`. Almost all mutable state in LT lives in objects.
- **Behaviors** are defined with the `lt.macros/behavior` macro and declare `:triggers` (the events they react to) and a `:reaction` callback. Behaviors can be `:debounce`d/throttled.
- **Tags** map to sets of behaviors. Objects declare tags, and the merged `.behaviors` files (core defaults + user's `user.behaviors` + any plugin `.behaviors` files) determine which behaviors are attached to which tagged objects. This mapping is recomputed and hot-applied on save/eval of any `.behaviors` file, without restarting the app — this is what makes LT's UI/behavior "live-editable."
- Triggering an event is done with `object/raise`, which dispatches to every behavior listening for that trigger on that object's tags.

When exploring the codebase, prefer the in-app searcher / doc searcher over guessing — behaviors and objects are looked up by tag/trigger, not always by ordinary var references, so plain grep can miss usages that only exist as keywords in `.behaviors` files.

### Source layout

- `src/lt/object.cljs`, `src/lt/macros.cljc` — the BOT core primitives (object creation, the `behavior` macro).
- `src/lt/objs/` — the built-in objects: editor, files, command, console, notifos, search, sidebar, clients, langs, etc. This is the bulk of LT's own logic.
- `src/lt/plugins/` — built-in plugins (auto-complete, auto-paren, doc, watches).
- `src/lt/util/` — shared utilities.
- `src-cljsdeps/` — compiled separately into `deploy/core/node_modules/clojurescript/cljsDeps.js`, read by `deploy/core/lighttable/background/threadworker.js`. That file is **not** a Web Worker — it's a `child_process.fork`'d Node process (re-launched via `ELECTRON_RUN_AS_NODE`), used by the `background` macro to run work (search, fuzzy file navigation, behaviors parsing) off the renderer's main thread.
- `deploy/` — the Electron shell and the full runtime tree shipped in a build: `deploy/core/` (the app payload, becomes `resources/app/core/`), `deploy/electron/` (pins and downloads the Electron binary — see `deploy/electron/package.json`), `deploy/platform/{mac,linux,win}/` (per-OS branding/launcher scripts), `deploy/settings/default/` (default keymap/behaviors).

### Node dependencies under `deploy/core/node_modules/`

This entire directory is `npm install`-populated at build time and gitignored — nothing under it is committed, and `forkedDependencies` in `deploy/core/package.json` is now empty (as of commit `000cc9b`, "npm install happens at build, no more forking of libraries"). LT-specific JS lives instead in the **committed** `deploy/core/lighttable/` directory — notably `deploy/core/lighttable/codemirror/` (forks of CodeMirror's search/hint addons with LT-specific APIs, *not* drop-in replacements for the upstream addons — see its README before touching them) and `deploy/core/lighttable/background/` (the worker scripts above).

### Legacy-plugin compatibility shims (`deploy/core/LightTable.html`)

The bundled plugins (`script/build.sh`'s `PLUGINS` list) are precompiled JavaScript from ~2015, and two shims installed right after `bootstrap.js` loads — before `lt.objs.app.init()` — are what let them run at all. Both fail *silently* if removed, so don't "clean them up":

- **Keyword hashing.** A compiled cljs keyword literal bakes in a compile-time hash. The algorithm changed between the plugins' ClojureScript and core's, so a plugin's `:foo` is `=` to core's but hashes differently, and every hash-map/set lookup misses in both directions — nothing throws, values are just inexplicably nil. The shim overrides `cljs.core.Keyword.prototype.cljs$core$IHash$_hash$arity$1` to recompute from `ns`/`name`. Plugins share core's single `cljs.core`, so this fixes all of them at once. `lt.object/fresh-kw` and `fresh-kw-keys` predate it and remain for collection-type normalization.
- **`crate` → `singultus`.** Core's hiccup library is `singultus`, aliased to `crate` in source but compiling to the `singultus.*` global. Plugins reference the old `crate.*` global; the shim aliases it.

### The Clojure plugin needs Java 8

`lein-light-standalone.jar` embeds Leiningen 2.5.2, which references `sun.misc.Launcher$ExtClassLoader` — removed in Java 9. It fails on JDK 11/17/21 alike. Only the Clojure client is affected; the build itself wants JDK 17. See `UBUNTU-START.md`.

### Editing/evaling ClojureScript live

LT can eval its own source inside a running instance (the intended dev workflow, see `doc/workflow.md`). Only eval individual top-level forms, not whole files — re-evaling certain files (e.g. `object.cljs`, `editor.cljs`) can redefine core object types/redefine app state and freeze or break the running instance.

## Contribution constraints (from CONTRIBUTING.md)

- `script/` and `deploy/` are core-team-only for direct contributions.
- Changes to vendored Node packages must go upstream first, then get pulled in via a version bump.
- CodeMirror-derived files (generally under `codemirror/`) are not accepted as PRs here — send changes upstream to CodeMirror instead.
- Add docstrings to non-trivial new functions (most existing code lacks them, but new code should have them).
