(ns recipes-edit.graphql-test
  (:require [clojure.test :refer [deftest is testing]]
            [recipes-edit.graphql :as graphql]))

(deftest extracts-validated-operations
  (doseq [operation-name ["RecipeById" "CreateRecipe" "UpdateRecipe"]]
    (testing operation-name
      (is (re-find (re-pattern operation-name)
                   (graphql/operation-source operation-name))))))

(deftest rejects-an-unknown-operation
  (is (thrown-with-msg? clojure.lang.ExceptionInfo
                        #"GraphQL operation not found"
                        (graphql/operation-source "MissingOperation"))))

(deftest rejects-schema-drift
  (is (thrown-with-msg?
       clojure.lang.ExceptionInfo
       #"Invalid GraphQL operations"
       (graphql/validate-operations!
        (slurp "recipe-db.graphqls")
        "query Broken { recipe(id: \"1\") { missingField } }"))))
