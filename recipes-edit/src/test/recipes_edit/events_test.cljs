(ns recipes-edit.events-test
  (:require [cljs.test :refer [deftest is]]
            [recipes-edit.events :as events]))

(deftest initialization-preserves-re-graph-state
  (let [re-graph-state {:re-graph {:default {:http {:url "/graphql"}}}}
        initialized (events/initialize-db re-graph-state {:page :new})]
    (is (= (:re-graph re-graph-state) (:re-graph initialized)))
    (is (= :new (get-in initialized [:route :page])))
    (is (= :idle (:status initialized)))))

(deftest normalizes-graphql-response-keys
  (is (= {:data {:createRecipe nil}
          :errors [{:message "Missing field value for name"
                    :extensions {:code "required-field" :field "name"}}]}
         (events/normalize-response
          {"data" {"createRecipe" nil}
           "errors" [{"message" "Missing field value for name"
                      "extensions" {"code" "required-field" "field" "name"}}]}))))