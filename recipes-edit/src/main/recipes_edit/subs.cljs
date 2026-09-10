(ns recipes-edit.subs
  (:require [re-frame.core :as rf]))

(rf/reg-sub
 ::state
 (fn [db _]
   db))
