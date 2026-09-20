# LightTable CodeMirror forks

These are **not** copies of upstream CodeMirror addons — they are LightTable-specific
forks with divergent APIs. Do not repoint their call sites at
`core/node_modules/codemirror/addon/...` without checking the API each one exposes
first; both were briefly deleted from the repo (commit `5442e92`) and restored after
confirming their call sites need exactly this shape.

- **`search.js`** defines `CodeMirror.commands.find(cm, query, rev)` — a 3-argument,
  dialog-free search command, plus `getSearchState` and a 4-argument `replace`.
  `src/lt/objs/find.cljs` drives LT's own find/replace UI against this exact
  signature. Upstream `codemirror/addon/search/search.js` instead defines
  `find(cm)` and opens its own `dialog.js`-based prompt — swapping in the
  upstream file breaks Find/Replace.

- **`show-hint.js`** is not the CodeMirror autocomplete addon at all. It defines
  only `CodeMirror.positionHint` and `CodeMirror.ensureHintVisible`, which
  `src/lt/plugins/auto_complete.cljs` calls to position LT's own hint popup.
  Upstream `codemirror/addon/hint/show-hint.js` provides neither function.

- **`overlay.js`** is current upstream `codemirror/addon/mode/overlay.js` with one
  fenced Light Table deviation: it passes the base mode's current token as a third
  argument to `overlay.token`, i.e. `overlay.token(stream, state.overlay, {pos, style})`.
  Upstream passes only two arguments. The Rainbow plugin
  (`lt.plugins.rainbow/rainbow-parens`) requires that third argument — its token fn
  reads `base.style` to detect brackets and `base.pos` to rewind the stream. Pointing
  this call site at upstream makes `base` `undefined`, so every syntax-highlight pass
  throws and CodeMirror aborts line rendering — the editor stops visibly updating as
  you type. (An earlier pass through this directory wrongly recorded `overlay.js` as a
  verbatim upstream copy; it is not, and that regression is exactly what it caused.)

Loaded from `src/lt/objs/find.cljs`, `src/lt/plugins/auto_complete.cljs` and
`src/lt/objs/editor.cljs` via `load/js "core/lighttable/codemirror/<file>"`.
