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

(defn- recipe-form [{:keys [form status name-error? feedback]}]
  (let [saving? (= :saving status)]
    [:form
     {:on-submit (fn [event]
                   (.preventDefault event)
                   (rf/dispatch [::events/save]))}
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
         [:small#name-helper "Name darf nicht leer sein."])]]
     [:h2 "Zutaten"]
     (doall (map-indexed ingredient-row (:ingredients form)))
     [:h2 "Zubereitung"]
     [:textarea
      {:id "method"
       :name "method"
       :rows 4
       :value (:method form)
       :style {:scrollbar-width "none"}
       :ref resize-textarea!
       :on-change (fn [event]
                    (resize-textarea! (.-target event))
                    (rf/dispatch [::events/set-method (.. event -target -value)]))}]
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
       (:inspirations form)))
     (when feedback
       [:p.feedback
        {:class (name (:kind feedback)) :role "alert"}
        (:message feedback)])
     [:div.grid
      [:button
       {:type "submit" :disabled saving? :aria-busy saving?}
       "Speichern"]
      [:a.secondary {:href "/" :role "button"} "Abbrechen"]]]))

(defn app []
  (let [{:keys [route status feedback] :as state} @(rf/subscribe [::subs/state])]
    (case (:page route)
      :new [:<> [:h1 "Neues Rezept"] [recipe-form state]]
      :edit [:<>
             [:h1 "Rezept bearbeiten"]
             (case status
               :loading [:p "Lädt…"]
               :not-found [:p "Rezept nicht gefunden."]
               :error [:p (:message feedback)]
               [recipe-form state])]
      "Page not found.")))
