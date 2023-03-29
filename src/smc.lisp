(defpackage #:permo (:use #:gt))
(in-package #:permo)

(declaim (optimize (speed 1) (debug 3)))

;;;; Types

;; Short-hand types.
;; Leaky abstractions: no secret what the concrete representations are.
(deftype R   (&rest args) "Real number."            `(double-float ,@args))
(deftype R*  ()           "Real vector."            '(simple-array R  (*)))
(deftype R** ()           "Vector of real vectors." '(simple-array R* (*)))
(deftype P   ()           "Probability."            '(R 0d0 1d0))
(deftype L   ()           "Log-likelihood."         '(R * #.(log 1)))


;;;; DEFMODEL: Model definition DSL (WIP)

(defmacro defmodel (name arglist &body log-likelihood)
  (destructuring-bind (args paramspecs) (split-sequence '&param arglist)
    #+nil (when (null args)       (error "DEFMODEL requires at least one argument."))
    (when (null paramspecs) (error "DEFMODEL requires at least one parameter."))
    (loop for (name min max) in paramspecs
          unless (and (symbolp name) (typep min 'double-float) (typep max 'double-float))
            do (error "Invalid parameter: ~a" (list name min max)))
    (flet ((name (suffix name)
             (make-symbol (concatenate 'string (string name) "." suffix))))
      (let* ((doc (if (stringp (first log-likelihood))
                      (pop log-likelihood)
                      ()))
             #+nil (weights (make-symbol "WEIGHTS"))
             (params         (mapcar #'first paramspecs))
             (ranges         (mapcar #'rest paramspecs))
             (vector.names   (mapcar (compose #'make-symbol #'symbol-name) params))
             (proposal.names (mapcar (curry #'name "P") params))
             (param.scales   (loop for (start end) in ranges
                                   ;; About three standard deviations between
                                   ;; particles on each parameter dimension.
                                   ;; Give them a chance to jitter to neighbors.
                                   collect (/ (abs (- end start)) (length params) 3))))
        `(defun ,name (observations &key (n-particles 100) (steps 100) (jitter-scales '(0.01d0 0.35d0 1d0)))
           ,@(ensure-list doc)
           (let (,@(loop for name in vector.names
                         for (min max) in ranges
                         collect `(,name (init-parameter-vector n-particles ,min ,max))))
             (labels ((log-likelihood (,@params ,@args)
                        ,@log-likelihood)
                      (particle-log-likelihood (i ,@args)
                        (log-likelihood ,@(loop for vector in vector.names
                                                collect `(aref ,vector i))
                                        ,@args))
                      (respawn! (parents)
                        (reorder! parents ,@vector.names))
                      (jitter! (metropolis-accept?)
                        (loop for jitter in jitter-scales do
                          (loop for i below n-particles
                                ,@(loop for param in params
                                        for vector in vector.names
                                        append `(for ,param = (aref ,vector i)))
                                for ll.old = (partial #'log-likelihood ,@params)
                                ,@(loop for proposal.name in proposal.names
                                        for param in params
                                        for scale in param.scales
                                        append `(for ,proposal.name = (+ ,param (* (gaussian-random) jitter (/ ,scale (expt n-particles ,(/ 1 (length params))))))))
                                for ll.new = (partial #'log-likelihood ,@proposal.names)
                                when (funcall metropolis-accept? ll.old ll.new)
                                  do (setf ,@(loop for vector in vector.names
                                                   for proposal in proposal.names
                                                   append `((aref ,vector i) ,proposal)))))))
               #+debug (declare (inline (smc/likelihood-tempering)))
               (values
                (smc/likelihood-tempering n-particles observations
                                          :log-likelihood #'particle-log-likelihood
                                          :respawn! #'respawn!
                                          :jitter! #'jitter!
                                          :temp-step (/ 1d0 steps))
                (dict ,@(loop for param in params
                              for vector in vector.names
                              collect (list 'quote param)
                              collect vector)))
                                         )))))))

(defun init-parameter-vector (length min max)
  (loop with vec = (make-array (list length) :element-type 'R)
        for i below length
        do (setf (aref vec i) (lerp (/ i length) min max))
        finally (return vec)))

(defun reorder! (indices &rest arrays)
  "Atomically overwrite ARRAY[a][i] with ARRAY[a][indices[i]]."
  (loop for a in arrays
        for original = (copy-array a)
        do (loop for i from 0
                 for p in indices
                 do (setf (aref a i) (aref original p)))))

(defmodel line (x y &param
                  (m -10d0 10d0)
                  (c -10d0 10d0)
                  (σ #.double-float-epsilon 5d0))
  "Linear relationship between X and Y with Gaussian noise of constant scale:
     y ~ m*x + c + N(0,σ)
   Infers parameters M (gradient), C (intercept), and σ (standard deviation.)"
  (gaussian-log-likelihood (+ c (* m x)) σ y))

(defmodel gaussian (x &param
                      (μ -10d0 10d0)
                      (σ #.double-float-epsilon 10d0))
  "Gaussian distribution:
     x ~ N(μ,σ)
   Infers mean and standard deviation."
  (gaussian-log-likelihood μ σ x))

(defmodel pi-circle (&param (x -1d0 1d0) (y -1d0 1d0))
  "Estimate Pi via marginal likelihood."
  ;; XXX: This model starts with a reasonable estimate which then approaches
  ;;      zero as the number of likelihood tempering steps increases.
  ;;      Why?
  (log (if (< (sqrt (+ (* x x) (* y y))) 1d0)
           4d0
           0.001d0)))


;;;; Sequential Monte Carlo (Particle Filter) sampler

(defun smc (&key log-mean-likelihood resample! rejuvenate! step! weight!)
  "Run a callback-driven Sequential Monte Carlo particle filter simulation.
   Return the log marginal likelihood estimate.

   Callbacks:
   (WEIGHT!)
     Calculate and associate weights with particles.
   (LOG-MEAN-LIKELIHOOD) ⇒ double-float
     Return the log mean likelihood for all particles.
   (RESAMPLE!)
     Resample weighted particles into equally-weighted replacements.
   (REJUVENATE!)
     Jitter particles without changing their distribution.
   (STEP!) ⇒ boolean
     Advance the simulation. Return true on success, false on a completed simulation."
  (loop do (funcall weight!)
        sum (funcall log-mean-likelihood)
        while (funcall step!)
        do (funcall resample!)
           (funcall rejuvenate!)))

(defun smc/likelihood-tempering (n-particles observations
                                    &key
                                      log-likelihood respawn! jitter!
                                      (temp-step 0.01d0))
  "Run a callback-driven Sequential Monte Carlo simulation using likelihood tempering.

   Callbacks:
   (PARTICLE-LOG-LIKELIHOOD particle datum) ⇒ log-likelihood
     Return log-likelihood of DATUM given the parameters of PARTICLE.
   (RESPAWN! parent-indices)
     Replace particles by overwriting them with the resampled PARENT-INDICES.
   (JITTER! metropolis-accept?)
     Rejuvenate particles by proposing moves to the function
       (METROPOLIS-ACCEPT? OLD-LOG-LIKELIHOOD-FN NEW-LOG-LIKELIHOOD-FN)
     which compares the likelihood ratios and returns true if the move is accepted."
  (local
    (def temp 0d0)
    (def prev-temp temp)
    (def log-weights (make-array (list n-particles) :element-type 'double-float))

    (defun tempered-log-likelihood (log-likelihood-fn &optional (temp temp))
      "Return the log-likelihood tempered with the current temperature."
      (handler-case
          (loop for o in (or observations (list '()))
                summing (apply log-likelihood-fn o) into ll
                finally (return (logexpt ll temp)))
        (floating-point-overflow () sb-ext:double-float-negative-infinity)))
    (defun log-mean-likelihood ()
      "Return the log mean likelihood of all particles."
      (log/ (logsumexp log-weights) (log n-particles)))
    (defun weight! ()
      "Calculate and set the weight of each particle."
      (loop for i below n-particles
            do (let (#+nil (old (aref log-weights i)))
                 (setf (aref log-weights i)
                       (lret ((r (log/ (tempered-log-likelihood (partial log-likelihood i))
                                       (tempered-log-likelihood (partial log-likelihood i) prev-temp)))
                             #+nil (format t "~&r = ~8f~%" r)))))))
    (defun resample! ()
      "Replace old particles by resampling them into new ones."
      (funcall respawn! (systematic-resample log-weights)))
    (defun step! ()
      "Advance the tempering schedule (unless finished.)"
      (setf prev-temp temp)
      (and (< temp 1d0)
           (setf temp (min 1d0 (+ temp temp-step)))))
    (defun metropolis-accept? (old-log-likelihood new-log-likelihood)
      (< (log (random 1d0)) (log/ (tempered-log-likelihood new-log-likelihood)
                                  (tempered-log-likelihood old-log-likelihood))))
    (defun rejuvenate! ()
      (funcall jitter! #'metropolis-accept?))

    (smc :log-mean-likelihood #'log-mean-likelihood
         :resample! #'resample!
         :rejuvenate! #'rejuvenate!
         :step! #'step!
         :weight! #'weight!)))

;; Helpers for arithmetic in the log domain.
;; Used sparingly when it helps to clarify intent.
(defun log/ (&rest numbers) (apply #'- numbers))
;;(defun log* (&rest numbers) (apply #'+ numbers))
(defun logexpt (a b)
  "Raise A (a log-domain number) to the power B (which is not log!)"
  (* a b))

;;;; Systematic resampling

(-> systematic-resample (vector) list)
(defun systematic-resample (log-weights)
  (values
   (systematic-resample/normalized (loop with normalizer = (logsumexp log-weights)
                                         for lw across log-weights
                                         collect (exp (- lw normalizer))))))

(-> systematic-resample/normalized (list) list)
(defun systematic-resample/normalized (weights)
  (loop with n = (length weights)
        with cdf = (coerce (loop for weight in weights
                                 sum weight into cumulative
                                 collect cumulative)
                           'vector)
        with index = 0
        repeat n
        ;; Pick a starting offset into the CDF
        for u = (random (/ 1d0 n)) then (+ u (/ 1d0 n))
        ;; Step forward through the CDF
        do (loop while (and (> u (aref cdf (min index (1- n))))) do (incf index))
           (minf index (1- n))
        collect (min index (1- n))))

;;;; Probability distributions and utilities

(defun gaussian-log-likelihood (μ σ x)
  "Return the likelihood of Normal(μ,σ) at X."
  (if (plusp σ)
      (let ((z (/ (- x μ) σ)))
        (- 0
           (log σ)
           (/ (+ (* z z) (log (* pi 2))) 2)))
      most-negative-double-float))

(-> logsumexp (R*) R)
(defun logsumexp (vec)
  ;; utility for numerically stable addition of log quantities e.g. for normalization
  ;; see e.g. https://gregorygundersen.com/blog/2020/02/09/log-sum-exp/
  (let ((max (reduce #'max vec)))
    (if (sb-ext:float-infinity-p max)
        sb-ext:double-float-negative-infinity
        (loop for x across vec
              summing (if (sb-ext:float-infinity-p x) 0d0 (exp (- x max))) into acc
              finally (return (+ max (log acc)))))))
