(ns recipes-edit.model
  (:require [clojure.string :as str]))

(def known-units
  #{"el" "tl" "ml" "l" "g" "kg" "prise" "stück" "pck" "dose" "bund" "zehe" "zehen"})

(def blank-ingredient
  {:amount "" :unit "" :name "" :optional false})

(defn blank-ingredient? [{:keys [amount unit name]}]
  (every? str/blank? [amount unit name]))

(defn normalize-ingredients [ingredients]
  (conj (vec (remove blank-ingredient? ingredients)) blank-ingredient))

(defn normalize-inspirations [inspirations]
  (conj (vec (remove str/blank? inspirations)) ""))

(defn blank-form []
  {:name ""
   :method ""
   :inspirations (normalize-inspirations [])
   :ingredients (normalize-ingredients [])})

(defn recipe->form [recipe]
  {:name (:name recipe)
   :method (or (:method recipe) "")
   :inspirations (normalize-inspirations (map :url (or (:inspirations recipe) [])))
   :ingredients (normalize-ingredients
                 (map #(merge blank-ingredient %)
                      (or (:ingredients recipe) [])))})

(defn- split-fused-amount-unit [word]
  (when-let [[_ amount unit] (re-matches #"([0-9.,/]+)(.+)" word)]
    (when (contains? known-units (str/lower-case unit))
      [amount unit])))

(defn parse-amount-unit [text]
  (let [words (str/split (str/trim text) #"\s+")
        optional? (some #(= "optional" (str/lower-case %)) words)
        words (->> words
                   (remove #(= "optional" (str/lower-case %)))
                   (mapcat #(or (split-fused-amount-unit %) [%]))
                   vec)]
    (cond
      (empty? words) ["" "" (boolean optional?)]
      (= 1 (count words)) (if (re-find #"\d" (first words))
                            [(first words) "" (boolean optional?)]
                            ["" (first words) (boolean optional?)])
      :else [(str/join " " (butlast words)) (last words) (boolean optional?)])))

(defn format-amount-unit [{:keys [amount unit optional]}]
  (str/join " " (cond-> []
                  (seq amount) (conj amount)
                  (seq unit) (conj unit)
                  optional (conj "optional"))))

(defn form->input [{:keys [name method inspirations ingredients]}]
  {:name name
   :method (when (seq method) method)
   :inspirations (vec (remove empty? inspirations))
   :ingredients (->> ingredients
                     (remove blank-ingredient?)
                     (mapv (fn [{:keys [amount unit name optional]}]
                             (cond-> {:name name :optional optional}
                               (seq amount) (assoc :amount amount)
                               (seq unit) (assoc :unit unit)))))})

(defn empty-name-error? [{:keys [extensions]}]
  (and (= "required-field" (:code extensions))
       (= "name" (:field extensions))))

(defn error-message [errors]
  (str/join "; " (keep :message errors)))
