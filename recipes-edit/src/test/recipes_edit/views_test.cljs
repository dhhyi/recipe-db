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

(defn- with-animation-frames [f]
  (let [request (.-requestAnimationFrame js/globalThis)
        cancel (.-cancelAnimationFrame js/globalThis)
        frames (atom {})
        next-id (atom 0)]
    (set! (.-requestAnimationFrame js/globalThis)
          (fn [callback]
            (let [id (swap! next-id inc)]
              (swap! frames assoc id callback)
              id)))
    (set! (.-cancelAnimationFrame js/globalThis)
          (fn [id] (swap! frames dissoc id)))
    (try
      (f frames (fn []
                  (let [callbacks (vals @frames)]
                    (reset! frames {})
                    (doseq [callback callbacks] (callback)))))
      (finally
        (set! (.-requestAnimationFrame js/globalThis) request)
        (set! (.-cancelAnimationFrame js/globalThis) cancel)))))

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
      (with-animation-frames
        (fn [frames flush!]
          (let [lifecycle (with-redefs [r/create-class (fn
                                                         ([spec] spec)
                                                         ([spec _] spec))]
                            (#'views/auto-sizing-textarea))
                textarea #js {:style #js {} :scrollHeight 100 :isConnected true}
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
            (testing "deferred controlled value writes are measured in the next frame"
              (is (= 1 (count @frames)) "coalesce pending measurements")
              (set! (.-scrollHeight textarea) 600)
              (flush!)
              (is (= "602px" (.. textarea -style -height)))
              (is (empty? @frames)))
            (testing "detached elements are not measured"
              ((:component-did-update lifecycle) nil)
              (set! (.-isConnected textarea) false)
              (set! (.-scrollHeight textarea) 800)
              (flush!)
              (is (= "602px" (.. textarea -style -height))))
            (testing "unmount cancels scheduled measurements"
              ((:component-did-update lifecycle) nil)
              ((:component-will-unmount lifecycle) nil)
              (is (empty? @frames))
              (ref nil)
              (flush!))))))))
