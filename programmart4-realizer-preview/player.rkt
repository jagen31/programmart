#lang racket/base

;; Playback subprocess -- placeholder.
;;
;;   racket player.rkt <file> <working-dir> <tempo> <volume> <out> <mode>
;;
;; The Racket original performed a `program-chuck` timeline through a
;; ChucK shell (with `say` for dialogue and a slideshow for slides).  None
;; of that machinery exists in the Rhombus stack yet: there is no tonart4
;; chuck realizer, no chuck timeline format, and no chuck backend.  So the
;; transport controls are present in the pane but playback is deferred to
;; go with the chuck realizer -- its event contract is that realizer's to
;; define, and porting the ~370-line performer against a contract that
;; does not exist yet would be guesswork.
;;
;; The panel treats our stdout as a stream of status lines, so we report
;; the situation on one line and exit; the panel shows it and resets the
;; transport.  When the chuck realizer lands, this file grows back into
;; the real performer (see the original drracket-realizer-preview/player.rkt
;; in tonart-compositions).

(module+ main
  (define out (current-output-port))
  (displayln
   "ChucK playback isn't available yet — it arrives with the tonart4 chuck realizer."
   out)
  (flush-output out)
  (exit 0))
