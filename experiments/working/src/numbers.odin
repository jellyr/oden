(pkg numbers)

(define (plus x y)
  (+ (x : int) (y : int)))

(define plus-1
  ((plus 1) : (int -> int)))

;; not working
;;(define annotated-float (1.2 : float))


;; not working
;;(define annotated-float-add ((+ 1 2) : float))
