# programmart

Concert programs for [facade](https://github.com/jagen31/facade) (Art 4), in
[Rhombus](https://rhombus-lang.org) — the *program* instantiation of the engine,
the way [tonart4](https://github.com/jagen31/tonart4) is the *music* one. Ported
from the Programmart used in the tonart concert compositions.

## Vocabulary

| form | meaning |
|---|---|
| `section id …` | a **coordinate**: which section a form belongs to (an ordered id path; nesting appends, `within` by prefix) |
| `art_title "…"` | an object: a section's printed title |
| `hymn_number n` | an object: a hymn by its number |
| `bg "color"` | an object: a section's background colour |
| `program_title "…"` | an object: the whole program's title |
| `piece id` | an object: a named piece |
| `hymn_number_to_title` | a rewriter: each `hymn_number` → an `art_title` from the hymnal |
| `program_text` | a realizer: the program as plain text |
| `program_html` | a realizer: the program as a self-contained HTML page, each section tinted by its `bg` |

`import: programmart open` also brings all of facade (`realize`, `at`, `section`,
`define_art`, the standard coordinates, …).

## Usage

```
#lang rhombus/and_meta
import: programmart open

define_art order_of_service:
  program_title "PL Songbook"
  at [section prelude]:
    art_title "Prelude"
    hymn_number 3
  at [section opening_song]:
    art_title "Opening Song"
    hymn_number 8

// a colour sub-program: each bg lands on its section because it shares
// the section coordinate
define_art color_program:
  at [section prelude]:      bg "goldenrod"
  at [section opening_song]: bg "lightblue"

println(realize program_text: order_of_service)
def html = realize program_html:
             order_of_service
             color_program
```

Because a `bg` carries a `section` coordinate, the `color_program` and the
`order_of_service` compose by coordinate — the goldenrod lands on the prelude and
the lightblue on the opening song, with no explicit wiring. That is the whole
point of Art: forms meet through their coordinates.

## Layout

- `programmart-lib/` — the library (collection `programmart`)
  - `main.rhm` — public entry (re-exports facade + the program lib)
  - `private/lib.rhm` — the vocabulary, the hymnal, and the realizers
  - `tests/demo.rhm` — a worked example
- `programmart/` — the metapackage

## Local build

Needs `facade` installed.

```
raco pkg install programmart/ programmart-lib/
racket programmart-lib/tests/demo.rhm
```
