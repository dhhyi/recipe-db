(ns recipes-edit.model-test
  (:require [cljs.test :refer [deftest is testing]]
            [recipes-edit.model :as model]))

(deftest parses-amount-and-unit
  (testing "single numeric word is an amount"
    (is (= ["250" "" false] (model/parse-amount-unit "250"))))
  (testing "single non-numeric word is a unit"
    (is (= ["" "Prise" false] (model/parse-amount-unit "Prise"))))
  (testing "the last word is the unit"
    (is (= ["1 1/2" "EL" false] (model/parse-amount-unit "1 1/2 EL"))))
  (testing "known fused units are split"
    (is (= ["1" "EL" false] (model/parse-amount-unit "1EL"))))
  (testing "the optional marker is detected"
    (is (= ["2" "TL" true] (model/parse-amount-unit "2 TL optional")))))

(deftest normalizes-dynamic-rows
  (is (= [{:amount "2" :unit "EL" :name "Öl" :optional false}
          model/blank-ingredient]
         (model/normalize-ingredients
          [model/blank-ingredient
           {:amount "2" :unit "EL" :name "Öl" :optional false}])))
  (is (= ["https://example.com" ""]
         (model/normalize-inspirations ["" "https://example.com" ""]))))

(deftest builds-graphql-input
  (is (= {:name "Suppe"
          :method nil
          :inspirations ["https://example.com"]
          :ingredients [{:name "Salz" :optional true :unit "Prise"}]}
         (model/form->input
          {:name "Suppe"
           :method ""
           :inspirations ["https://example.com" ""]
           :ingredients [{:amount "" :unit "Prise" :name "Salz" :optional true}
                         model/blank-ingredient]}))))

(deftest classifies-empty-name-errors
  (is (model/empty-name-error?
       {:extensions {:code "BAD_USER_INPUT" :field "name"}}))
  (is (not (model/empty-name-error?
            {:extensions {:code "BAD_USER_INPUT" :field "method"}}))))
