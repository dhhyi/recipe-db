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
    (is (= ["2" "TL" true] (model/parse-amount-unit "2 TL optional"))))
  (testing "optional marker alone"
    (is (= ["" "" true] (model/parse-amount-unit "optional")))))

(deftest normalizes-dynamic-rows
  (is (= [{:amount "2" :unit "EL" :name "Öl" :optional false}
          model/blank-ingredient]
         (model/normalize-ingredients
          [model/blank-ingredient
           {:amount "2" :unit "EL" :name "Öl" :optional false}])))
  (is (= ["https://example.com" ""]
         (model/normalize-inspirations ["" "https://example.com" ""]))))

(deftest builds-graphql-input
  (testing "includes inspirations when online or default"
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
  (testing "omits inspirations when inspirations are offline"
    (is (= {:name "Suppe"
            :method nil
            :ingredients [{:name "Salz" :optional true :unit "Prise"}]}
           (model/form->input
            {:name "Suppe"
             :method ""
             :inspirations ["https://example.com" ""]
             :ingredients [{:amount "" :unit "Prise" :name "Salz" :optional true}
                           model/blank-ingredient]}
            {:inspirations-online false})))))

(deftest classifies-empty-name-errors
  (is (model/empty-name-error?
       {:extensions {:code "required-field" :field "name"}}))
  (is (not (model/empty-name-error?
            {:extensions {:code "required-field" :field "method"}}))))

(deftest dirty-compares-forms
  (testing "identical forms are not dirty"
    (let [form {:name "Soup" :method "Mix" :ingredients [] :inspirations []}]
      (is (not (model/dirty? form form)))))

  (testing "different names are dirty"
    (let [form1 {:name "Soup" :method "Mix" :ingredients [] :inspirations []}
          form2 {:name "Stew" :method "Mix" :ingredients [] :inspirations []}]
      (is (model/dirty? form1 form2))))

  (testing "different methods are dirty"
    (let [form1 {:name "Soup" :method "Mix" :ingredients [] :inspirations []}
          form2 {:name "Soup" :method "Blend" :ingredients [] :inspirations []}]
      (is (model/dirty? form1 form2))))

  (testing "ignores trailing blank ingredient rows"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}]
                 :inspirations []}]
      (is (not (model/dirty? form1 form2)))))

  (testing "graphql nil amount/unit normalized to blank string"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount nil :unit nil :optional false}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "" :unit "" :optional false}
                               model/blank-ingredient]
                 :inspirations []}]
      (is (not (model/dirty? form1 form2)))))

  (testing "graphql loaded ingredient edited then exact undo is clean"
    (let [baseline (model/recipe->form {:name "Soup"
                                        :method "Boil"
                                        :ingredients [{:name "Salt" :amount nil :unit nil :optional false}]})
          form-after-edit {:name "Soup" :method "Boil"
                           :ingredients [{:name "Salt" :amount "2" :unit "tl" :optional false}
                                         model/blank-ingredient]
                           :inspirations (model/normalize-inspirations [])}
          form-after-undo {:name "Soup" :method "Boil"
                           :ingredients [{:name "Salt" :amount "" :unit "" :optional false}
                                         model/blank-ingredient]
                           :inspirations (model/normalize-inspirations [])}]
      (is (model/dirty? form-after-edit baseline))
      (is (not (model/dirty? form-after-undo baseline)))))

  (testing "nil optional normalized to false"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional nil}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                               model/blank-ingredient]
                 :inspirations []}]
      (is (not (model/dirty? form1 form2)))))

  (testing "ignores trailing blank inspiration rows"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients []
                 :inspirations ["https://example.com" ""]}
          form2 {:name "Soup" :method "Mix"
                 :ingredients []
                 :inspirations ["https://example.com"]}]
      (is (not (model/dirty? form1 form2)))))

  (testing "different ingredients are dirty"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Pepper" :amount "1" :unit "tl" :optional false}
                               model/blank-ingredient]
                 :inspirations []}]
      (is (model/dirty? form1 form2))))

  (testing "different inspirations are dirty"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients []
                 :inspirations ["https://a.com" ""]}
          form2 {:name "Soup" :method "Mix"
                 :ingredients []
                 :inspirations ["https://b.com" ""]}]
      (is (model/dirty? form1 form2))))

  (testing "empty optional field differs from present"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional true}
                               model/blank-ingredient]
                 :inspirations []}]
      (is (model/dirty? form1 form2))))

  (testing "preserves optional parsing semantics"
    (let [form1 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "" :unit "prise" :optional false}
                               model/blank-ingredient]
                 :inspirations []}
          form2 {:name "Soup" :method "Mix"
                 :ingredients [{:name "Salt" :amount "" :unit "prise" :optional true}
                               model/blank-ingredient]
                 :inspirations []}]
      (is (model/dirty? form1 form2)))))

(deftest recipe-to-form-round-trip
  (testing "converts recipe to form and back"
    (let [recipe {:name "Soup"
                  :method "Boil"
                  :ingredients [{:name "Salt" :amount "1" :unit "tl" :optional false}
                                {:name "Pepper" :amount "2" :unit "tl" :optional true}]
                  :inspirations [{:url "https://a.com"}
                                 {:url "https://b.com"}]}
          form (model/recipe->form recipe)
          input (model/form->input form {:inspirations-online true})]
      (is (= "Soup" (:name input)))
      (is (= "Boil" (:method input)))
      (is (= 2 (count (:ingredients input))))
      (is (= 2 (count (:inspirations input)))))))
