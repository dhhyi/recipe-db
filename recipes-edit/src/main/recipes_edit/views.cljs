(ns recipes-edit.views
  (:require [re-frame.core :as rf]
            [recipes-edit.events :as events]
            [recipes-edit.model :as model]
            [recipes-edit.subs :as subs]))

(defn- resize-textarea! [textarea]
  (when textarea
    (set! (.. textarea -style -height) "auto")
    (set! (.. textarea -style -height) (str (.-scrollHeight textarea) "px"))))

(defn- ingredient-row [index ingredient]
  [:div.flex.flex-row.gap-1.items-center {:key index}
   [:input.w-20!.sm:w-28!
    {:type "text"
     :id (str "ingredient-amount-unit-" index)
     :placeholder "Menge/Einheit"
     :value (model/format-amount-unit ingredient)
     :on-change #(rf/dispatch [::events/set-ingredient-amount-unit index (.. % -target -value)])}]
   [:input
    {:type "text"
     :id (str "ingredient-name-" index)
     :placeholder "Zutat"
     :value (:name ingredient)
     :on-change #(rf/dispatch [::events/set-ingredient-name index (.. % -target -value)])}]
   [:button
    {:type "button"
     :aria-label "Zutat entfernen"
     :title "Zutat entfernen"
     :on-click #(rf/dispatch [::events/remove-ingredient index])}
    "-"]])

(defn- return-action [{:keys [route status]}]
  [:a.secondary
   {:href (if (= :edit (:page route)) (str "/recipe/" (:id route)) "/")
    :role "button"
    :aria-disabled (= :saving status)
    :tab-index (when (= :saving status) -1)}
   (if (= :edit (:page route)) "Zurück zum Rezept" "Zurück zur Übersicht")])

(defn- recipe-form [{:keys [form baseline status name-error? feedback inspirations-online save-failed?] :as state}]
  (let [saving? (= :saving status)
        dirty? (model/dirty? form baseline)]
    [:form
     {:on-submit (fn [event]
                   (.preventDefault event)
                   (rf/dispatch [::events/save]))}
     [:fieldset {:disabled saving?}
      [:fieldset
       [:label
        [:span#name-label "Name"]
        [:input
         (cond-> {:type "text"
                  :id "name"
                  :name "name"
                  :aria-labelledby "name-label"
                  :value (:name form)
                  :on-change #(rf/dispatch [::events/set-name (.. % -target -value)])}
           name-error? (assoc :aria-invalid "true" :aria-describedby "name-helper"))]
        (when name-error?
          [:small#name-helper {:role "alert"} "Name darf nicht leer sein."])]]
      [:h2 "Zutaten"]
      (doall (map-indexed ingredient-row (:ingredients form)))
      [:h2 "Zubereitung"]
      [:textarea
       {:id "method"
        :name "method"
        :rows 4
        :value (:method form)
        :style {:scrollbar-width "none"}
        :ref #(resize-textarea! %)
        :on-change (fn [event]
                     (resize-textarea! (.-target event))
                     (rf/dispatch [::events/set-method (.. event -target -value)]))}]
      (when inspirations-online
        [:<>
         [:h2 "Inspirationen"]
         (doall
          (map-indexed
           (fn [index inspiration]
             [:div {:key index}
              [:input
               {:type "url"
                :id (str "inspiration-" index)
                :placeholder "Link"
                :value inspiration
                :on-change #(rf/dispatch [::events/set-inspiration index (.. % -target -value)])}]])
           (:inspirations form)))])]
     (when (= :error (:kind feedback))
       [:p.feedback.error {:role "alert"} (:message feedback)])
     [:p {:role "status" :aria-live "polite"}
      (cond
        saving? "Änderungen werden gespeichert. Bitte warten …"
        dirty? "Ungespeicherte Änderungen."
        (= :success (:kind feedback)) (:message feedback)
        :else "Keine ungespeicherten Änderungen.")]
     [:div.editor-actions
      [:div.editor-buttons
       [:button
        {:type "submit" :disabled (or saving? (not dirty?)) :aria-busy saving?}
        (cond saving? "Speichert …" save-failed? "Erneut speichern" :else "Speichern")]
       [:button.secondary
        {:type "button"
         :disabled (or saving? (not dirty?))
         :on-click #(rf/dispatch [::events/discard])}
        "Änderungen verwerfen"]]
      [return-action state]]]))

(defn app []
  (let [{:keys [route status feedback] :as state} @(rf/subscribe [::subs/state])]
    (case (:page route)
      :new [:<> [:h1 "Neues Rezept"] [recipe-form state]]
      :edit [:<>
             [:h1 "Rezept bearbeiten"]
             (case status
               :loading [:<> [:p {:role "status"} "Lädt…"] [return-action state]]
               :not-found [:<> [:p "Rezept nicht gefunden."] [return-action state]]
               :error [:<> [:p.feedback.error {:role "alert"} (:message feedback)] [return-action state]]
               [recipe-form state])]
      "Page not found.")))
