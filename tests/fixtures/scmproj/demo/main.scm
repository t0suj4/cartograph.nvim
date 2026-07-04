(define-module (demo main)
  #:use-module (demo util))

(define (run n)
  (let loop ((k n) (acc 0))
    (if (zero? k) acc
        (loop (- k 1) (+ acc (step k))))))

(display (run 5))
