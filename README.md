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

## Engraved programs (Scribble)

`programmart/scribble.rhm` adds `program_scribble` — a realizer that renders
the program as [Scribble](https://docs.racket-lang.org/scribble/) source, and
for each section that holds notes, engraves a score with
[tonart4](https://github.com/jagen31/tonart4)'s LilyPond realizer and embeds
it. `render_scribble_html` runs `raco scribble --html` to produce the page.

```
import:
  programmart open
  tonart4 open
  lib("programmart/scribble.rhm") open

define_art order_of_service:
  program_title "Sunday Service"
  at [section prelude]:
    art_title "Prelude"
    at [interval 0 1]: note g 0 4
    at [interval 1 2]: note a 0 4
  at [section opening_song]:
    art_title "Opening Song"
    at [interval 0 2]: note c 0 5

def src = realize program_scribble: order_of_service
render_scribble_html(src, "program-scores", "program")
```

Notes placed in a section are engraved as its score; each section is
tinted by its `bg`, and multi-voice music engraves as one staff per
`voice`.

This bridges programmart and tonart4, so it lives in its own module (the
core is facade-only). Engraving needs the `lilypond` CLI; rendering needs
`raco`. Scores are written under the output directory (default
`program-scores/`).

## Layout

- `programmart-lib/` — the library (collection `programmart`)
  - `main.rhm` — public entry (re-exports facade + the program lib)
  - `private/lib.rhm` — the vocabulary, the hymnal, and the text/HTML realizers
  - `resources.rhm` — the resource table + `art_program` (multi-realizer)
  - `hymnal.rhm` — the hymnal table (`hymn_number_to_title` / `_to_score`)
  - `scribble.rhm` — the Scribble realizer (engraved scores, section backgrounds)
  - `tests/demo.rhm` — a worked example
- `programmart/` — the metapackage

## Local build

Needs `facade` installed.

```
raco pkg install programmart/ programmart-lib/
racket programmart-lib/tests/demo.rhm
```
