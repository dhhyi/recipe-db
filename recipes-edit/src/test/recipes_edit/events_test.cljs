(ns recipes-edit.events-test
  (:require [cljs.test :refer [deftest is testing]]
            [re-frame.registrar :as registrar]
            [re-graph.core :as re-graph]
            [recipes-edit.events :as events]
            [recipes-edit.model :as model]))

(defn- event-effects [db event]
  (let [interceptors (registrar/get-handler :event (first event))]
    (is (some? interceptors) (str "expected registered handler for " (first event)))
    (-> ((:before (last interceptors))
         {:coeffects {:db db :event event}
          :effects {}})
        :effects)))

(defn- event-db [db event]
  (:db (event-effects db event)))

(deftest initialize-event-preserves-re-graph-and-sets-blank-baseline
  (let [state {:re-graph {:default {:http {:url "/graphql"}}}}
        effects (event-effects state [::events/initialize {:page :new}])
        db (:db effects)]
    (is (= (:re-graph state) (:re-graph db)))
    (is (= :idle (:status db)))
    (is (= (:form db) (:baseline db)))
    (is (= [::re-graph/query
            {:id :service-online
             :query events/service-online-query
             :callback [::events/service-online-loaded]}]
           (:dispatch effects)))))

(deftest initialize-event-for-edit-queries-recipe
  (let [effects (event-effects {} [::events/initialize {:page :edit :id "123"}])
        db (:db effects)]
    (is (= :loading (:status db)))
    (is (= {:page :edit :id "123"} (:route db)))
    (is (= [::re-graph/query
            {:id :recipe
             :query events/recipe-query
             :variables {:id "123"}
             :callback [::events/recipe-loaded]}]
           (:dispatch effects)))))

(deftest normalizes-graphql-response-keys
  (is (= {:data {:createRecipe nil}
          :errors [{:message "Missing field value for name"
                    :extensions {:code "required-field" :field "name"}}]}
         (events/normalize-response
          {"data" {"createRecipe" nil}
           "errors" [{"message" "Missing field value for name"
                      "extensions" {"code" "required-field" "field" "name"}}]}))))

(deftest recipe-loaded-success-updates-form-and-baseline
  (let [db {:status :loading
            :route {:page :edit :id "123"}}
        effects (event-effects db [::events/recipe-loaded
                                   {:response {:data {:recipe {:name "Soup"
                                                               :method "Boil"
                                                               :ingredients []
                                                               :inspirations []}
                                                      :inspirationsOnline true}
                                               :errors []}}])
        next-db (:db effects)]
    (is (= :idle (:status next-db)))
    (is (= "Soup" (get-in next-db [:form :name])))
    (is (= (:form next-db) (:baseline next-db)))
    (is (true? (:inspirations-online next-db)))))

(deftest set-name-clears-success-feedback-when-form-becomes-dirty
  (let [baseline {:name "Soup"
                  :method "Boil"
                  :ingredients (model/normalize-ingredients [])
                  :inspirations (model/normalize-inspirations [])}
        db {:status :idle
            :form baseline
            :baseline baseline
            :feedback {:kind :success :message "Gespeichert"}}
        next-db (event-db db [::events/set-name "Soup 2"])]
    (is (= "Soup 2" (get-in next-db [:form :name])))
    (is (nil? (:feedback next-db)))))

(deftest edit-events-are-ignored-while-saving
  (let [db {:status :saving
            :name-error? true
            :feedback {:kind :success :message "Gespeichert"}
            :form {:name "Soup"
                   :method "Boil"
                   :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                                 model/blank-ingredient]
                   :inspirations ["https://a.example" ""]}
            :baseline {:name "Soup"
                       :method "Boil"
                       :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                                     model/blank-ingredient]
                       :inspirations ["https://a.example" ""]}}
        events [[::events/set-name "Stew"]
                [::events/set-method "Mix"]
                [::events/set-inspiration 0 "https://b.example"]
                [::events/set-ingredient-name 0 "Pepper"]
                [::events/set-ingredient-amount-unit 0 "2 EL"]
                [::events/remove-ingredient 0]
                [::events/discard]]]
    (doseq [event events]
      (is (= db (event-db db event)) (str "expected no-op for " event)))))

(deftest save-event-guards-and-builds-mutation-request
  (testing "no-op when state is not saveable"
    (doseq [status [:saving :loading :not-found :error]]
      (let [db {:status status
                :route {:page :new}
                :form {:name "Soup" :method "Boil" :ingredients [] :inspirations []}
                :baseline {:name "" :method "" :ingredients [] :inspirations []}}]
        (is (= {} (event-effects db [::events/save])))))
    (let [db {:status :idle
              :route {:page :new}
              :form {:name "Soup" :method "Boil" :ingredients [] :inspirations []}
              :baseline {:name "Soup" :method "Boil" :ingredients [] :inspirations []}}]
      (is (= {} (event-effects db [::events/save])))))
  (testing "dirty create builds create mutation and enters saving"
    (let [db {:status :idle
              :route {:page :new}
              :inspirations-online true
              :form {:name "Soup"
                     :method "Boil"
                     :ingredients (model/normalize-ingredients [])
                     :inspirations (model/normalize-inspirations [])}
              :baseline (model/blank-form)}
          effects (event-effects db [::events/save])]
      (is (= :saving (get-in effects [:db :status])))
      (is (= [::re-graph/mutate
              {:query events/create-mutation
               :variables {:input (model/form->input (:form db) {:inspirations-online true})}
               :callback [::events/saved]}]
             (:dispatch effects)))))
  (testing "dirty update includes id and update mutation"
    (let [db {:status :idle
              :route {:page :edit :id "123"}
              :inspirations-online false
              :form {:name "Soup"
                     :method "Boil"
                     :ingredients (model/normalize-ingredients [])
                     :inspirations (model/normalize-inspirations [])}
              :baseline (model/blank-form)}
          effects (event-effects db [::events/save])]
      (is (= events/update-mutation (get-in effects [:dispatch 1 :query])))
      (is (= "123" (get-in effects [:dispatch 1 :variables :id]))))))

(deftest saved-event-create-success-updates-route-baseline-and-replace-effect
  (let [form {:name "Soup"
              :method "Boil"
              :ingredients (model/normalize-ingredients [])
              :inspirations (model/normalize-inspirations [])}
        baseline (model/blank-form)
        db {:status :saving
            :route {:page :new}
            :form form
            :baseline baseline}
        effects (event-effects db [::events/saved
                                   {:response {:data {:createRecipe {:id "321"}}
                                               :errors []}}])
        next-db (:db effects)]
    (is (= :idle (:status next-db)))
    (is (= {:page :edit :id "321"} (:route next-db)))
    (is (= form (:baseline next-db)))
    (is (= {:kind :success :message "Gespeichert"} (:feedback next-db)))
    (is (= "/edit/321" (::events/replace-url effects)))))

(deftest saved-event-validation-errors-preserve-form-and-baseline
  (let [form {:name ""
              :method "Boil"
              :ingredients (model/normalize-ingredients [])
              :inspirations (model/normalize-inspirations [])}
        baseline {:name "Soup"
                  :method "Boil"
                  :ingredients (model/normalize-ingredients [])
                  :inspirations (model/normalize-inspirations [])}
        db {:status :saving
            :route {:page :new}
            :form form
            :baseline baseline}
        name-error-effects (event-effects db [::events/saved
                                              {:response {:data {:createRecipe nil}
                                                          :errors [{:message "Name fehlt"
                                                                    :extensions {:code "required-field"
                                                                                 :field "name"}}]}}])
        name-error-db (:db name-error-effects)
        gql-error-effects (event-effects db [::events/saved
                                             {:response {:data {:createRecipe nil}
                                                         :errors [{:message "Invalid ingredient"}]}}])
        gql-error-db (:db gql-error-effects)]
    (is (= form (:form name-error-db)))
    (is (= baseline (:baseline name-error-db)))
    (is (true? (:name-error? name-error-db)))
    (is (nil? (:feedback name-error-db)))
    (is (= form (:form gql-error-db)))
    (is (= baseline (:baseline gql-error-db)))
    (is (= {:kind :error :message "Invalid ingredient"} (:feedback gql-error-db)))))

(deftest saved-event-update-success-requires-update-recipe-id
  (let [form {:name "Soup updated"
              :method "Boil"
              :ingredients (model/normalize-ingredients [])
              :inspirations (model/normalize-inspirations [])}
        baseline {:name "Soup"
                  :method "Boil"
                  :ingredients (model/normalize-ingredients [])
                  :inspirations (model/normalize-inspirations [])}
        db {:status :saving
            :route {:page :edit :id "123"}
            :form form
            :baseline baseline}
        success-db (:db (event-effects db [::events/saved
                                           {:response {:data {:updateRecipe {:id "123"}}
                                                       :errors []}}]))
        failure-db (:db (event-effects db [::events/saved
                                           {:response {:data {:updateRecipe nil}
                                                       :errors []}}]))]
    (is (= form (:baseline success-db)))
    (is (= {:kind :success :message "Gespeichert"} (:feedback success-db)))
    (is (= baseline (:baseline failure-db)))
    (is (true? (:save-failed? failure-db)))
    (is (= {:kind :error :message "Save failed"} (:feedback failure-db)))))

(deftest discard-restores-baseline-and-clears-feedback
  (let [db {:status :idle
            :form {:name "Modified"
                   :method "Changed"
                   :ingredients (model/normalize-ingredients [])
                   :inspirations (model/normalize-inspirations [])}
            :baseline {:name "Original"
                       :method "Original"
                       :ingredients (model/normalize-ingredients [])
                       :inspirations (model/normalize-inspirations [])}
            :name-error? true
            :save-failed? true
            :feedback {:kind :error :message "x"}}
        next-db (event-db db [::events/discard])]
    (is (= (:baseline db) (:form next-db)))
    (is (false? (:name-error? next-db)))
    (is (false? (:save-failed? next-db)))
    (is (nil? (:feedback next-db)))))

(deftest discard-restores-latest-successful-baseline-after-multiple-saves
  (let [make-form (fn [name]
                    {:name name
                     :method "Boil"
                     :ingredients (model/normalize-ingredients [])
                     :inspirations (model/normalize-inspirations [])})
        initial-form (make-form "Original")
        first-save-form (make-form "First save")
        start-db {:status :saving
                  :route {:page :edit :id "123"}
                  :form first-save-form
                  :baseline initial-form}
        first-saved-db (:db (event-effects start-db [::events/saved
                                                     {:response {:data {:updateRecipe {:id "123"}}
                                                                 :errors []}}]))
        after-second-edit (event-db first-saved-db [::events/set-name "Second save"])
        second-save-effects (event-effects after-second-edit [::events/save])
        second-saving-db (:db second-save-effects)
        second-saved-db (:db (event-effects second-saving-db [::events/saved
                                                              {:response {:data {:updateRecipe {:id "123"}}
                                                                          :errors []}}]))
        after-unsaved-edit (event-db second-saved-db [::events/set-name "Unsaved edit"])
        discarded-db (event-db after-unsaved-edit [::events/discard])]
    (is (= "First save" (get-in first-saved-db [:baseline :name])))
    (is (= :saving (:status second-saving-db)))
    (is (= "Second save" (get-in second-saved-db [:baseline :name])))
    (is (= "Unsaved edit" (get-in after-unsaved-edit [:form :name])))
    (is (= "Second save" (get-in discarded-db [:form :name])))
    (is (= (:baseline second-saved-db) (:form discarded-db)))))
