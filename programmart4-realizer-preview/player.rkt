#lang racket/base

;; Playback subprocess.
;;
;;   racket player.rkt <file> <working-dir> <tempo> <volume> <out> <mode>
;;
;; Realizes the file's `program_audio` art (falling back to `program`) with
;; programmart's `program_performer` realizer into a *timeline* -- a flat
;; list of instructions in section order -- and performs it:
;;
;;   (list "mark"   title)                a section marker (reported)
;;   (list "speak"  speaker text)         a line, spoken with `say`
;;   (list "direct" text)                 a stage direction, spoken (other voice)
;;   (list "music"  thunk secs)           call the thunk for an rsound, play it,
;;                                          hold `secs` seconds
;;
;; The timeline is plain data with rsound *thunks*, so each section is only
;; synthesized when the player reaches it -- playback starts promptly and
;; the wait is spread across the piece.  As extract.rkt does, we write a
;; small driver module next to the source, instantiate it, and read the
;; timeline back (the realize/synthesis output is pointed at stderr so the
;; status stream on stdout stays clean).
;;
;; Stop: the panel closes our stdin (or sends `stop`); a reader thread sees
;; it, stops sound, and the walk ends.  `tempo`/`out`/`mode` are accepted
;; for protocol compatibility with the panel but unused on this path.

(require racket/port
         racket/path
         racket/file
         racket/string
         racket/system
         (only-in rsound rs-write))

(define SAY "/usr/bin/say")
(define AFPLAY "/usr/bin/afplay")   ; play a WAV, reliably, with no PortAudio
(define DIRECTION-VOICE "Daniel")   ; stage directions in a different voice

(define progress-out (make-parameter (current-output-port)))
(define (report fmt . args)
  (displayln (apply format fmt args) (progress-out))
  (flush-output (progress-out)))

;; ---------------------------------------------------------------------------
;; which art to realize
;; ---------------------------------------------------------------------------

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

(define (driver-text user-basename art)
  (format (string-append
           "#lang rhombus/and_meta\n"
           "import:\n"
           "  lib(\"programmart/audio.rhm\") open\n"
           "  lib(\"tonart4/main.rhm\") open\n"
           "  ~s open\n"
           "export: timeline\n"
           "def timeline = realize program_performer: ~a\n")
          user-basename
          art))

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

;; the timeline comes back as Rhombus values; events are lists indexable by
;; position.  `list-ref` works on them (Rhombus PairLists are Racket lists).
(define (ev-kind e) (list-ref e 0))

;; speak `text`, optionally in `voice`; blocks until `say` finishes
(define (speak! text [voice #f])
  (apply system* SAY (append (if voice (list "-v" voice) '()) (list text))))

;; play an rsound by writing it to a temp WAV and running `afplay`, which
;; is interruptible (killed on stop) -- rsound's own PortAudio playback is
;; unreliable across machines.  Returns when the sound finishes or `stop?`.
(define (play-sound! snd stop?)
  (define wav (make-temporary-file "realizer-audio~a.wav"))
  (dynamic-wind
   void
   (lambda ()
     (rs-write snd wav)
     (define afp (process* AFPLAY (path->string wav)))
     (define ctl (list-ref afp 4))
     (let loop ()
       (cond
         [(stop?) (with-handlers ([(lambda (_) #t) void]) (ctl 'kill))]
         [(eq? 'running (ctl 'status)) (sleep 0.1) (loop)]
         [else (void)]))
     ;; close the pipes process* opened
     (close-input-port (list-ref afp 0))
     (close-output-port (list-ref afp 1))
     (close-input-port (list-ref afp 3)))
   (lambda () (with-handlers ([(lambda (_) #t) void]) (delete-file wav)))))

;; ---------------------------------------------------------------------------

(module+ main
  (define args (current-command-line-arguments))
  (unless (<= 5 (vector-length args) 6)
    (raise-user-error 'player "expected <file> <working-dir> <tempo> <volume> <out> [<mode>]"))
  (define path (path->complete-path (string->path (vector-ref args 0))))
  (define wd (path->complete-path (string->path (vector-ref args 1))))
  (define dir (path-only path))

  (define stopped (box #f))
  (void
   (thread (lambda ()
             (let loop ()
               (define l (read-line))
               (cond
                 [(eof-object? l) (set-box! stopped #t)]
                 [(string=? (string-trim l) "stop") (set-box! stopped #t)]
                 [else (loop)])))))
  (define (stopped?) (unbox stopped))

  (parameterize ([progress-out (current-output-port)]
                 [current-directory wd]
                 [current-load-relative-directory dir]
                 [current-output-port (current-error-port)])   ; realize chatter -> stderr
    (with-handlers ([(lambda (e) #t)
                     (lambda (e)
                       (report "!! ~a" (if (exn? e) (exn-message e) e))
                       (exit 1))])
      (define names (art-exports path))
      (define art (choose-audio-art names))
      (unless art
        (report "This module provides no `program_audio` or `program` art to play.")
        (exit 1))
      (report "Realizing (~a)…" art)
      (define timeline
        (call-with-driver
         dir (driver-text (path->string (file-name-from-path path)) art)
         (lambda (drv) (dynamic-require drv 'timeline (lambda () #f)))))
      (unless (and timeline (pair? timeline))
        (report "The performer produced an empty timeline.")
        (exit 0))
      (define total (length timeline))
      (for ([e (in-list timeline)] [i (in-naturals 1)])
        (unless (stopped?)
          (case (ev-kind e)
            [("mark")
             (report "[~a/~a] ~a" i total (list-ref e 1))]
            [("speak")
             (report "[~a/~a] ~a" i total (list-ref e 1))
             (speak! (list-ref e 2))]
            [("direct")
             (report "[~a/~a] (direction)" i total)
             (speak! (list-ref e 1) DIRECTION-VOICE)]
            [("music")
             (define secs (list-ref e 2))
             (report "[~a/~a] music ~a s" i total (real->decimal-string secs 1))
             (define snd ((list-ref e 1)))         ; synthesize this section now
             (unless (stopped?)
               (play-sound! snd stopped?))]
            [else (void)])))
      (report (if (stopped?) "stopped" "done"))
      (exit 0))))
