(ns lt.util.process
  "Single access point for Node's process object in the renderer.

  ClojureScript's own compiled cljs.core bootstrap unconditionally
  reassigns the global `process` to a bare {env:{}} shim (see
  process.env.cljs in the ClojureScript standard library, used for
  cljs.core's environment-target detection) — this clobbers the real,
  fully-populated process object Electron injects via nodeIntegration.
  LightTable.html stashes the real object as window.__electronProcess
  before bootstrap.js runs; every other namespace should read process
  state through this namespace rather than js/process directly.")

(def process (or js/window.__electronProcess js/process))
(def env (.-env process))
(def platform (.-platform process))
(def argv (.-argv process))
(def exec-path (.-execPath process))
(def versions (.-versions process))
(def version (.-version process))

(defn cwd [] (.cwd process))

(defn next-tick [f] (.nextTick process f))
