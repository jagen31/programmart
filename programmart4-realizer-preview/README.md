# Realizer Preview

A DrRacket plugin that runs a realizer over the edited module's `program`
art and shows the result in a pane on the right.

This is the Rhombus edition: it realizes a **programmart** composition
(the Art 4 program DSL, ported to Rhombus).

Buttons:

- **Scribble** — realizes the `program_visual` art (the printed order of
  service) with programmart's `program_scribbler` realizer and renders it
  as a document: headings, section colors, dialogue, resource/hymn titles,
  lilypond scores, dancer figures, slides. **Working.**
- **Play ▸** — realizes the `program_audio` art with tonart4's
  `music_rsound` realizer into an rsound and plays it. **Working.** (Stop
  ends it; the transport's Perform/Prev/Next are inert on the rsound path.)
- **Strudel ▸** — will realize a `program_strudel` and hand it to a Strudel
  REPL on localhost. **Pending** the strudel realizer — the button reports
  that for now.

Each button prefers a per-realizer override art and falls back to the base
`program`: Scribble → `program_visual`, Play → `program_audio`, Strudel →
`program_strudel`.

## Install

```bash
raco pkg install --link /Users/jared.gentner/git/programmart/programmart4-realizer-preview
```

Restart DrRacket, then **View → Show Realizer Preview (Rhombus)** (`⌥⌘R`).

> The menu item, shortcut (`⌥⌘R`), sort key, and preference keys are all
> distinct from the original Racket `realizer-preview` plugin, so both can
> be installed and used at once.

To pick up code changes to the plugin, `raco make tool.rkt` and restart
DrRacket.

> The `program-preview` plugin adds its own pane too, so with both
> installed you get two menu items and can open two panes side by side.

## What it expects

A `#lang rhombus/and_meta` module that **exports a `program` art** and,
optionally, the per-realizer overrides:

```rhombus
export: program program_visual program_audio

define_art program:           // the raw order of service
  hymnal; resources; service

define_art program_visual:    // prepared for the document
  program; color_program; …; resource_to_title

define_art program_audio:     // the whole thing, as tones
  program; …; note_to_tone
```

`tonart4-compositions`' `dances/service.rhm` is the reference. Each art is
realized as given — the plugin composes nothing in behind your back.

The status line always names the binding that ran
(`program_visual · 24 blocks · 12.9 s`).

A module without a suitable art says so and lists the arts it does
provide, so you can rename or compose one.

| control | what it does |
|---|---|
| **Scribble** | realize `program_visual` (else `program`) into the pane |
| **Play ▸** | realize `program_audio` (else `program`) and play it |
| **Strudel ▸** | (pending the strudel realizer) |
| **Zoom** | rescale the pane (relayout only, no re-realize) |

**Auto** re-runs **Scribble** ~1.5 s after you stop typing. Off by
default: every run re-runs lilypond, ~10 s a cycle.

## How it works

```
 definitions text ──► extract.rkt (subprocess) ──► result ──► layout.rkt ──► text%
                          │
                          ├─ write a driver .rhm beside the source
                          ├─ realize the art with program_scribbler
                          └─ read back the source, render its `doc`
```

**An art is a `define_art`, a syntax binding in facade's own binding
space**, and `realize` is a form that has to run inside a module that
imports the art. So — exactly as the Racket original did — the Scribble
button writes a small driver module next to your source, compiles it, and
reads the result back (the Play button does the same with `music_rsound`,
reading back the rsound):

```rhombus
#lang rhombus/and_meta
import:
  lib("programmart/scribble.rhm") open
  lib("tonart4/main.rhm") open
  "program.rhm" open
export: result
def result = realize program_scribbler: program_visual
```

Two details are load-bearing:

- **`realize` wants a bare realizer identifier** — a dotted name does not
  parse there — so the realizer is imported `open`. The realizer is
  `program_scribbler`, deliberately not `program_scribble`, so the
  `program_visual` art (and any other override) never collides with it.
- **The driver is a sibling of the source**, imported by its bare
  basename, so the source's own relative imports and `load_musicxml` paths
  still resolve. It is deleted afterward, with its `.zo`.

The realizer emits **absolute** image paths, so the rendered document
resolves its score/figure/slide PNGs no matter where the temporary
`.scrbl` it is read through happens to live.

**Realizing happens in a subprocess.** Instantiating the driver runs the
realizers, which shell out to lilypond and take ~10 s; none of that should
be able to wedge the IDE, and lilypond's stdout chatter must not corrupt
the pane. Its output is captured into a build log shown under any error.

### Working directory

A failed run is retried from the repo root (nearest ancestor with a
`.git`) and the answer is remembered per file, for compositions that reach
for repo-root-relative paths.

## What's here vs. deferred

**Here and working:** the plugin, the Scribble button (document), the Play
button (rsound audio via `music_rsound`), the driver-module realization,
display-list rendering, section colors, auto-render, repo-root retry.

**Audio caveat.** `music_rsound` mixes every tone by its interval, with no
notion of sections in time — so `program_audio` over a whole multi-section
program plays all its sections *at once*, and its length is the longest
piece. Shape `program_audio` to taste (a single piece, or sections spread
out in time) for a musical result; the plugin just realizes and plays it.

**Deferred:**

- **Strudel** needs a `program_strudel` realizer in tonart4/programmart.
  The REPL handoff (base64 `code2hash`, `http://localhost:4321/#…`) is
  kept in `preview-panel.rkt` for when it lands.
- **ChucK / a scored performance** (dialogue spoken, slides raised, manual
  "perform myself" stepping) is not on the rsound path. The original
  370-line ChucK performer lives in
  `tonart-compositions/drracket-realizer-preview/player.rkt` to port back
  if that richer performance is wanted.

## Notes

- `racket` and `lilypond` are found explicitly, not via `PATH`: DrRacket
  launched from Finder inherits a bare environment with neither Homebrew
  nor `/usr/local` on it.
