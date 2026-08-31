#lang racket/base

;; Subprocess entry point.
;;
;;   racket extract.rkt <mode> <file> [<working-dir>]
;;
;; where <mode> is `scribble` or `strudel`: realize the file's `program`
;; art with that realizer and hand back the result.
;;
;; A programmart composition is a `#lang rhombus/and_meta` module that
;; provides a `program` art (a `define_art`).  In Rhombus, `realize` is a
;; form that must run inside a module that imports the art, so -- exactly
;; as the Racket original did -- each mode writes a small driver module
;; next to the source, compiles it, and reads the result back:
;;
;;   #lang rhombus/and_meta
;;   import:
;;     lib("programmart/scribble.rhm") open
;;     lib("tonart4/main.rhm") open
;;     "program.rhm" open
;;   export: result
;;   def result = realize program_scribble: program
;;
;; `realize` needs the realizer as a bare identifier (a dotted name does
;; not parse there), so the realizer is imported `open` and the base art
;; is `program`.  The driver is a *sibling* of the source, so the source's
;; own relative imports and `load_musicxml` paths still resolve, and it is
;; imported by its bare basename.
;;
;; This runs in its own process on purpose: instantiating the driver runs
;; the realizers, which shell out to lilypond and take seconds; none of
;; that should be able to wedge or kill the IDE.  Everything the program
;; prints while loading -- lilypond's chatter -- is captured into a log
;; and kept out of the way, because the result is the only thing allowed
;; on the real stdout.

(require racket/port
         racket/path
         racket/file
         racket/class
         racket/string
         scribble/core
         "scribble-preview.rkt")

(provide extract-result)

;; The art each button realizes.  Only `program` for now: `realize` wants
;; a bare realizer id, so the scribble realizer is imported as
;; `program_scribble` -- which would collide with a same-named override
;; art in the driver.  (When the strudel / chuck realizers are ported,
;; their `program_strudel` / `program_chuck` override arts do not collide,
;; and can be added here.)
(define BASE-ART "program")

;; ---------------------------------------------------------------------------
;; errors
;; ---------------------------------------------------------------------------

(define (format-error e log)
  (define msg
    (if (exn? e)
        (let* ([base (exn-message e)]
               [locs (if (exn:srclocs? e) ((exn:srclocs-accessor e) e) '())]
               [loc (and (pair? locs) (car locs))])
          ;; Syntax errors already carry `file:line:col:` up front; only
          ;; add it for the ones that don't.
          (if (and loc (srcloc-source loc)
                   (not (regexp-match? #px"^[^\\s:]+:[0-9]+:[0-9]+:" base)))
              (format "~a:~a:~a: ~a"
                      (let ([s (srcloc-source loc)])
                        (if (path? s) (path->string (file-name-from-path s)) s))
                      (or (srcloc-line loc) "?")
                      (or (srcloc-column loc) "?")
                      base)
              base))
        (format "~a" e)))
  (list 'err msg log))

;; ---------------------------------------------------------------------------
;; does the module export the `program` art?
;; ---------------------------------------------------------------------------

;; A Rhombus `define_art` exports into facade's own binding space, not the
;; default phase-0 syntax space -- so `module->exports` lists it under the
;; group key `(0 . facade/af)` rather than a bare `0`.  (This is how we
;; can tell an art is there without instantiating the module.)
(define (art-exports path)
  (dynamic-require path 0)
  (define-values (vars stxs) (module->exports path))
  (for*/list ([grp (in-list stxs)]
              #:when (let ([k (car grp)])
                       (and (pair? k) (eqv? 0 (car k)) (eq? 'facade/af (cdr k))))
              [e (in-list (cdr grp))])
    (symbol->string (car e))))

(define (missing-art-message path names)
  (define arts (sort names string<?))
  (string-append
   (format "~a provides no `program` art.\n\nThe realizer buttons realize the `program` art the module provides."
           (path->string (file-name-from-path path)))
   (if (null? arts)
       ""
       (format "\n\nThis module does provide these arts: ~a\n\nAdd a `define_art program: …` (and `export program`) that composes one of them."
               (string-join arts ", ")))))

;; ---------------------------------------------------------------------------
;; driver module
;; ---------------------------------------------------------------------------

;; `~s` writes the basename as a properly escaped literal, so spaces and
;; quotes in it are not a problem.
(define (scribble-driver-text user-basename)
  (format (string-append
           "#lang rhombus/and_meta\n"
           "import:\n"
           "  lib(\"programmart/scribble.rhm\") open\n"
           "  lib(\"tonart4/main.rhm\") open\n"
           "  ~s open\n"
           "export: result\n"
           "def result = realize program_scribble: ~a\n")
          user-basename
          BASE-ART))

;; The driver is a sibling of the source and imported by basename.  It is
;; deleted afterward, along with the `.zo` compiled/ picks up.
(define (call-with-driver dir text proc)
  (define drv (make-temporary-file "realizer-driver~a.rhm" #f dir))
  (dynamic-wind
   (lambda () (call-with-output-file drv #:exists 'truncate (lambda (p) (display text p))))
   (lambda () (proc drv))
   (lambda ()
     (with-handlers ([(lambda (_) #t) void]) (delete-file drv))
     (with-handlers ([(lambda (_) #t) void])
       (define-values (base name dir?) (split-path drv))
       (define zo (build-path dir "compiled" (path-replace-extension name #".zo")))
       (when (file-exists? zo) (delete-file zo))))))

;; A `program_scribble_source` string -> a scribble `doc` part, by writing
;; it to a temp sibling `.scrbl` and requiring `doc`.  (The realizer emits
;; absolute image paths, so the temp file's location does not matter.)
(define (source-string->doc src-str dir)
  (define tmp (make-temporary-file "realizer-doc~a.scrbl" #f dir))
  (dynamic-wind
   void
   (lambda () (call-with-output-file tmp #:exists 'truncate/replace
                (lambda (o) (display src-str o)))
              (dynamic-require tmp 'doc (lambda () #f)))
   (lambda () (with-handlers ([(lambda (_) #t) void]) (delete-file tmp)))))

;; ---------------------------------------------------------------------------
;; the modes
;; ---------------------------------------------------------------------------

;; Returns `(ok ART BLOCK …)`, `(code ART STRING)`, or `(err MESSAGE LOG)`.
;; ART is the binding that got realized, which the pane reports.
(define (extract-result mode file [cwd #f])
  (define path (path->complete-path (if (path? file) file (string->path file))))
  (define dir (path-only path))
  (define wd (if cwd (path->complete-path cwd) dir))
  (define log (open-output-string))
  (define (finish-err msg) (list 'err msg (get-output-string log)))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (format-error e (get-output-string log)))])
    (parameterize ([current-output-port log]
                   [current-error-port log]
                   [current-directory wd]
                   [current-load-relative-directory dir])
      (cond
        [(eq? mode 'strudel)
         (finish-err
          (string-append
           "No Strudel realizer in the Rhombus stack yet.\n\n"
           "The Strudel button will realize `program-strudel` once that "
           "realizer is ported to tonart4/programmart. Until then, use the "
           "Scribble button."))]
        [(not (eq? mode 'scribble))
         (finish-err (format "Unknown mode ~a." mode))]
        [else
         (define names (art-exports path))
         (cond
           [(not (member BASE-ART names))
            (finish-err (missing-art-message path names))]
           [else
            (define src-str
              (call-with-driver
               dir (scribble-driver-text (path->string (file-name-from-path path)))
               (lambda (drv) (dynamic-require drv 'result (lambda () #f)))))
            (cond
              [(not (string? src-str))
               (finish-err "The scribble realizer produced no document source.")]
              [else
               (define doc (source-string->doc src-str dir))
               (if (part? doc)
                   (list* 'ok (string->symbol BASE-ART) (doc->display-list doc))
                   (finish-err "The scribble realizer's document did not render."))])])]))))

(module+ main
  (define args (current-command-line-arguments))
  (unless (<= 2 (vector-length args) 3)
    (raise-user-error 'extract "expected <mode> <file> [<working-dir>]"))
  (define real-out (current-output-port))
  (write (extract-result (string->symbol (vector-ref args 0))
                         (vector-ref args 1)
                         (and (= 3 (vector-length args)) (vector-ref args 2)))
         real-out)
  (flush-output real-out))
