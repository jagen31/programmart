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
         racket/async-channel
         (only-in rsound rs-write))

(define SAY "/usr/bin/say")
(define AFPLAY "/usr/bin/afplay")   ; play a WAV, reliably, with no PortAudio
(define DIRECTION-VOICE "Daniel")   ; stage directions in a different voice

;; the slideshow executable ships next to the running racket; fall back to
;; PATH, then a bare name
(define SLIDESHOW
  (let ([cand (and (path? (find-system-path 'exec-file))
                   (let ([d (path-only (path->complete-path (find-system-path 'exec-file)))])
                     (and d (build-path d "slideshow"))))])
    (cond
      [(and cand (file-exists? cand)) (path->string cand)]
      [(find-executable-path "slideshow") => path->string]
      [else "slideshow"])))

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

;; Show the slide PNGs `paths` as a fullscreen slideshow: write a
;; `#lang slideshow` deck (one slide per image, scaled to fit) and run the
;; slideshow app.  Playback holds here -- the presenter clicks through and
;; quits -- until it exits or Stop kills it.  (The concert player did the
;; same, opening the deck with the slideshow app.)
(define (show-slides! paths stop?)
  (when (pair? paths)
    (define tmp (make-temporary-file "realizer-slides~a.rkt"))
    (dynamic-wind
     void
     (lambda ()
       (call-with-output-file tmp #:exists 'truncate/replace
         (lambda (o)
           (displayln "#lang slideshow" o)
           (for ([p (in-list paths)])
             (fprintf o "(slide (scale-to-fit (bitmap ~s) 1000 700))\n" p))))
       (define ss (process* SLIDESHOW (path->string tmp)))
       (define ctl (list-ref ss 4))
       (let loop ()
         (cond
           [(stop?) (with-handlers ([(lambda (_) #t) void]) (ctl 'kill))]
           [(eq? 'running (ctl 'status)) (sleep 0.2) (loop)]
           [else (void)]))
       (close-input-port (list-ref ss 0))
       (close-output-port (list-ref ss 1))
       (close-input-port (list-ref ss 3)))
     (lambda () (with-handlers ([(lambda (_) #t) void]) (delete-file tmp))))))

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

;; perform one event: report it, and make its sound (music -> afplay,
;; speak/direct -> say).  `mark`s carry no sound.
(define (perform-event! e i total stopped?)
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
     (report "[~a/~a] music ~a s" i total (real->decimal-string (list-ref e 2) 1))
     (unless (stopped?)
       (play-sound! ((list-ref e 1)) stopped?))]      ; synthesize now
    [("slide")
     (report "[~a/~a] slides — holding until the deck is closed" i total)
     (unless (stopped?)
       (show-slides! (list-ref e 1) stopped?))]
    [else (void)]))

;; a one-line summary for the paused prompt in manual mode
(define (event-summary e)
  (case (ev-kind e)
    [("mark")   (format "~a" (list-ref e 1))]
    [("speak")  (format "~a: ~a" (list-ref e 1) (list-ref e 2))]
    [("direct") (format "(stage direction) ~a" (list-ref e 1))]
    [("music")  (format "music · ~a s" (real->decimal-string (list-ref e 2) 1))]
    [("slide")  "slides"]
    [else       "item"]))

(define (mark? e) (string=? (ev-kind e) "mark"))

;; Automatic: walk the timeline end to end, each event for its own length.
(define (perform-auto! vec total stopped?)
  (for ([e (in-vector vec)] [i (in-naturals 1)])
    (unless (stopped?) (perform-event! e i total stopped?))))

;; Manual ("Perform Myself"): pause before every performable item and wait
;; for a command -- `play` performs the current item and stays on it (so it
;; can be repeated), `next`/`prev` step between items, `stop` ends.  Section
;; marks carry no sound, so they are announced and stepped past rather than
;; paused on.  Indexed, because `prev` has to reach items already behind the
;; cursor.  (Mirrors the concert player's `perform-manual!`.)
(define (perform-manual! vec total stopped? next-cmd)
  ;; step one performable item from `from` in direction `dir` (+1/-1),
  ;; announcing any marks crossed; returns the new index or #f off the end
  (define (step from dir)
    (let scan ([j (+ from dir)])
      (cond
        [(or (< j 0) (>= j total)) #f]
        [(mark? (vector-ref vec j))
         (perform-event! (vector-ref vec j) (add1 j) total stopped?)
         (scan (+ j dir))]
        [else j])))
  (define first (step -1 +1))
  (when first
    (let loop ([cur first])
      (unless (stopped?)
        (define ev (vector-ref vec cur))
        (report "[~a/~a] ⏸ ~a — Play to perform · Prev / Next to move"
                (add1 cur) total (event-summary ev))
        (let wait ()
          (case (next-cmd)
            [(play)
             (perform-event! ev (add1 cur) total stopped?)
             (unless (stopped?)
               (report "[~a/~a] ✓ ~a — Prev / Next to move" (add1 cur) total (event-summary ev)))
             (wait)]
            [(next) (define n (step cur +1)) (if n (loop n) (void))]
            [(prev) (define p (step cur -1)) (if p (loop p) (wait))]
            [(stop) (void)]
            [else (wait)]))))))

;; ---------------------------------------------------------------------------

(module+ main
  (define args (current-command-line-arguments))
  (unless (<= 5 (vector-length args) 6)
    (raise-user-error 'player "expected <file> <working-dir> <tempo> <volume> <out> [<mode>]"))
  (define path (path->complete-path (string->path (vector-ref args 0))))
  (define wd (path->complete-path (string->path (vector-ref args 1))))
  (define dir (path-only path))
  (define manual? (and (= 6 (vector-length args))
                       (string=? "manual" (vector-ref args 5))))

  (define stopped (box #f))
  (define cmd-ch (make-async-channel))
  ;; The panel talks over stdin, one command per line: `play` performs the
  ;; current item, `next`/`prev` move, and closing the port (EOF) -- or a
  ;; `stop` line -- ends the piece.  In auto mode the panel only closes the
  ;; port, so this collapses to stop-on-EOF.
  (void
   (thread (lambda ()
             (let loop ()
               (define l (read-line))
               (cond
                 [(eof-object? l) (set-box! stopped #t) (async-channel-put cmd-ch 'stop)]
                 [else
                  (case (string-trim l)
                    [("play") (async-channel-put cmd-ch 'play) (loop)]
                    [("next") (async-channel-put cmd-ch 'next) (loop)]
                    [("prev") (async-channel-put cmd-ch 'prev) (loop)]
                    [("stop") (set-box! stopped #t) (async-channel-put cmd-ch 'stop)]
                    [else (loop)])])))))
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
      (define vec (list->vector timeline))
      (define total (vector-length vec))
      (if manual?
          (perform-manual! vec total stopped? (lambda () (async-channel-get cmd-ch)))
          (perform-auto! vec total stopped?))
      (report (if (stopped?) "stopped" "done"))
      (exit 0))))
