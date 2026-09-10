(ns recipes-edit.events
  (:require [clojure.walk :as walk]
            [re-frame.core :as rf]
            [re-graph.core :as re-graph]
            [recipes-edit.model :as model])
  (:require-macros [recipes-edit.graphql :refer [operation]]))

(def recipe-query (operation "RecipeById"))
(def create-mutation (operation "CreateRecipe"))
(def update-mutation (operation "UpdateRecipe"))

(defn initial-db [route]
  {:route route
   :status (if (= :edit (:page route)) :loading :idle)
   :form (model/blank-form)
   :name-error? false
   :feedback nil})

(defn initialize-db [db route]
  (merge db (initial-db route)))

(defn normalize-response [response]
  (walk/keywordize-keys
   (cond
     (string? response) (js->clj (js/JSON.parse response))
     (map? response) response
     :else (js->clj response))))

(rf/reg-fx
 ::navigate
 (fn [url]
   (.assign js/location url)))

(rf/reg-event-fx
 ::initialize
 (fn [{:keys [db]} [_ route]]
   (cond-> {:db (initialize-db db route)}
     (= :edit (:page route))
     (assoc :dispatch
            [::re-graph/query
             {:id :recipe
              :query recipe-query
              :variables {:id (:id route)}
              :callback [::recipe-loaded]}]))))

(rf/reg-event-db
 ::recipe-loaded
 (fn [db [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (cond
       (seq errors) (assoc db :status :error :feedback {:kind :error :message (model/error-message errors)})
       (nil? (:recipe data)) (assoc db :status :not-found)
       :else (assoc db :status :idle :form (model/recipe->form (:recipe data)))))))

(rf/reg-event-db
 ::set-name
 (fn [db [_ value]]
   (-> db
       (assoc-in [:form :name] value)
       (assoc :name-error? false))))

(rf/reg-event-db
 ::set-method
 (fn [db [_ value]]
   (assoc-in db [:form :method] value)))

(rf/reg-event-db
 ::set-inspiration
 (fn [db [_ index value]]
   (update-in db [:form :inspirations]
              #(model/normalize-inspirations (assoc % index value)))))

(rf/reg-event-db
 ::set-ingredient-name
 (fn [db [_ index value]]
   (update-in db [:form :ingredients]
              #(model/normalize-ingredients (assoc-in % [index :name] value)))))

(rf/reg-event-db
 ::set-ingredient-amount-unit
 (fn [db [_ index value]]
   (let [[amount unit optional] (model/parse-amount-unit value)]
     (update-in db [:form :ingredients]
                #(model/normalize-ingredients
                  (assoc % index (assoc (get % index)
                                        :amount amount
                                        :unit unit
                                        :optional optional)))))))

(rf/reg-event-db
 ::remove-ingredient
 (fn [db [_ index]]
   (update-in db [:form :ingredients]
              #(model/normalize-ingredients
                (vec (concat (subvec % 0 index) (subvec % (inc index))))))))

(rf/reg-event-fx
 ::save
 (fn [{:keys [db]} _]
   (let [{:keys [page id]} (:route db)
         request {:query (if (= :new page) create-mutation update-mutation)
                  :variables (cond-> {:input (model/form->input (:form db))}
                               (= :edit page) (assoc :id id))
                  :callback [::saved]}]
     {:db (assoc db :status :saving :name-error? false :feedback nil)
      :dispatch [::re-graph/mutate request]})))

(rf/reg-event-fx
 ::saved
 (fn [{:keys [db]} [_ {:keys [response]}]]
   (let [{:keys [data errors]} (normalize-response response)]
     (cond
       (some model/empty-name-error? errors)
       {:db (assoc db :status :idle :name-error? true)}

       (seq errors)
       {:db (assoc db :status :idle
                   :feedback {:kind :error :message (model/error-message errors)})}

       (= :new (get-in db [:route :page]))
       (if-let [id (get-in data [:createRecipe :id])]
         {:db (assoc db :status :idle)
          ::navigate (str "/edit/" id)}
         {:db (assoc db :status :idle
                     :feedback {:kind :error :message "no recipe created"})})

       :else
       {:db (assoc db :status :idle
                   :feedback {:kind :success :message "Gespeichert"})}))))
