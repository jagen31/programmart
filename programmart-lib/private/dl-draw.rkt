#lang racket/base

;; Draw a scribble "display list" (see scribble-preview.rkt) into a
;; `bitmap%`, using `racket/draw` only -- no `racket/gui`, so it is safe to
;; run at rewrite time and in any process.  This is the browser-free way to
;; get a picture of a program: `doc->display-list` gives the structure, and
;; this lays it out (word wrap, alignment, fonts, per-section background
;; bands, foreground colours, embedded score/slide PNGs) and paints it into
;; a bitmap sized exactly to its content.
;;
;; Everything is measured at a `scale` factor so the raster stays crisp
;; when it is later warped / zoomed onto a shape's face.
;;
;;   BLOCK ::= (heading DEPTH ALIGN SPAN ...) | (para ALIGN SPAN ...)
;;           | (nested BG FG BLOCK ...) | (items BULLET (BLOCK ...) ...)
;;           | (table (CELL ...) ...) | (rule)
;;   SPAN  ::= (t STR BOLD? ITALIC? TT? COLOR) | (img PATH SCALE)
;;           | (imgb BYTES SCALE) | (br)

(require racket/class
         racket/draw
         racket/list
         racket/string)

(provide display-list->bitmap
         display-list->png)

;; ---------------------------------------------------------------------------
;; fonts and colours
;; ---------------------------------------------------------------------------

(define (mk-font size bold? italic? tt?)
  (make-object font%
    (max 1 (inexact->exact (round size)))
    (if tt? 'modern 'swiss)                 ; sans body, monospace code
    (if italic? 'italic 'normal)
    (if bold? 'bold 'normal)))

(define (->color c)
  (cond
    [(not c) #f]
    [(is-a? c color%) c]
    [(and (string? c) (regexp-match #px"^#([0-9a-fA-F]{6})$" c))
     => (lambda (m)
          (define h (cadr m))
          (define (b i) (string->number (substring h i (+ i 2)) 16))
          (make-object color% (b 0) (b 2) (b 4)))]
    [(and (string? c) (regexp-match #px"^#([0-9a-fA-F]{3})$" c))
     => (lambda (m)
          (define h (cadr m))
          (define (b i) (* 17 (string->number (substring h i (+ i 1)) 16)))
          (make-object color% (b 0) (b 1) (b 2)))]
    [(string? c) (send the-color-database find-color c)]
    [else #f]))

(define black (make-object color% 17 17 17))

;; ---------------------------------------------------------------------------
;; images
;; ---------------------------------------------------------------------------

(define (load-bitmap src)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (cond
      [(bytes? src) (read-bitmap (open-input-bytes src) 'png/alpha)]
      [(and (string? src) (file-exists? src)) (read-bitmap src)]
      [(path? src) (read-bitmap src)]
      [else #f])))

;; scale a bitmap to a target width (never upscale past its natural size *
;; scale), returning a fresh bitmap
(define (scale-bitmap bmp target-w)
  (define w (send bmp get-width))
  (define h (send bmp get-height))
  (define s (/ target-w (max 1 w)))
  (cond
    [(and (> s 0.99) (< s 1.01)) bmp]
    [else
     (define nw (max 1 (inexact->exact (round (* w s)))))
     (define nh (max 1 (inexact->exact (round (* h s)))))
     (define out (make-bitmap nw nh))
     (define dc (new bitmap-dc% [bitmap out]))
     (send dc set-smoothing 'smoothed)
     (send dc set-scale s s)
     (send dc draw-bitmap bmp 0 0)
     (send dc set-bitmap #f)
     out]))

;; ---------------------------------------------------------------------------
;; tokens (a flowable atom)
;; ---------------------------------------------------------------------------

(struct tok (kind str font color w h bmp) #:transparent)
;; kind: 'word | 'space | 'img | 'break

(define (measure-dc) (new bitmap-dc% [bitmap (make-bitmap 1 1)]))

;; spans -> tokens, measured on `mdc`.  `fg` is the inherited foreground;
;; a span's own colour overrides it.  `content-w` bounds inline images.
(define (spans->tokens mdc spans size fg force-bold? content-w)
  (append*
   (for/list ([s (in-list spans)])
     (case (car s)
       [(t)
        (define str (cadr s))
        (define f (mk-font size (or force-bold? (caddr s)) (cadddr s) (list-ref s 4)))
        (define col (or (->color (list-ref s 5)) fg black))
        (send mdc set-font f)
        (define-values (sw sh sa sd) (send mdc get-text-extent " "))
        (define words (regexp-match* #px"\\S+" str))
        (add-between
         (for/list ([w (in-list words)])
           (define-values (tw th ta td) (send mdc get-text-extent w))
           (tok 'word w f col tw th #f))
         (tok 'space " " f col sw sh #f))]
       [(img imgb)
        (define raw (load-bitmap (cadr s)))
        (cond
          [raw
           (define nat (* (send raw get-width) (caddr s)))
           (define bmp (scale-bitmap raw (min nat content-w)))
           (list (tok 'img #f #f #f (send bmp get-width) (send bmp get-height) bmp))]
          [else
           (define f (mk-font size #f #t #f))
           (send mdc set-font f)
           (define m "[missing image]")
           (define-values (tw th ta td) (send mdc get-text-extent m))
           (list (tok 'word m f (make-object color% 200 0 0) tw th #f))])]
       [(br) (list (tok 'break #f #f #f 0 0 #f))]
       [else '()]))))

;; greedily break tokens into lines that fit `w`; returns list of lines,
;; each a list of tokens (leading/trailing spaces trimmed)
(define (break-lines toks w)
  (define lines '())
  (define cur '())          ; reversed
  (define cur-w 0.0)
  (define (flush!)
    (set! lines (cons (reverse (drop-spaces cur)) lines))
    (set! cur '()) (set! cur-w 0.0))
  (define (drop-spaces rev)  ; trim trailing (head of reversed) spaces
    (cond [(and (pair? rev) (eq? 'space (tok-kind (car rev)))) (drop-spaces (cdr rev))]
          [else rev]))
  (for ([t (in-list toks)])
    (case (tok-kind t)
      [(break) (flush!)]
      [(space)
       (unless (null? cur)          ; no leading spaces
         (set! cur (cons t cur)) (set! cur-w (+ cur-w (tok-w t))))]
      [else
       (when (and (pair? cur) (> (+ cur-w (tok-w t)) w))
         (flush!))
       (set! cur (cons t cur)) (set! cur-w (+ cur-w (tok-w t)))]))
  (unless (null? cur) (flush!))
  (reverse lines))

(define (line-width ln) (for/sum ([t (in-list ln)]) (tok-w t)))
(define (line-height ln)
  (for/fold ([m 0.0]) ([t (in-list ln)]) (max m (tok-h t))))

;; ---------------------------------------------------------------------------
;; layout -> a list of paint ops + the total height
;;
;; op ::= (list 'text x y str font color)
;;      | (list 'img  x y bmp)
;;      | (list 'band x y w h color)      ; painted behind everything
;;      | (list 'rule x y w h)
;; ---------------------------------------------------------------------------

(define BASE 13.0)
(define LINE-GAP 0.32)         ; extra leading, * font size
(define PARA-GAP 0.55)         ; between blocks, * BASE
(define HEAD-SCALES (vector 1.9 1.5 1.25 1.1))
(define NEST-PAD 0.85)         ; * BASE
(define NEST-MARGIN 0.5)       ; * BASE

(define (layout blocks page-w scale)
  (define mdc (measure-dc))
  (define pad (* 18 scale))
  (define ops '())
  (define bands '())
  (define (op! o) (set! ops (cons o ops)))
  (define (band! o) (set! bands (cons o bands)))
  (define base (* BASE scale))

  ;; flow a run of spans at (x,y) within width w; return the new y
  (define (flow-spans spans x y w size align fg force-bold?)
    (define toks (spans->tokens mdc spans size fg force-bold? w))
    (define lines (break-lines toks w))
    (for/fold ([y y]) ([ln (in-list lines)])
      (define lw (line-width ln))
      (define lh (max size (line-height ln)))
      (define x0 (case align
                   [(center) (+ x (max 0 (/ (- w lw) 2)))]
                   [(right)  (+ x (max 0 (- w lw)))]
                   [else x]))
      (let place ([items ln] [cx x0])
        (unless (null? items)
          (define t (car items))
          (case (tok-kind t)
            [(word) (op! (list 'text cx (+ y (/ (- lh (tok-h t)) 2)) (tok-str t) (tok-font t) (tok-color t)))]
            [(img)  (op! (list 'img cx (+ y (/ (- lh (tok-h t)) 2)) (tok-bmp t)))]
            [else (void)])
          (place (cdr items) (+ cx (tok-w t)))))
      (+ y lh (* LINE-GAP size))))

  ;; lay a list of blocks; return new y
  (define (blocks-y bs x y w fg)
    (for/fold ([y y]) ([b (in-list bs)] [i (in-naturals)])
      (define y* (if (positive? i) (+ y (* PARA-GAP base)) y))
      (block-y b x y* w fg)))

  (define (block-y b x y w fg)
    (case (car b)
      [(heading)
       (define depth (cadr b))
       (define sc (if (< depth (vector-length HEAD-SCALES)) (vector-ref HEAD-SCALES depth) 1.0))
       (flow-spans (cdddr b) x y w (* base sc) (caddr b) fg #t)]
      [(para)
       (flow-spans (cddr b) x y w base (cadr b) fg #f)]
      [(nested)
       (define bg (->color (cadr b)))
       (define fg* (or (->color (caddr b)) fg))
       (define p (* NEST-PAD base))
       (define top (+ y (* NEST-MARGIN base)))
       (define inner-y (blocks-y (cdddr b) (+ x p) (+ top p) (- w (* 2 p)) fg*))
       (define bottom (+ inner-y p))
       (when bg (band! (list 'band x top w (- bottom top) bg)))
       (+ bottom (* NEST-MARGIN base))]
      [(items)
       (define ordered? (eq? 'ordered (cadr b)))
       (define bw (* base 1.4))
       (for/fold ([y y]) ([item (in-list (cddr b))] [n (in-naturals 1)])
         (define y* (if (> n 1) (+ y (* 0.2 base)) y))
         (op! (list 'text x y* (if ordered? (format "~a." n) "•") (mk-font base #f #f #f) (or fg black)))
         (blocks-y item (+ x bw) y* (- w bw) fg))]
      [(table)
       ;; lay each row's cells as columns of equal share
       (for/fold ([y y]) ([row (in-list (cdr b))])
         (define cells (filter (lambda (x) (not (eq? 'cont x))) row))
         (define n (max 1 (length cells)))
         (define cw (/ w n))
         (define ys
           (for/list ([cell (in-list cells)] [k (in-naturals)])
             (blocks-y cell (+ x (* k cw)) y (- cw (* 0.4 base)) fg)))
         (apply max (cons y ys)))]
      [(rule)
       (op! (list 'rule x (+ y (* 0.2 base)) w (max 1.0 (* 0.18 base))))
       (+ y (* 0.5 base))]
      [else y]))

  (define end-y (blocks-y blocks pad pad (- page-w (* 2 pad)) #f))
  (values (reverse bands) (reverse ops) (+ end-y pad)))

;; ---------------------------------------------------------------------------
;; paint
;; ---------------------------------------------------------------------------

;; blocks -> bitmap%.  page-width is the logical content width; scale is the
;; oversampling factor (2.0 => crisp at 2x).
(define (display-list->bitmap blocks #:page-width [page-width 720] #:scale [scale 2.0])
  (define W (inexact->exact (round (* page-width scale))))
  (define-values (bands ops H) (layout blocks W scale))
  (define bmp (make-bitmap W (max 1 (inexact->exact (round H)))))
  (define dc (new bitmap-dc% [bitmap bmp]))
  (send dc set-smoothing 'smoothed)
  ;; white ground
  (send dc set-pen "white" 0 'transparent)
  (send dc set-brush "white" 'solid)
  (send dc draw-rectangle 0 0 W H)
  ;; section bands, behind
  (for ([o (in-list bands)])
    (send dc set-pen "white" 0 'transparent)
    (send dc set-brush (list-ref o 5) 'solid)
    (send dc draw-rounded-rectangle (list-ref o 1) (list-ref o 2) (list-ref o 3) (list-ref o 4) (* 6 scale)))
  ;; content
  (for ([o (in-list ops)])
    (case (car o)
      [(text)
       (send dc set-font (list-ref o 4))
       (send dc set-text-foreground (list-ref o 5))
       (send dc draw-text (list-ref o 3) (list-ref o 1) (list-ref o 2))]
      [(img)
       (send dc draw-bitmap (list-ref o 3) (list-ref o 1) (list-ref o 2))]
      [(rule)
       (send dc set-pen "black" 0 'transparent)
       (send dc set-brush black 'solid)
       (send dc draw-rectangle (list-ref o 1) (list-ref o 2) (list-ref o 3) (list-ref o 4))]))
  (send dc set-bitmap #f)
  bmp)

(define (display-list->png blocks out-path #:page-width [page-width 720] #:scale [scale 2.0])
  (define bmp (display-list->bitmap blocks #:page-width page-width #:scale scale))
  (send bmp save-file out-path 'png)
  out-path)
