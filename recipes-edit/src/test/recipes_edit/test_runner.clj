(ns recipes-edit.test-runner
  (:require [clojure.test :as test]
            [recipes-edit.graphql-test]))

(defn -main []
  (let [{:keys [fail error]} (test/run-tests 'recipes-edit.graphql-test)]
    (when (pos? (+ fail error))
      (System/exit 1))))
