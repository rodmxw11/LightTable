(ns lt.objs.platform
  "Provide platform-agnostic and platform related fns"
  (:require [lt.object :as object]
            [lt.util.dom :as dom]
            [lt.util.process :as process]
            [lt.util.remote :as remote])
  (:require-macros [lt.macros :refer [behavior]]))

(def electron true)

(def fs (js/require "fs"))
(def clipboard (.-clipboard (js/require "electron")))
(def electron-shell (.-shell (js/require "electron")))

(defn get-data-path []
  (.getAppPath remote/app))

(defn normalize [plat]
  (condp = plat
    "win32" :windows
    "linux" :linux
    "darwin" :mac))

(defn open-url [path]
  (-> (.openExternal electron-shell path)
      (.catch (fn [err] (js/lt.objs.console.error err)))))

(defn open
  "If the given path exists, open it with the desktop's default manner.
  Otherwise, open it as an external protocol e.g. a url."
  [path]
  (if (.existsSync fs path)
    ;; shell.openPath resolves to an error string on failure, "" on success.
    (-> (.openPath electron-shell path)
        (.then (fn [err] (when (seq err) (js/lt.objs.console.error err)))))
    (open-url path)))

(defn show-item [path]
  (.showItemInFolder electron-shell path))

(defn copy
  "Copies given text to platform's clipboard"
  [text]
  (.writeText clipboard text))

(defn paste
  "Returns text of last copy to platform's clipboard"
  []
  (.readText clipboard))

(def platform (normalize process/platform))

(defn mac? []
  (= platform :mac))

(defn win? []
  (= platform :windows))

(defn linux? []
  (= platform :linux))
