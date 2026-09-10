(ns recipes-edit.core
  (:require [re-frame.core :as rf]
            [re-graph.core :as re-graph]
            [reagent.dom.client :as reagent-dom]
            [recipes-edit.events :as events]
            [recipes-edit.views :as views]))

(defonce root
  (reagent-dom/create-root (.getElementById js/document "app")))

(defn- route [pathname]
  (cond
    (= "/edit/new" pathname) {:page :new}
    :else (if-let [[_ id] (re-matches #"/edit/([^/]+)" pathname)]
            {:page :edit :id id}
            {:page :not-found})))

(defn init []
  (rf/dispatch-sync [::re-graph/init {:ws nil :http {:url "/graphql"}}])
  (rf/dispatch-sync [::events/initialize (route (.-pathname js/location))])
  (reagent-dom/render root [views/app]))
