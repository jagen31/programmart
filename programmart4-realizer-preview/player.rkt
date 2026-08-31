#lang racket/base

;; Playback subprocess.
;;
;;   racket player.rkt <file> <working-dir> <tempo> <volume> <out> <mode>
;;
;; Realizes the file's `program_audio` art (falling back to `program`)
;; with tonart4's `music_rsound` realizer into an rsound, and plays it.
;; This is the rsound path -- no ChucK, no dialogue, no slides; just the
;; program's notes sounding.
;;
;; A `program_audio` is a `define_art`, and `realize` runs inside a module
;; that imports it, so -- as extract.rkt does for the document -- we write
;; a small driver module next to the source, instantiate it, and read the
;; realized rsound back.  Building the sound happens on that
;; `dynamic-require`, which can take a while for a big program; its output
;; is pointed at stderr so the status stream on stdout stays clean.
;;
;; Stop: the panel closes our stdin (or sends `stop`); a reader thread sees
;; it, stops playback, and exits.  `tempo` / `out` / `mode` are accepted
;; for protocol compatibility with the panel but unused on this path.

(require racket/port
         racket/path
         racket/file
         racket/string
         (only-in rsound play/proc stop rs-frames default-sample-rate))

;; Progress goes to the real stdout; the realize phase is pointed at stderr
;; (below), so this parameter keeps hold of the channel the panel reads.
(define progress-out (make-parameter (current-output-port)))
(define (report fmt . args)
  (displayln (apply format fmt args) (progress-out))
  (flush-output (progress-out)))

;; ---------------------------------------------------------------------------
;; which art to realize
;; ---------------------------------------------------------------------------

;; A Rhombus `define_art` exports into facade's binding space, listed under
;; the `(0 . facade/af)` group key by `module->exports`.
(define (art-exports path)
  (dynamic-require path 0)
  (define-values (vars stxs) (module->exports path))
  (for*/list ([grp (in-list stxs)]
              #:when (let ([k (car grp)])
                       (and (pair? k) (eqv? 0 (car k)) (eq? 'facade/af (cdr k))))
              [e (in-list (cdr grp))])
    (symbol->string (car e))))

(define (choose-audio-art names)
  (cond
    [(member "program_audio" names) "program_audio"]
    [(member "program" names) "program"]
    [else #f]))

;; ---------------------------------------------------------------------------
;; driver module
;; ---------------------------------------------------------------------------

;; `rs_render` (which `music_rsound` emits a call to) resolves in tonart4's
;; own scope, so the driver only needs tonart4/main and the source; it does
;; not import rsound itself.
(define (driver-text user-basename art)
  (format (string-append
           "#lang rhombus/and_meta\n"
           "import:\n"
           "  lib(\"tonart4/main.rhm\") open\n"
           "  ~s open\n"
           "export: snd\n"
           "def snd = realize music_rsound: ~a\n")
          user-basename
          art))

;; write the driver beside the source, hand it to `proc`, and clean up
;; (the driver and the `.zo` compiled/ leaves behind)
(define (call-with-driver dir text proc)
  (define drv (make-temporary-file "realizer-audio~a.rhm" #f dir))
  (dynamic-wind
   (lambda () (call-with-output-file drv #:exists 'truncate (lambda (p) (display text p))))
   (lambda () (proc drv))
   (lambda ()
     (with-handlers ([(lambda (_) #t) void]) (delete-file drv))
     (with-handlers ([(lambda (_) #t) void])
       (define-values (base name dir?) (split-path drv))
       (define zo (build-path dir "compiled" (path-replace-extension name #".zo")))
       (when (file-exists? zo) (delete-file zo))))))

;; ---------------------------------------------------------------------------

(module+ main
  (define args (current-command-line-arguments))
  (unless (<= 5 (vector-length args) 6)
    (raise-user-error 'player "expected <file> <working-dir> <tempo> <volume> <out> [<mode>]"))
  (define path (path->complete-path (string->path (vector-ref args 0))))
  (define wd (path->complete-path (string->path (vector-ref args 1))))
  (define dir (path-only path))

  (define stopped (box #f))
  ;; The panel talks over stdin; any line, or EOF, means stop.
  (void
   (thread (lambda ()
             (let loop ()
               (define l (read-line))
               (cond
                 [(eof-object? l) (set-box! stopped #t) (stop)]
                 [(string=? (string-trim l) "stop") (set-box! stopped #t) (stop)]
                 [else (loop)])))))

  (parameterize ([progress-out (current-output-port)]
                 [current-directory wd]
                 [current-load-relative-directory dir]
                 ;; keep realize/synthesis chatter off the status stream
                 [current-output-port (current-error-port)])
    (with-handlers ([(lambda (e) #t)
                     (lambda (e)
                       (with-handlers ([(lambda (_) #t) void]) (stop))
                       (report "!! ~a" (if (exn? e) (exn-message e) e))
                       (exit 1))])
      (define names (art-exports path))
      (define art (choose-audio-art names))
      (unless art
        (report "This module provides no `program_audio` or `program` art to play.")
        (exit 1))
      (report "Rendering audio (~a)…" art)
      (define snd
        (call-with-driver
         dir (driver-text (path->string (file-name-from-path path)) art)
         (lambda (drv) (dynamic-require drv 'snd (lambda () #f)))))
      (cond
        [(not snd)
         (report "The audio realizer produced no sound.")
         (exit 1)]
        [(unbox stopped) (exit 0)]
        [else
         (define secs (/ (rs-frames snd) (exact->inexact (default-sample-rate))))
         (report "[1/1] playing ~a s — Stop to end" (real->decimal-string secs 1))
         (play/proc snd)
         (let wait ([left secs])
           (when (and (> left 0) (not (unbox stopped)))
             (sleep (min 0.2 left))
             (wait (- left 0.2))))
         (with-handlers ([(lambda (_) #t) void]) (stop))
         (report (if (unbox stopped) "stopped" "done"))
         (exit 0)]))))
