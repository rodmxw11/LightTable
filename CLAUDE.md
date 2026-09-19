# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Light Table is a code editor built on Electron. The application logic (core objects, behaviors, editor, plugins) is written in ClojureScript (`src/`), compiled to JavaScript (`deploy/core/lighttable/bootstrap.js`), and run inside Electron alongside a large tree of Node/JS dependencies in `deploy/`.

## Build / run commands

Prerequisites: Leiningen 2.1+, node.js + npm, git. On Windows, development is normally done under Cygwin.

- Full build (installs electron + core node deps, compiles ClojureScript, assembles an app under `builds/`): `script/build.sh`
  - Override output version: `VERSION=0.8.1-pre script/build.sh`
  - Release build: `script/build.sh --release`
- Faster rebuild after the first full build (skips updating plugins/electron): `script/build-app.sh`
- Recompile ClojureScript only, after editing `src/`: `lein cljsbuild once app`
  - On Windows you may need to comment out the `:source-map` line in `project.clj` first (see `doc/developer-install.md`, issue #1025).
- Run without a full rebuild (assumes `script/build.sh` has run at least once): `script/light.sh`
- Build API docs locally (creates `codox/`, not for commit): `lein with-profile doc codox`
- Rebuild `cljsDeps.js` (needed after a ClojureScript version upgrade): `lein cljsbuild once cljsdeps`

There are no automated tests in this repo; QA is manual (see the release checklist in `doc/for-committers.md`).

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
- `src-cljsdeps/` — compiled separately into `deploy/core/node_modules/clojurescript/cljsDeps.js`, used by the background-thread worker (`threadworker.js`) to run ClojureScript compilation in a Web Worker (invoked via the `background` macro).
- `deploy/` — the Electron shell and the full runtime tree shipped in a build, including `deploy/core/node_modules/` (vendored, forked, and LT-specific JS/Node libraries — see below) and `deploy/electron/`.

### Node dependencies under `deploy/core/node_modules/`

Per `doc/for-committers.md`, this directory mixes several kinds of packages, distinguished in `deploy/core/package.json`:

- `dependencies` — vendored upstream packages; do not modify directly, update via `npm install NAME@VERSION` inside `deploy/core`.
- `forkedDependencies` — packages with LT-specific patches that should eventually go upstream (e.g. the Mousetrap fork adds chord/sequence support; changes are wrapped in comments marking the deviation).
- LT-specific libraries (e.g. `clojurescript`, `codemirror_addons`, `lighttable`).

### Editing/evaling ClojureScript live

LT can eval its own source inside a running instance (the intended dev workflow, see `doc/workflow.md`). Only eval individual top-level forms, not whole files — re-evaling certain files (e.g. `object.cljs`, `editor.cljs`) can redefine core object types/redefine app state and freeze or break the running instance.

## Contribution constraints (from CONTRIBUTING.md)

- `script/` and `deploy/` are core-team-only for direct contributions.
- Changes to vendored Node packages must go upstream first, then get pulled in via a version bump.
- CodeMirror-derived files (generally under `codemirror/`) are not accepted as PRs here — send changes upstream to CodeMirror instead.
- Add docstrings to non-trivial new functions (most existing code lacks them, but new code should have them).
