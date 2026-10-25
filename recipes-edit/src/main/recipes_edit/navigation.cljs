(ns recipes-edit.navigation
  (:require [re-frame.db :as db]
            [recipes-edit.model :as model]))

(defonce stop-guards! (atom nil))

(defn start! []
  (when-let [stop! @stop-guards!] (stop!))
  (let [guarded? (atom false)
        before-unload (fn [event]
                        (.preventDefault event)
                        (set! (.-returnValue event) ""))]
    (letfn [(set-guard! [value]
              (when (not= value @guarded?)
                (reset! guarded? value)
                (if value
                  (.addEventListener js/window "beforeunload" before-unload)
                  (.removeEventListener js/window "beforeunload" before-unload))))
            (sync-state! [state]
              (let [saving? (= :saving (:status state))]
                (set-guard! (or saving? (model/dirty? (:form state) (:baseline state))))
                (when-let [header (.querySelector js/document "header-component")]
                  (set! (.-inert header) saving?))))
            (click! [event]
              (when-let [anchor (some #(when (and (.-matches %) (.matches % "a[href]")) %)
                                      (array-seq (.composedPath event)))]
                (let [destination (js/URL. (.-href anchor) (.-href js/location))
                      current (js/URL. (.-href js/location))
                      saving? (= :saving (:status @db/app-db))]
                  (when (= (.-origin destination) (.-origin current))
                    (cond
                      saving?
                      (do (.preventDefault event) (.stopImmediatePropagation event))

                      (or (.-defaultPrevented event)
                          (not @guarded?)
                          (not= 0 (.-button event))
                          (.-ctrlKey event) (.-metaKey event) (.-shiftKey event) (.-altKey event)
                          (not (contains? #{"" "_self" "_top" "_parent"} (.toLowerCase (.-target anchor))))
                          (.hasAttribute anchor "download")
                          (and (= (.-pathname destination) (.-pathname current))
                               (= (.-search destination) (.-search current))
                               (.includes (.-href destination) "#")))
                      nil

                      (js/confirm "Ungespeicherte Änderungen verwerfen und Seite verlassen?")
                      (set-guard! false)

                      :else
                      (do (.preventDefault event) (.stopImmediatePropagation event)))))))]
      (add-watch db/app-db ::guards (fn [_ _ _ state] (sync-state! state)))
      (.addEventListener js/document "click" click! true)
      (sync-state! @db/app-db)
      (reset! stop-guards!
              (fn []
                (remove-watch db/app-db ::guards)
                (.removeEventListener js/document "click" click! true)
                (set-guard! false))))))
