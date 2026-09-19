(ns lt.objs.dialogs
  "Provide Electron-based dialogs"
  (:require [lt.object :as object]
            [lt.util.dom :as dom]
            [lt.objs.app :as app]
            [lt.util.remote :as remote])
  (:require-macros [lt.macros :refer [behavior defui]]))

(def dialog remote/dialog)

(defn dir [obj event]
  (let [files (.showOpenDialogSync dialog app/win #js {:properties #js ["openDirectory" "multiSelections"]})]
    (doseq [file files]
      (object/raise obj event file))))

(defn file [obj event]
  (let [files (.showOpenDialogSync dialog app/win #js {:properties #js ["openFile" "multiSelections"]})]
    (doseq [file files]
      (object/raise obj event file))))

(defn save-as [obj event path]
  (when-let [file (.showSaveDialogSync dialog app/win #js {:defaultPath path})]
    (object/raise obj event file)))
