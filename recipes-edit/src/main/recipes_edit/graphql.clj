(ns recipes-edit.graphql
  (:require [clojure.string :as str])
  (:import [graphql Scalars]
           [graphql.language AstPrinter OperationDefinition]
           [graphql.parser Parser]
           [graphql.schema GraphQLScalarType]
           [graphql.schema.idl RuntimeWiring SchemaGenerator SchemaParser]
           [graphql.validation Validator]
           [java.util Locale]))

(defn- scalar [name]
  (-> (GraphQLScalarType/newScalar)
      (.name name)
      (.coercing (.getCoercing Scalars/GraphQLString))
      (.build)))

(defn- schema [schema-source]
  (let [registry (.parse (SchemaParser.) schema-source)
        wiring (-> (RuntimeWiring/newRuntimeWiring)
                   (.scalar (scalar "StringOrInt"))
                   (.scalar (scalar "Upload"))
                   (.build))]
    (.makeExecutableSchema (SchemaGenerator.) registry wiring)))

(defn validate-operations! [schema-source operations-source]
  (let [document (.parseDocument (Parser.) operations-source)
        errors (.validateDocument (Validator.)
                                  (schema schema-source)
                                  document
                                  (Locale/getDefault))]
    (when (seq errors)
      (throw (ex-info (str "Invalid GraphQL operations:\n"
                           (str/join "\n" (map str errors)))
                      {:errors errors})))
    document))

(defn operation-source [operation-name]
  (let [document (validate-operations! (slurp "recipe-db.graphqls")
                                       (slurp "operations.graphql"))]
    (if-let [operation (some #(when (and (instance? OperationDefinition %)
                                         (= operation-name (.getName ^OperationDefinition %)))
                                %)
                             (.getDefinitions document))]
      (AstPrinter/printAst operation)
      (throw (ex-info (str "GraphQL operation not found: " operation-name)
                      {:operation-name operation-name})))))

(defmacro operation [operation-name]
  (operation-source operation-name))
