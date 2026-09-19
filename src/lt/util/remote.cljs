(ns lt.util.remote
  "Single access point for @electron/remote, which replaces Electron's
  built-in `remote` module (removed in Electron 14). Every namespace that
  needs to reach across into the main process (BrowserWindow control,
  native menus, native dialogs, app.getAppPath, argv/global reads) should
  go through here rather than requiring 'electron' or '@electron/remote'
  directly, so that a load-time failure (e.g. main.js forgetting to call
  remoteMain.enable() for this window) surfaces as one clear error instead
  of five different unhelpful stack traces from five namespaces.

  This is also the seam a future contextIsolation/contextBridge hardening
  pass would replace — deliberately deferred for now since LightTable's
  plugin ecosystem calls js/require directly and would break under it.")

(def remote (js/require "@electron/remote"))

(defn current-window [] (.getCurrentWindow remote))

(def Menu (.-Menu remote))
(def MenuItem (.-MenuItem remote))
(def dialog (.-dialog remote))
(def app (.-app remote))
(def remote-process (.-process remote))

(defn get-global [k] (.getGlobal remote k))
