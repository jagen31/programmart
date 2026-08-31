#lang info

(define collection "programmart4-realizer-preview")

(define deps
  '("base"
    "draw-lib"
    "gui-lib"
    "scribble-lib"
    "drracket-plugin-lib"
    "rhombus-lib"))

(define version "0.0.1")
(define pkg-desc "Realizer Preview -- a DrRacket pane that realizes a programmart (Rhombus) composition")
(define license '(MIT))

(define drracket-tools '(("tool.rkt")))
(define drracket-tool-names '("Realizer Preview"))
(define drracket-tool-icons '(#f))
