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

(defn- animate-ingredient! [element frames]
  (when (and (fn? (.-animate element))
             (not (.. js/window (matchMedia "(prefers-reduced-motion: reduce)") -matches)))
    (.animate element (clj->js frames) #js {:duration 200 :easing "ease-out"})))

(defn- remove-ingredient! [event index ingredient]
  (when-not (model/blank-ingredient? ingredient)
    (let [row (.. event -currentTarget -parentElement)
          rect (.getBoundingClientRect row)
          ghost (.cloneNode row true)]
      (when (and (fn? (.-animate ghost))
                 (not (.. js/window (matchMedia "(prefers-reduced-motion: reduce)") -matches)))
        (doseq [[source target] (map vector
                                     (array-seq (.querySelectorAll row "input"))
                                     (array-seq (.querySelectorAll ghost "input")))]
          (set! (.-value target) (.-value source))
          (.removeAttribute target "id"))
        (.setAttribute ghost "aria-hidden" "true")
        (.setAttribute ghost "inert" "")
        (set! (.-cssText (.-style ghost))
              (str "position:fixed;pointer-events:none;z-index:10;margin:0;"
                   "left:" (.-left rect) "px;top:" (.-top rect) "px;width:" (.-width rect) "px"))
        (.appendChild (.-body js/document) ghost)
        (let [animation (animate-ingredient! ghost [{:opacity 1 :transform "translateX(0)"}
                                                    {:opacity 0 :transform "translateX(-12px)"}])
              cleanup #(.remove ghost)]
          (set! (.-onfinish animation) cleanup)
          (set! (.-oncancel animation) cleanup)))))
  (rf/dispatch [::events/remove-ingredient index]))

(defn- ingredient-row [index ingredient on-remove]
  [:div.flex.flex-row.gap-1.items-center {:key index}
   [:input.min-w-0
    {:type "text"
     :id (str "ingredient-amount-unit-" index)
     :placeholder "Menge/Einheit"
     :aria-label "Menge/Einheit"
     :value (model/format-amount-unit ingredient)
     :on-change #(rf/dispatch [::events/set-ingredient-amount-unit index (.. % -target -value)])}]
   [:input.min-w-0
    {:type "text"
     :id (str "ingredient-name-" index)
     :placeholder "Zutat"
     :aria-label "Zutat"
     :value (:name ingredient)
     :on-change #(rf/dispatch [::events/set-ingredient-name index (.. % -target -value)])}]
   [:button.outline
    {:type "button"
     :aria-label "Zutat entfernen"
     :title "Zutat entfernen"
     :on-click #(on-remove % index ingredient)}
    "-"]])

(defn- ingredient-list []
  (let [container (atom nil)
        observer (atom nil)
        removing (atom nil)]
    (r/create-class
     {:component-did-mount
      (fn [_]
        (when (exists? js/MutationObserver)
          (let [watcher (js/MutationObserver.
                         (fn [records]
                           (when (and @removing
                                      (some #(pos? (.-length (.-removedNodes %))) (array-seq records)))
                             (let [{:keys [index tops following]} @removing]
                               (doseq [[position node] (map-indexed vector (array-seq (.-children @container)))
                                       :when (and (>= position index) (< (inc position) (count tops)))]
                                 (let [offset (- (nth tops (inc position)) (.-top (.getBoundingClientRect node)))]
                                   (animate-ingredient! node [{:transform (str "translateY(" offset "px)")}
                                                              {:transform "translateY(0)"}])))
                               (doseq [[node top] following
                                       :when (.-isConnected node)]
                                 (let [offset (- top (.-top (.getBoundingClientRect node)))]
                                   (animate-ingredient! node [{:transform (str "translateY(" offset "px)")}
                                                              {:transform "translateY(0)"}]))))
                             (reset! removing nil))
                           (doseq [record (array-seq records)
                                   node (array-seq (.-addedNodes record))]
                             (when (= 1 (.-nodeType node))
                               (animate-ingredient! node [{:opacity 0 :transform "translateY(-8px)"}
                                                          {:opacity 1 :transform "translateY(0)"}])))))]
            (.observe watcher @container #js {:childList true})
            (reset! observer watcher))))
      :component-will-unmount
      (fn [_] (when @observer (.disconnect @observer)))
      :reagent-render
      (fn [ingredients]
        [:div {:ref #(reset! container %)}
         (doall
          (map-indexed
           (fn [index ingredient]
             (ingredient-row index ingredient
                             (fn [event index ingredient]
                               (when-not (model/blank-ingredient? ingredient)
                                 (reset! removing
                                         {:index index
                                          :tops (mapv #(.-top (.getBoundingClientRect %))
                                                      (array-seq (.-children @container)))
                                          :following (loop [node (.-nextElementSibling @container)
                                                            result []]
                                                       (if node
                                                         (recur (.-nextElementSibling node)
                                                                (conj result [node (.-top (.getBoundingClientRect node))]))
                                                         result))}))
                               (remove-ingredient! event index ingredient))))
           ingredients))])})))

(defn- return-action [{:keys [route status]}]
  [:a
   {:href (if (= :edit (:page route)) (str "/recipe/" (:id route)) "/")
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
      [:input.min-w-0
       (cond-> {:type "text"
                :id "name"
                :name "name"
                :placeholder "Name"
                :aria-label "Name"
                :value (:name form)
                :on-change #(rf/dispatch [::events/set-name (.. % -target -value)])}
         name-error? (assoc :aria-invalid "true" :aria-describedby "name-helper"))]
      (when name-error?
        [:small#name-helper {:role "alert"} "Name darf nicht leer sein."])
      [:h2 "Zutaten"]
      [ingredient-list (:ingredients form)]
      [:h2 "Zubereitung"]
      [auto-sizing-textarea
       {:id "method"
        :name "method"
        :aria-label "Zubereitung"
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
                :aria-label "Link"
                :value inspiration
                :on-change #(rf/dispatch [::events/set-inspiration index (.. % -target -value)])}]])
           (:inspirations form)))])]
     (when (= :error (:kind feedback))
       [:p.feedback.error {:role "alert"} (:message feedback)])
     (when dirty?
       [:p.feedback.warning {:role "status" :aria-live "polite"}
        "Ungespeicherte Änderungen."])
     (when (= :success (:kind feedback))
       [:p.feedback.success.save-feedback {:role "status" :aria-live "polite"}
        (:message feedback)])
     [:div.flex.flex-wrap.gap-2
      [:button.w-auto!.max-w-full
       (cond-> {:type "submit" :disabled (or saving? (not dirty?))}
         saving? (assoc :aria-busy "true"))
       (if save-failed? "Erneut speichern" "Speichern")]
      [:button.outline.w-auto!.max-w-full
       {:type "button"
        :disabled (or saving? (not dirty?))
        :on-click #(rf/dispatch [::events/discard])}
       "Änderungen verwerfen"]]
     [:p [return-action state]]]))

(defn app []
  (let [{:keys [route status feedback] :as state} @(rf/subscribe [::subs/state])]
    (case (:authorization state)
      :loading [:<> [:div {:aria-busy "true" :aria-label "Zugriff wird geprüft"}] [return-action state]]
      :authentication-required
      [:<>
       [:h1 "Anmeldung erforderlich"]
       [:p.feedback.error {:role "alert"} "Zum Bearbeiten von Rezepten ist eine Anmeldung erforderlich."]
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
       [return-action state]]
      :allowed
      (case (:page route)
        :new (if (= :outcome-unknown status)
               [:<>
                [:h1 "Speichern unklar"]
                [:p.feedback.error {:role "alert"} (:message feedback)]
                [return-action state]]
               [:<> [:h1 "Neues Rezept"] [recipe-form state]])
        :edit [:<>
               [:h1 "Rezept bearbeiten"]
               (case status
                 :loading [:<> [:div {:aria-busy "true" :aria-label "Rezept wird geladen"}] [return-action state]]
                 :not-found [:<> [:p.feedback.error {:role "alert"} "Rezept nicht gefunden."] [return-action state]]
                 :error [:<> [:p.feedback.error {:role "alert"} (:message feedback)] [return-action state]]
                 [recipe-form state])]
        "Page not found.")
      "Page not found.")))
