# Using this codebase to deepen ClojureScript knowledge

Notes on what LightTable's source is genuinely good for learning, what it
will actively mislead you about, and a concrete path in.

Companion to `UPGRADE-RETROSPECTIVE-NOTES.md` (why the upgrade was hard) and
`doc/BOT.md` (the architecture itself).

---

## The short answer

Yes — but for a narrower set of things than you might expect, and with one
real caveat: **the code is 2014-era and predates most of what defines modern
Clojure.**

A survey of `src/` (~15,000 lines, 69 files):

| Idiom | Files using it |
|---|---|
| `defprotocol` / `defrecord` / `deftype` / `reify` | **0** |
| `core.async` | 0 |
| `clojure.spec` | 0 |
| transducers | 0 |
| `defmulti` | 3 |
| JS interop (`js/`, `.-`, `#js`) | 455 lines |
| `defmacro` (all in `src/lt/macros.cljc`) | 12 |

That table is the whole argument in miniature. Read on for what it implies.

---

## What it teaches well

### 1. Macros — the strongest case

Twelve macros in `src/lt/macros.cljc`, three of them load-bearing and
non-trivial:

- **`behavior`** (`:8`) — declares a new *kind of thing*, not a function.
  Registers into a global registry, handles `:triggers`, `:debounce`,
  `:throttle`, `:exclusive`, `:params`.
- **`defui`** (`:30`) — a DSL for building DOM with event bindings.
- **`background`** (`:95`) — takes a function body and arranges for it to run
  in a *forked process*. The most magical thing in the repo, and (see the
  retrospective) the least defensible.

Macro-writing is the biggest gap in most self-taught Clojure, because
tutorials only ever demonstrate `unless`. These are real ones solving real
problems.

**The trick that makes this a great learning loop:** you can read the
expansion. `deploy/core/lighttable/bootstrap.js` is the compiled output of
every macro in the repo.

```bash
# change a behavior in src/, then:
lein cljsbuild once app
grep -n "__BEH__your_behavior_name" deploy/core/lighttable/bootstrap.js
```

Write a macro form, recompile, read the JavaScript it became. Very few
projects give you that this directly.

### 2. Data-oriented design, taken to the limit

Note the zeros in that table: **no protocols, records, types or `reify` in
15,000 lines.** Everything is maps, sets, keywords and functions. An object
is an atom holding a map. A tag is a keyword. The tags→behaviors index is a
map of keyword to list.

Most programmers coming from OO reach for protocols far too early. This
codebase is a large-scale existence proof that you frequently don't need
them. Seeing that at 15k lines rather than in a blog post changes your
defaults.

### 3. The hosted-language mental model

ClojureScript is a *compiler emitting JavaScript*, and compiled artifacts
embed decisions made at compile time. The keyword-hash saga documented in
`UPGRADE-RETROSPECTIVE-NOTES.md` is an unusually vivid demonstration:
`=` and `hash` are separate contracts, and it is possible to satisfy one and
violate the other. Most Clojure programmers never encounter this.

### 4. Reading unfamiliar Clojure

An underrated skill. A runtime-wired codebase with no call graph is the
hard-mode version of it.

---

## Where it will mislead you

The code predates, and therefore teaches nothing about:

- **`clojure.spec`** (2016) — which is precisely the answer to "how do you
  constrain data" that this architecture's central failure was crying out
  for. You will learn the *problem* here in depth and have to learn the
  solution elsewhere. (`malli` is the common modern alternative.)
- **Transducers**, **`core.async`**, **`deps.edn`**, **`shadow-cljs`**.
  Tooling here is `lein-cljsbuild`, which is legacy.
- **Testing.** There are no tests, so nothing to learn about `deftest`,
  fixtures, or generative testing.

Two further caveats:

- **455 lines of JS interop.** A genuinely useful skill, but not the core
  language, and not transferable to JVM Clojure.
- **Almost no pure functional code.** The codebase is nearly all effects on
  global atoms. There is very little functional-core/imperative-shell and
  very little transformation-pipeline work.

And some of what you will read is simply **bad practice** — global mutable
registries, swallowed exceptions, unstructured god-maps, singleton vars
racing their own constructor. Fine when read critically; harmful if absorbed
as "this is how it is done." Read `UPGRADE-RETROSPECTIVE-NOTES.md`'s
architecture section first so you know which parts are the warning.

---

## Complementarity with 4clojure

4clojure drills pure functions, sequence manipulation, `reduce` / `map` /
threading — expressiveness *in the small*.

This codebase is the opposite half: structure *in the large*, macros, state
management, interop, and how a real system decays over a decade.

The two fit together unusually well. The gap neither covers is **spec,
tests, and how to keep a large Clojure system honest** — worth picking up
deliberately from somewhere else.

---

## A concrete path in

### Don't read it front to back

Build something in it. The best available exercise is the highest-value item
on the improvement list in the retrospective:

> **Implement wiring validation: warn on unknown behavior names and unknown
> tags.**

It is a good learning vehicle because it is small and bounded, forces you to
understand the `behavior` macro and the registries, has an unambiguous
success criterion (introduce a typo, see a warning), and genuinely improves
the repo.

**Orientation for it:**

- `src/lt/objs/settings.cljs:107` — `parse-behaviors`, where a `.behaviors`
  file becomes data. Note the existing error path on `:111`: it validates
  *shape* (vector or map) but never *contents*.
- `src/lt/objs/settings.cljs:85` — `map->flat-behaviors`, showing the
  `[:tag :behavior arg…]` entry format and how `-` subtraction is encoded.
- `src/lt/object.cljs` — the registries you would validate against:
  `object-defs`, `behaviors`, `tags` (all private atoms near the top).
- `src/lt/object.cljs:488` — `tag-behaviors`, where a tag→behaviors
  association is actually made.

**One real design wrinkle, worth thinking through before coding.** Naive
validation at parse time will produce false positives: user behaviors are
parsed before plugin JavaScript has loaded, so a plugin's behaviors are not
yet in the registry. A wiring check therefore wants to run *after* plugin
load — for example a pass over `@tags` comparing against `@behaviors` once
the plugin manager finishes — or to defer and re-check. Working out where
that hook belongs is most of the exercise, and it is the same ordering
problem that produced the `java-exe` bug described in the retrospective.

### Then: use the InstaRepl on LightTable itself

This is the part that is actually special, and it now works again.
`doc/workflow.md` describes evaluating LightTable's own source inside a
running instance — the loop the editor was designed around.

Heed the warning in `CLAUDE.md`: eval **individual top-level forms**, not
whole files. Re-evaluating `object.cljs` or `editor.cljs` wholesale
redefines core object types under the running app and will freeze or break
it.

### Suggested reading order, if you do read

1. `doc/BOT.md` — the intended mental model, from the authors.
2. `src/lt/macros.cljc` — all 134 lines. Small, and everything else assumes it.
3. `src/lt/object.cljs` — 548 lines, the whole core. Read `raise`/`raise*`
   and `update-listeners` closely; they are where dispatch actually happens.
4. One small behavior-heavy namespace, e.g. `src/lt/objs/notifos.cljs`, to
   see the pattern applied.
5. `src/lt/objs/editor.cljs` only when you need it — it is large and
   interop-heavy.

---

## Questions worth pulling on

- How does `raise` dispatch, and why does `:listeners` exist as a cache
  rather than being computed on demand?
- What does the `behavior` macro expand into, and what do `:debounce`,
  `:throttle` and `:exclusive` compile to?
- How does `background` move a function body into another process, and what
  does it do to the arguments on the way? (See the `Invalid arity: 3` bug in
  the retrospective.)
- Why are objects atoms-of-maps rather than records, and what does that buy
  and cost?
