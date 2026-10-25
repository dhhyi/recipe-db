(ns recipes-edit.views-test
  (:require [cljs.test :refer [deftest is testing]]
            [reagent.core :as r]
            [recipes-edit.views :as views]))

(defn- with-computed-style [style f]
  (let [window (.-window js/globalThis)]
    (set! (.-window js/globalThis) #js {:getComputedStyle (fn [_] style)})
    (try
      (f)
      (finally
        (set! (.-window js/globalThis) window)))))

(deftest textarea-height-accounts-for-box-sizing
  (doseq [[box-sizing expected] [["border-box" "103px"]
                                 ["content-box" "80px"]]]
    (testing box-sizing
      (with-computed-style
        #js {:boxSizing box-sizing
             :borderTopWidth "1.5px"
             :borderBottomWidth "1.5px"
             :paddingTop "8px"
             :paddingBottom "12px"}
        (fn []
          (let [textarea #js {:style #js {:height "400px"}}]
            (js/Object.defineProperty
             textarea "scrollHeight"
             #js {:get (fn []
                         (is (= "auto" (.. textarea -style -height))
                             "clear the old height before measuring to allow shrinking")
                         100)})
            (#'views/resize-textarea! textarea)
            (is (= expected (.. textarea -style -height)))))))))

(deftest textarea-resizes-after-controlled-value-updates
  (with-computed-style
    #js {:boxSizing "border-box"
         :borderTopWidth "1px"
         :borderBottomWidth "1px"}
    (fn []
      (let [lifecycle (with-redefs [r/create-class (fn
                                                     ([spec] spec)
                                                     ([spec _] spec))]
                        (#'views/auto-sizing-textarea))
            textarea #js {:style #js {} :scrollHeight 100}
            [_ props] ((:reagent-render lifecycle) {:value "Persisted method"})
            ref (:ref props)]
        (ref textarea)
        ((:component-did-mount lifecycle) nil)
        (is (= "102px" (.. textarea -style -height)))
        (testing "a programmatic update does not need another ref or change event"
          (set! (.-scrollHeight textarea) 600)
          ((:component-did-update lifecycle) nil)
          (is (= "602px" (.. textarea -style -height))))
        (testing "shorter restored values shrink the textarea"
          (set! (.-scrollHeight textarea) 100)
          ((:component-did-update lifecycle) nil)
          (is (= "102px" (.. textarea -style -height))))
        (testing "unmounted refs are safe"
          (ref nil)
          ((:component-did-update lifecycle) nil))))))
