(ns recipes-edit.events
  (:require [clojure.walk :as walk]
            [re-frame.core :as rf]
            [re-graph.core :as re-graph]
            [recipes-edit.model :as model])
  (:require-macros [recipes-edit.graphql :refer [operation]]))

(def recipe-query (operation "RecipeById"))
(def create-mutation (operation "CreateRecipe"))
(def update-mutation (operation "UpdateRecipe"))
(def service-online-query (operation "ServiceOnline"))
(def capabilities-query (operation "MyCapabilities"))

(defn initial-db [route]
  {:route route
   :status (if (= :edit (:page route)) :loading :idle)
   :authorization :loading
   :form (model/blank-form)
   :baseline (model/blank-form)
   :name-error? false
   :inspirations-online nil
   :save-failed? false
   :feedback nil})

(defn initialize-db [db route]
  (merge db (initial-db route)))

(defn normalize-response [response]
  (walk/keywordize-keys
   (cond
     (string? response) (js->clj (js/JSON.parse response))
     (map? response) response
     :else (js->clj response))))

(defn- authorization-state [errors]
  (let [extensions (:extensions (first errors))]
    (case (:code extensions)
      "authentication-required" :authentication-required
      "invalid-credentials" :authentication-required
      "forbidden" :forbidden
      (case (:status extensions)
        401 :authentication-required
        403 :forbidden
        nil))))

(rf/reg-fx
 ::replace-url
 (fn [url]
   (when-let [history (.-history js/window)]
     (.replaceState history #js {} "" url))))

(defn- clear-saved-feedback-when-dirty [db]
  (if (and (= :success (get-in db [:feedback :kind]))
           (model/dirty? (:form db) (:baseline db)))
    (assoc db :feedback nil)
    db))

(rf/reg-event-fx
 ::initialize
 (fn [{:keys [db]} [_ route]]
   (let [page (:page route)]
     {:db (initialize-db db route)
      :dispatch-n (cond-> [[::re-graph/query
                            {:id :my-capabilities
                             :query capabilities-query
                             :callback [::capabilities-loaded]}]]
                    (= page :edit)
                    (conj [::re-graph/query
                           {:id :recipe
                            :query recipe-query
                            :variables {:id (:id route)}
                            :callback [::recipe-loaded]}])
                    (= page :new)
                    (conj [::re-graph/query
                           {:id :service-online
                            :query service-online-query
                            :callback [::service-online-loaded]}]))})))

(rf/reg-event-db
 ::capabilities-loaded
 (fn [db [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (if (seq errors)
       (assoc db
              :authorization (or (authorization-state errors) :error)
              :authorization-message (model/error-message errors))
       (let [capabilities (:myCapabilities data)]
         (assoc db
                :authorization (if (:canManageRecipes capabilities) :allowed
                                   (if (= "anonymous" (:role capabilities))
                                     :authentication-required
                                     :forbidden))
                :capabilities capabilities))))))

(rf/reg-event-db
 ::recipe-loaded
 (fn [db [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (cond
       (seq errors) (assoc db :status :error :feedback {:kind :error :message (model/error-message errors)})
       (nil? (:recipe data)) (assoc db :status :not-found)
       :else (let [form (model/recipe->form (:recipe data))]
               (assoc db
                      :status :idle
                      :inspirations-online (:inspirationsOnline data)
                      :form form
                      :baseline form))))))

(rf/reg-event-db
 ::service-online-loaded
 (fn [db [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (if (seq errors)
       (assoc db :feedback {:kind :error :message (model/error-message errors)})
       (assoc db :inspirations-online (:inspirationsOnline data))))))

(rf/reg-event-db
 ::set-name
 (fn [db [_ value]]
   (if (= :saving (:status db))
     db
     (-> db
         (assoc-in [:form :name] value)
         (assoc :name-error? false)
         clear-saved-feedback-when-dirty))))

(rf/reg-event-db
 ::set-method
 (fn [db [_ value]]
   (if (= :saving (:status db))
     db
     (-> (assoc-in db [:form :method] value)
         clear-saved-feedback-when-dirty))))

(rf/reg-event-db
 ::set-inspiration
 (fn [db [_ index value]]
   (if (= :saving (:status db))
     db
     (-> (update-in db [:form :inspirations]
                    #(model/normalize-inspirations (assoc % index value)))
         clear-saved-feedback-when-dirty))))

(rf/reg-event-db
 ::set-ingredient-name
 (fn [db [_ index value]]
   (if (= :saving (:status db))
     db
     (-> (update-in db [:form :ingredients]
                    #(model/normalize-ingredients (assoc-in % [index :name] value)))
         clear-saved-feedback-when-dirty))))

(rf/reg-event-db
 ::set-ingredient-amount-unit
 (fn [db [_ index value]]
   (if (= :saving (:status db))
     db
     (let [[amount unit optional] (model/parse-amount-unit value)]
       (-> (update-in db [:form :ingredients]
                      #(model/normalize-ingredients
                        (assoc % index (assoc (get % index)
                                              :amount amount
                                              :unit unit
                                              :optional optional))))
           clear-saved-feedback-when-dirty)))))

(rf/reg-event-db
 ::remove-ingredient
 (fn [db [_ index]]
   (if (= :saving (:status db))
     db
     (-> (update-in db [:form :ingredients]
                    #(model/normalize-ingredients
                      (vec (concat (subvec % 0 index) (subvec % (inc index))))))
         clear-saved-feedback-when-dirty))))

(rf/reg-event-fx
 ::save
 (fn [{:keys [db]} _]
   (let [status (:status db)]
     (if (or (not= :allowed (:authorization db))
             (= :saving status)
             (= :loading status)
             (= :not-found status)
             (= :error status)
             (not (model/dirty? (:form db) (:baseline db))))
       {}
       (let [{:keys [page]} (:route db)
             request {:query (if (= :new page) create-mutation update-mutation)
                      :variables (cond-> {:input (model/form->input (:form db) {:inspirations-online (:inspirations-online db)})}
                                   (= :edit page) (assoc :id (get-in db [:route :id])))
                      :callback [::saved]}]
         {:db (assoc db :status :saving :name-error? false :feedback nil :save-failed? false)
          :dispatch [::re-graph/mutate request]})))))

(rf/reg-event-fx
 ::saved
 (fn [{:keys [db]} [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (cond
       (seq errors)
       (if-let [authorization (authorization-state errors)]
         {:db (assoc db
                     :status :idle
                     :authorization authorization
                     :authorization-message (model/error-message errors))}
         (if (some model/empty-name-error? errors)
           {:db (assoc db :status :idle :name-error? true :save-failed? true :feedback nil)}
           {:db (assoc db :status :idle
                       :name-error? false
                       :save-failed? true
                       :feedback {:kind :error :message (model/error-message errors)})}))

       (= :new (get-in db [:route :page]))
       (if-let [id (get-in data [:createRecipe :id])]
         {:db (assoc db
                     :status :idle
                     :name-error? false
                     :route (assoc (:route db) :page :edit :id id)
                     :baseline (:form db)
                     :save-failed? false
                     :feedback {:kind :success :message "Gespeichert"})
          ::replace-url (str "/edit/" id)}
         {:db (assoc db :status :idle
                     :save-failed? true
                     :feedback {:kind :error :message "no recipe created"})})

       (get-in data [:updateRecipe :id])
       {:db (assoc db :status :idle
                   :name-error? false
                   :baseline (:form db)
                   :save-failed? false
                   :feedback {:kind :success :message "Gespeichert"})}

       :else
       {:db (assoc db :status :idle
                   :save-failed? true
                   :feedback {:kind :error :message "Save failed"})}))))

(rf/reg-event-db
 ::discard
 (fn [db _]
   (if (= :saving (:status db))
     db
     (assoc db :form (:baseline db) :name-error? false :save-failed? false :feedback nil))))
