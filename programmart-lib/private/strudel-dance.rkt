#lang racket/base

;; Dance -> Strudel (hydra guitarHero) support for program_strudeler.
;;
;; Ported from the old racket realizer (tonart-compositions/strudel/
;; program-strudel.rkt).  The Rhombus realizer extracts pose FRAMES from a
;; section's music blocks and calls in here to (a) paint a horizontal playback
;; STRIP PNG and (b) emit the per-section `<sid>_dance()` JS.  The `guitarHero`
;; hydra header (glsl scroll math) is emitted once, verbatim, from `hydra-header`.
;;
;; A FRAME is (list start dur l r facing-symbol) in beats.  `make-dancer` is
;; danceart's figure.

(require racket/list racket/match racket/string racket/format racket/math
         (prefix-in im: 2htdp/image)
         (only-in (lib "danceart/private/dance-draw.rkt") make-dancer))

(provide POSE-SIZE render-section-strip! render-dance-png!
         num->js pose-tag dance-call-js hydra-header)

;; --- pose / strip images -------------------------------------------------
(define POSE-SIZE 280)

(define (as-str p) (if (path? p) (path->string p) p))
(define (render-dance-png! l r facing-sym disk-path)
  (unless (file-exists? disk-path)
    (im:save-image (make-dancer l r facing-sym) (as-str disk-path))))

;; Build (and write) a section's playback STRIP PNG.  `dancers` is a list of
;; per-dancer frame lists; `cycle` the dance length in beats; `mode` 'rhythm or
;; 'uniform.  Returns #t if written.  (Faithful to the old render-section-strip!.)
(define (render-section-strip! dancers cycle mode disk-path)
  (define all-frames (append* dancers))
  (cond
    [(null? all-frames) #f]
    [else
     (define n (length dancers))
     (define uniq-starts (sort (remove-duplicates (map car all-frames)) <))
     (define start->idx
       (for/hash ([s (in-list uniq-starts)] [i (in-naturals)]) (values s i)))
     (define raw-w
       (case mode
         [(rhythm)  (* cycle POSE-SIZE)]
         [(uniform) (* (length uniq-starts) POSE-SIZE)]
         [else (error 'render-section-strip! "unknown mode ~a" mode)]))
     (define raw-h (* n POSE-SIZE))
     (define MAX-STRIP 16384)
     (define res (min 1.0 (/ MAX-STRIP (max 1 raw-w)) (/ MAX-STRIP (max 1 raw-h))))
     (define ppb (* POSE-SIZE res))
     (define band (* POSE-SIZE res))
     (define strip-w (max 1 (exact-round (* raw-w res))))
     (define strip-h (max 1 (exact-round (* raw-h res))))
     (define base (im:rectangle strip-w strip-h 'solid (im:color 0 0 0 0)))
     (define final
       (for/fold ([img base]) ([dancer (in-list dancers)] [k (in-naturals)])
         (define row-cy (exact->inexact (* (+ k 0.5) band)))
         (for/fold ([img img]) ([f (in-list dancer)])
           (match-define (list start _dur l r face) f)
           (define pose-img
             (if (= res 1.0) (make-dancer l r face) (im:scale res (make-dancer l r face))))
           (define center-x
             (case mode
               [(rhythm)  (* start ppb)]
               [(uniform) (* (+ (hash-ref start->idx start) 0.5) ppb)]))
           (for/fold ([img img]) ([dx (in-list (list 0 (- strip-w) strip-w))])
             (im:place-image pose-img (exact->inexact (+ center-x dx)) row-cy img)))))
     (im:save-image final (as-str disk-path))
     #t]))

;; --- JS emission ---------------------------------------------------------
(define (num->js x)
  (cond [(integer? x) (~a x)]
        [(rational? x) (~a (exact->inexact x))]
        [else (~a x)]))

(define (pose-tag l r f) (format "~a-~a-~a" l r f))

;; A `<sid>_dance()` constructor returning a hydra node.  `variants` is a list of
;; (list key rhythm-url uniform-url cycle onsets).
(define (dance-call-js sid variants)
  (define (sa . xs) (apply string-append (map ~a xs)))
  (define entries
    (for/list ([v (in-list variants)])
      (match-define (list key rhythm-url uniform-url cycle onsets) v)
      (define onsets-js
        (string-join (for/list ([o (in-list (append onsets (list cycle)))]) (num->js o)) ", "))
      (sa "    '" key "': {\n"
          "      rhythm:  '" rhythm-url "',\n"
          "      uniform: '" uniform-url "',\n"
          "      cycle:   " (num->js cycle) ",\n"
          "      onsets:  [" onsets-js "],\n"
          "    }")))
  (define default-key (cond [(null? variants) "_default"] [else (car (car variants))]))
  (sa "const " sid "_dance = (opts) => {\n"
      "  opts = opts || {};\n"
      "  const _mode = opts.mode || 'rhythm';\n"
      "  const _variants = {\n"
      (string-join entries ",\n") "\n"
      "  };\n"
      "  const _variant = (opts.variant != null) ? ('' + opts.variant) : '" default-key "';\n"
      "  const _data = _variants[_variant] || _variants['" default-key "'];\n"
      "  s0.initImage(_mode === 'uniform' ? _data.uniform : _data.rhythm);\n"
      "  return guitarHero(Object.assign({\n"
      "    cycle: _data.cycle,\n"
      "    onsets: _data.onsets,\n"
      "    phaseOffset: 0,\n"
      "  }, opts));\n"
      "};"))

;; The hydra header: initHydra + `rect`/`scrollXClamp`/`guitarHero`.  Emitted once
;; before any section when the program has a dance.  Lifted verbatim from the old
;; realizer's JS header.
(define hydra-header #<<HYDRA
await initHydra();

// CSS color name -> [r,g,b] in 0..1 (used by a dance scene's letterbox bg).
window._cssToRGB = (name) => {
  const d = document.createElement('div');
  d.style.color = name;
  document.body.appendChild(d);
  const m = getComputedStyle(d).color.match(/\d+(\.\d+)?/g);
  d.remove();
  return m ? [parseInt(m[0]) / 255, parseInt(m[1]) / 255, parseInt(m[2]) / 255] : [0, 0, 0];
};

// Axis-aligned rectangle source: white inside a centered rect (w,h), else black.
setFunction({
  name: 'rect',
  type: 'src',
  inputs: [ { type: 'float', name: 'w', default: 1 }, { type: 'float', name: 'h', default: 1 } ],
  glsl: 'vec2 _d = abs(_st - 0.5) - vec2(w, h) * 0.5; return vec4(vec3(step(max(_d.x, _d.y), 0.0)), 1.0);',
});

// scrollX that clamps uv to [0,1] (edge = transparent) instead of GL_REPEAT.
setFunction({
  name: 'scrollXClamp',
  type: 'coord',
  inputs: [ { type: 'float', name: 'offsetX', default: 0 }, { type: 'float', name: 'speed', default: 0 } ],
  glsl: 'return clamp(_st + vec2(offsetX + time * speed, 0.0), 0.0, 1.0);',
});

// guitarHero -- scrolling-pose display.  Caller loads a playback strip into s0;
// this scrolls one layer past a bar.  See program-strudel.rkt for the full docs.
window.guitarHero = function guitarHero(opts) {
  opts = opts || {};
  const mode       = opts.mode        || 'rhythm';
  const cycle      = (opts.cycle      != null) ? opts.cycle      : 1;
  const onsets     = Array.isArray(opts.onsets) ? opts.onsets    : [0, cycle];
  const vis        = (opts.vis        != null) ? opts.vis        : 4;
  const cellHeight = (opts.cellHeight != null) ? opts.cellHeight : 0.5;
  const barX       = (opts.barX       != null) ? opts.barX       : 0.2;
  const barDrawX   = (opts.barDrawX   != null) ? opts.barDrawX   : barX;
  const bg         = opts.bg          || solid(0, 0, 0);
  const hold        = Math.max(0, (opts.hold    != null) ? opts.hold    : 0);
  const phaseOffset = (opts.phaseOffset != null) ? opts.phaseOffset : 0;
  const revealPad   = (opts.revealPad != null) ? opts.revealPad : 1.5 / vis;
  const timeFn = opts.timeFn || (() => {
    try { if (typeof getTime === 'function') { const v = getTime(); if (isFinite(v)) return v; } } catch (e) {}
    return 0;
  });

  const N = Math.max(1, onsets.length - 1);
  const stripCells = (mode === 'uniform') ? N : cycle;
  const scaleX = stripCells / vis;
  const scaleY = cellHeight;
  const barOffset = (barX - 0.5) / scaleX;

  const bar = solid(1, 1, 0).mask(shape(4).scale(10, 0.002).scrollX(0.5 - barDrawX));

  const targetAtPhase = (mode === 'uniform')
    ? ((phase) => {
        let i = 0;
        for (; i < N - 1; i++) { if (phase < onsets[i + 1]) break; }
        const intervalDur = onsets[i + 1] - onsets[i];
        const progress = intervalDur > 0 ? (phase - onsets[i]) / intervalDur : 0;
        return (i + 0.5 + progress) / N;
      })
    : ((phase) => phase / cycle);

  return bg
    .layer(
      src(s0)
        .scrollX(() => {
          let raw = timeFn() - hold + phaseOffset;
          if (!isFinite(raw)) raw = 0;
          const phase = ((raw % cycle) + cycle) % cycle;
          return targetAtPhase(phase) - 0.5 - barOffset;
        }, 0)
        .scale(1, scaleX, scaleY)
        .mask(rect(
          () => {
            const t = timeFn();
            if (!isFinite(t)) return 0;
            const f0x = barX + (hold - t) / vis;
            const leftEdge = Math.max(0, Math.min(1, f0x - revealPad));
            return 1 - leftEdge;
          },
          cellHeight
        ).scrollX(() => {
          const t = timeFn();
          if (!isFinite(t)) return 0;
          const f0x = barX + (hold - t) / vis;
          const leftEdge = Math.max(0, Math.min(1, f0x - revealPad));
          return -leftEdge / 2;
        }))
    )
    .layer(bar);
};
HYDRA
)
