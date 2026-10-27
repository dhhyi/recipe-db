(ns recipes-edit.views
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [recipes-edit.events :as events]
            [recipes-edit.model :as model]
            [recipes-edit.subs :as subs]))

(defn- resize-textarea! [textarea]
  (when textarea
    (set! (.. textarea -style -height) "auto")
    (let [style (js/window.getComputedStyle textarea)
          adjustment (if (= "border-box" (.-boxSizing style))
                       (+ (js/parseFloat (.-borderTopWidth style))
                          (js/parseFloat (.-borderBottomWidth style)))
                       (- (+ (js/parseFloat (.-paddingTop style))
                             (js/parseFloat (.-paddingBottom style)))))]
      (set! (.. textarea -style -height)
            (str (+ (.-scrollHeight textarea) adjustment) "px")))))

(defn- auto-sizing-textarea []
  (let [textarea (atom nil)
        resize! (fn [_] (resize-textarea! @textarea))]
    (r/create-class
     {:component-did-mount resize!
      ;; The controlled child applies its value before this parent lifecycle.
      :component-did-update resize!
      :reagent-render
      (fn [props]
        [:textarea (assoc props :ref #(reset! textarea %))])})))

(defn- ingredient-row [index ingredient]
  [:div.flex.flex-row.gap-1.items-center {:key index}
   [:input.w-20!.sm:w-28!.min-w-0
    {:type "text"
     :id (str "ingredient-amount-unit-" index)
     :placeholder "Menge/Einheit"
     :value (model/format-amount-unit ingredient)
     :on-change #(rf/dispatch [::events/set-ingredient-amount-unit index (.. % -target -value)])}]
   [:input.min-w-0
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
        [:input.min-w-0
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
      [auto-sizing-textarea
       {:id "method"
        :name "method"
        :rows 4
        :value (:method form)
        :style {:scrollbar-width "none"}
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
              [:input.min-w-0
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
     [:div.editor-actions {:class "grid! gap-2 my-3"}
      [:div.editor-buttons.flex.flex-wrap.gap-2
       [:button.w-auto!.max-w-full
        {:type "submit" :disabled (or saving? (not dirty?)) :aria-busy saving?}
        (cond saving? "Speichert …" save-failed? "Erneut speichern" :else "Speichern")]
       [:button.secondary.w-auto!.max-w-full
        {:type "button"
         :disabled (or saving? (not dirty?))
         :on-click #(rf/dispatch [::events/discard])}
        "Änderungen verwerfen"]]
      [return-action state]]]))

(defn app []
  (let [{:keys [route status feedback] :as state} @(rf/subscribe [::subs/state])]
    (case (:authorization state)
      :loading [:<> [:h1 "Zugriff wird geprüft"] [:p {:role "status"} "Bitte warten …"] [return-action state]]
      :authentication-required
      [:<>
       [:h1 "Anmeldung erforderlich"]
       [:p.feedback.error {:role "alert"} "Zum Bearbeiten von Rezepten ist eine Anmeldung erforderlich."]
       [:a {:href "/oauth2/start?rd=%2F"} "Mit Google anmelden"]
       [return-action state]]
      :forbidden
      [:<>
       [:h1 "Keine Berechtigung"]
       [:p.feedback.error {:role "alert"} "Dein Konto darf Rezepte nicht bearbeiten."]
       [return-action state]]
      :error
      [:<>
       [:h1 "Zugriff nicht verfügbar"]
       [:p.feedback.error {:role "alert"} (:authorization-message state)]
       [:a {:href "/oauth2/start?rd=%2F"} "Anmelden"]
       [return-action state]]
      :allowed
      (case (:page route)
        :new [:<> [:h1 "Neues Rezept"] [recipe-form state]]
        :edit [:<>
               [:h1 "Rezept bearbeiten"]
               (case status
                 :loading [:<> [:p {:role "status"} "Lädt…"] [return-action state]]
                 :not-found [:<> [:p "Rezept nicht gefunden."] [return-action state]]
                 :error [:<> [:p.feedback.error {:role "alert"} (:message feedback)] [return-action state]]
                 [recipe-form state])]
        "Page not found.")
      "Page not found.")))
