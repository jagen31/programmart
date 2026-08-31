# Realizer Preview

A DrRacket plugin that runs a realizer over the edited module's `program`
art and shows the result in a pane on the right.

This is the Rhombus edition: it realizes a **programmart** composition
(the Art 4 program DSL, ported to Rhombus).

Buttons:

- **Scribble** — realizes the `program` art with programmart's
  `program_scribble` realizer and renders it as a document (headings,
  section colors, lilypond scores, dancer figures, slides). **Working.**
- **Strudel ▸** — will realize a `program-strudel` and hand it to a
  Strudel REPL on localhost. **Pending** the strudel realizer — the button
  reports that for now.
- **Play ▸ / Perform Myself / ◂ Prev / Next ▸** — will perform the program
  through a ChucK shell (with automatic and manual/"perform myself"
  modes). **Pending** the chuck realizer — the transport reports that for
  now.

The Strudel and playback controls are present so the pane is the real
realizer-preview, but neither can do anything until its realizer is ported
to tonart4/programmart. See "What's here vs. deferred" below.

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

A `#lang rhombus/and_meta` module that **exports a `program` art**:

```rhombus
export: program

define_art program:
  service_scribble   // or however you compose the order of service
```

`tonart4-compositions`' `dances/service.rhm` is the reference. The art is
realized as given — the plugin composes nothing in behind your back; if
you want the section colors or the dancer figures, compose them into
`program` yourself (as `service_scribble` does).

The status line always names the binding that ran
(`program · 24 blocks · 12.9 s`).

A module without a `program` art says so and lists the arts it does
provide, so you can rename or compose one.

| control | what it does |
|---|---|
| **Scribble** | realize `program` as a document, into the pane |
| **Strudel ▸** | (pending the strudel realizer) |
| **Play ▸ / Perform Myself / Prev / Next** | (pending the chuck realizer) |
| **Zoom** | rescale the pane (relayout only, no re-realize) |

**Auto** re-runs **Scribble** ~1.5 s after you stop typing. Off by
default: every run re-runs lilypond, ~10 s a cycle.

## How it works

```
 definitions text ──► extract.rkt (subprocess) ──► result ──► layout.rkt ──► text%
                          │
                          ├─ write a driver .rhm beside the source
                          ├─ realize `program` with `program_scribble`
                          └─ read back the source, render its `doc`
```

**A `program` is a `define_art`, a syntax binding in facade's own binding
space**, and `realize` is a form that has to run inside a module that
imports the art. So — exactly as the Racket original did — the Scribble
button writes a small driver module next to your source, compiles it, and
reads the result back:

```rhombus
#lang rhombus/and_meta
import:
  lib("programmart/scribble.rhm") open
  lib("tonart4/main.rhm") open
  "program.rhm" open
export: result
def result = realize program_scribble: program
```

Two details are load-bearing:

- **`realize` wants a bare realizer identifier** — a dotted `pmart.program_scribble`
  does not parse there — so the realizer is imported `open` and the art is
  the base name `program`. (A same-named `program_scribble` override art
  would then collide with the realizer in the driver; the strudel / chuck
  override arts won't, and can be added when those realizers land.)
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

**Here and working:** the plugin, the Scribble button, the driver-module
realization, the display-list rendering, section colors, auto-render,
repo-root retry.

**Deferred with their realizers:**

- **Strudel** needs a `program-strudel` realizer in tonart4/programmart.
  The REPL handoff (base64 `code2hash`, `http://localhost:4321/#…`) is
  kept in `preview-panel.rkt` for when it lands.
- **ChucK playback** (`player.rkt`) needs a tonart4 chuck realizer — its
  timeline event contract is that realizer's to define. `player.rkt` is a
  placeholder that reports the deferral; the original 370-line performer
  lives in `tonart-compositions/drracket-realizer-preview/player.rkt` to
  port back against the real contract. A simpler path may be the existing
  `music_rsound` realizer (audio buffers) rather than a full ChucK shell.

## Notes

- `racket` and `lilypond` are found explicitly, not via `PATH`: DrRacket
  launched from Finder inherits a bare environment with neither Homebrew
  nor `/usr/local` on it.
