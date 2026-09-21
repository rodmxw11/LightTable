# Retrospective: why this upgrade was hard

Notes written after bringing LightTable from Electron 13.1.2 to 44.4.3 and
restoring a working Clojure InstaRepl on the `claude-lighttable` branch.

`ELECTRON-UPDATE-PLAN.md` is the blow-by-blow record of *what* was done.
This document is the *why it cost what it did*, aimed at whoever picks this
up next — including a future me who has forgotten all of it.

---

## The short version

**The Electron upgrade was not the hard part.**

Electron 13 → 44 was largely mechanical and went roughly to plan:
`remote` → `@electron/remote`, an explicit `webPreferences` block,
promise-ified dialogs, a handful of renamed APIs (`openItem` → `openPath`,
`moveItemToTrash` → `trashItem`, `getUrl` → `getURL`). It is a well-trodden
migration with good upstream documentation.

What consumed the effort was a decade of accumulated rot *underneath* it,
which the Electron work merely became the first thing in years to exercise.
Nearly every one of those problems failed **silently** — returning `nil`
rather than raising — in an architecture with no compile-time checking and
no test suite.

---

## One commit planted most of it

`f9ef736`, 2021-04-10, titled **"Use updated libraries"**. That single
commit did three things, none of them visible as a risk in its diff:

| Change | Consequence | Discovered |
|---|---|---|
| ClojureScript → 1.10.844 | Keyword hashing changed, breaking the ABI with every precompiled plugin | 2026, this branch |
| `crate` → `singultus` | The `crate.*` global every plugin builds DOM with ceased to exist | 2026, this branch |
| (same cljs bump) | `cljs.reader/read-string` became multi-arity, killing every `background` worker | 2026, this branch |

Three of the five bugs fixed in commit `4db8e83` trace to that one commit.

The third is a good illustration of how this happens. The offending line —
`(.map orig# cljs.reader/read-string)` in `src/lt/macros.cljc` — was written
in `c5e88c6` (2018-12-27) and was **correct at the time**. `Array.prototype.map`
calls its callback with `(element, index, array)`; single-arity compiled
ClojureScript functions ignore extra arguments. The 2021 cljs upgrade made
`read-string` multi-arity, and a 3-argument call then threw
`Invalid arity: 3`. Nobody changed that line; the ground moved under it.

---

## Nobody noticed because the project was already dormant

Commits per year on `develop`:

```
2014: 790     2017:  12     2020: 14
2015: 197     2018:  19     2021: 16
2016: 112     2019:  14
```

After `f9ef736` there were **13 more commits, then nothing** — the last is
`000cc9b`, 2021-06-25, about ten weeks later.

So a routine dependency bump landed three latent breakages into a repo with
almost no remaining activity to surface them. This is not carelessness. It
is the normal fate of maintenance commits on a project whose maintainers
have stopped using it daily: the change is reasonable, the test is "does it
still build", and it did.

Other pre-existing breakage found along the way, none of it Electron-related:

- **`5442e92` (2020-02-10)** deleted `deploy/core/node_modules/codemirror_addons/`,
  which three call sites still loaded (`editor.cljs`, `find.cljs`,
  `auto_complete.cljs`). Find/replace and autocomplete had been dead since.
- **`cljsDeps.js` was never built** — `lein cljsbuild once cljsdeps` was
  commented out in `script/build.sh`, while `threadworker.js` unconditionally
  read the file it produces. Every `background` call site was dead code.
- **The app did not boot on Electron 13 either.** It was missing the
  `webPreferences` it needed. The "it doesn't work on new Linux" premise was
  true but incomplete; it didn't work anywhere.
- **`ClojureInstarepl` was never added to the build.** The Clojure plugin's
  CHANGELOG at 0.3.0 says *"Split out instarepl into its own plugin -
  ClojureInstarepl."* `script/build.sh` installed seven plugins and not that
  one. A 2015 packaging oversight that shipped and was never caught.

---

## The structural reason: an unversioned ABI nobody knew existed

This is the deep cause, and it is worth understanding before touching
anything here.

**LightTable's plugins ship compiled JavaScript, not source.** Compiled
ClojureScript bakes in compile-time constants — including, for every keyword
literal, a precomputed hash:

```js
new cljs.core.Keyword(null, "instarepl", "instarepl", 1043123260)
```

That hash is a *compiler implementation detail*, and it changed between the
ClojureScript the bundled plugins were built with (~2014–2015) and core's
1.10.844. Measured on a live instance:

| Keyword | From plugin JS | Freshly interned | `=`? |
|---|---|---|---|
| `:instarepl` | `1043123260` | `-1983907341` | yes |
| `:clojure.lang` | `240089642` | `-1686276330` | yes |

They are equal. They print identically. Hash maps and sets navigate by
**hash**, so every lookup misses — in both directions, since core also can't
find keys a plugin wrote and a plugin can't find keys core wrote.

This is a binary-compatibility problem in an ecosystem that does not think of
itself as having binaries. There is no ABI version, no load-time check, no
warning — and the failure mode is `nil`, not an exception.

### Why that was so expensive to chase

Layer LightTable's BOT architecture on top. Behaviors are wired to objects by
**keyword names written as data** in `.behaviors` files, resolved at runtime.
That is what makes the editor live-editable, and it means:

- no compile-time verification that any wiring is valid
- no static analysis; plain `grep` genuinely misses usages
- a registered-but-unreachable command is indistinguishable from a missing one

Concretely, the shapes this took:

- Every **plugin-registered command** was unreachable from the command bar
  and from `exec!`. Registration succeeded. Nothing threw.
- Objects were **created without ever being initialized**: `make-object*`
  merged plugin-supplied kwargs over core's defaults without normalizing
  keys, so a plugin's `:init` and core's `:init` were *different keys*, the
  defaults overrode nothing, and `(:init obj)` found neither. This is why
  the InstaRepl tab opened and rendered blank.
- Language objects (`clj_lang`, `python-lang`, `nodejs-lang`) had only
  `:destroy` wired, so `:eval!` was raised into the void.
- Plugins died with `crate is not defined` the moment they built DOM —
  loading without complaint, then rendering nothing.

And there is **no automated test suite**. QA is a manual checklist in
`doc/for-committers.md`. Regressions are invisible until a human exercises
that exact feature.

### The fix worth remembering

Per-boundary normalization (`lt.object/fresh-kw`, applied at each registry as
it was discovered) was the wrong shape, and discovery kept continuing —
behaviors, then tags, then the command registry, then `object-defs`. It also
**cannot** fix the plugin-reads-core direction at all: `(:ed @obj)` inside
plugin code, reading a key core wrote, misses no matter what core normalizes.

The general fix is one override, in `deploy/core/LightTable.html` immediately
after `bootstrap.js` loads and before `lt.objs.app.init()`:

```js
cljs.core.Keyword.prototype.cljs$core$IHash$_hash$arity$1 = function () {
    if (this.__ltRehashed !== true) {
        this._hash = cljs.core.hash_keyword(this);
        this.__ltRehashed = true;
    }
    return this._hash;
};
```

Plugins share core's single `cljs.core`, and `cljs.core/hash` always
dispatches through this protocol method, so recomputing from `ns`/`name`
repairs every stale keyword at once, in both directions. Core's own keywords
already hash to exactly that value, so it is a no-op for them.

**If you ever upgrade ClojureScript again, this shim is what keeps the
precompiled plugins working.** It is also the reason to be suspicious of any
future "just update the libraries" commit.

---

## Why InstaRepl in particular was the worst thing to revive

It is the one feature that touches nearly every subsystem:

```
CodeMirror + overlay modes  →  object/behavior wiring  →  command registry
  →  plugin loading  →  forked background worker  →  eval/client layer
  →  spawned JVM  →  nREPL socket  →  inline result widgets
```

It is effectively LightTable's full-stack integration test. "Get InstaRepl
working" was therefore never a feature request — it meant repairing every
link in that chain, and each repair only revealed the next break. That is
why the work repeatedly looked nearly done and wasn't.

Two of the blockers were also **environmental rather than code**, which no
amount of reading the source would have surfaced:

- **Java 8 is required.** `lein-light-standalone.jar` embeds Leiningen 2.5.2,
  whose `dynapath` references `sun.misc.Launcher$ExtClassLoader` — removed in
  Java 9. Verified failing identically on JDK 11, 17 and 21; working on
  Temurin 1.8.0_504 (`nREPL server started on port 64515`).
- **`ClojureInstarepl` was missing from the build** (above), and its compiled
  bundle redefines the `lt.plugins.clojure` namespace (222 references),
  loading *after* the Clojure plugin so its copy wins — including
  `jar-path`, which therefore resolves against the wrong plugin directory.

---

## Lessons

1. **Silent failure is the cost driver, not complexity.** None of these bugs
   was individually hard. Every one was hard to *find*, because a wrong
   answer and a correct answer looked the same. Time went into black-box
   verification over CDP, not into writing fixes.

2. **Verify against the running app, not the source.** Several confident,
   reasonable-looking conclusions were wrong, and only live inspection caught
   them (see "What went wrong in the process" below). In a runtime-wired
   architecture, reading the code tells you what *should* happen.

3. **Fix the mechanism, not the site.** Three registries were patched
   individually before the single `Keyword` hash override made all of them —
   and the unfixable reverse direction — moot. When the same bug appears
   twice, stop and look for the shared cause.

4. **Precompiled plugin distribution is the root architectural liability.**
   Shipping compiled artifacts against an unversioned compiler ABI is what
   turned a library upgrade into silent, years-long breakage. If this project
   were ever revived properly, building plugins from source at install time
   would eliminate an entire bug class.

5. **"Update the libraries" is a load-bearing commit.** On a dormant project
   with no tests, it is the highest-risk change available, and it looks like
   housekeeping.

---

## What went wrong in the process

Recorded honestly, because it is part of the cost:

- **An unverified claim caused a real regression.** Phase 2a recorded
  `overlay.js` as "a verbatim copy" of CodeMirror's upstream addon and
  repointed the loader at upstream. It is not: LightTable's fork passes a
  **third argument** that the Rainbow plugin reads. Against upstream, every
  syntax-highlight pass threw and aborted line rendering — the editor stopped
  visibly updating while typing. The claim survived a review pass that
  correctly caught the same error for `search.js` and `show-hint.js`.

- **Whack-a-mole before generalizing.** See lesson 3.

- **Diagnostics bitten by the bug under investigation.** Twice, a CDP probe
  read a `nil` caused by the very keyword-hash mismatch being fixed, and the
  wrong conclusion was believed briefly before being caught.

- **Recurring test-harness errors worth guarding against:** selecting
  `targets[0]` from CDP `/json` (webview guests are targets too — always
  match `title === "Light Table"`); querying a registry with the wrong key
  type after changing its key representation; wrapping module-level functions
  instead of the `:reaction` actually captured in the behaviors registry,
  which produces a misleadingly empty trace.

---

## Architecture: what is good, what is wrong, what would help

### It is not overly complex — it is under-constrained

A reasonable prior, on hitting bugs like these, is that the system must be
baroque. The measurements say otherwise. The entire BOT core — objects,
behaviors, tags, dispatch, hot re-apply — is **548 lines** in
`src/lt/object.cljs` plus 134 in `src/lt/macros.cljc`. There is no framework
bloat and no indirection for its own sake. The whole of `src/` is ~15,000
lines across 69 files, and the individual namespaces are small and readable.

The problem is the inverse of complexity: the codebase is **simple in the
small and unanalyzable in the large**. There are 469 behaviors across 68
core files, wired together through five global atoms by keyword names
resolved at runtime, and — verified by inspection — **nothing anywhere
validates that a named behavior or tag exists**.

### The central flaw: decoupling without contracts

BOT is maximally decoupled. Any behavior may attach to any tag, any object
may raise any trigger, and nothing imports anything.

That resembles modularity but is not. Modularity requires **interfaces** — a
module promising something that can be checked. BOT has none: a trigger is a
keyword, a behavior is a closure, and nothing declares what an object
provides, what a trigger's payload looks like, or what a behavior requires.
Decoupling without contracts is not modularity, only distance: all the cost
of indirection (no call graph, `grep` misses usages, no compiler help) with
none of the guarantee.

Three consequences, all hit during this work:

**Objects are unstructured god-maps.** An object is an atom holding an
arbitrary map. Any behavior from any plugin may `merge!` any key into any
object. No schema, no namespacing convention, no provenance. The Clojure
plugin writes `:java-exe`, core writes `:ed`, and when `(:ed @obj)` returned
nil there was no way to ask what was supposed to have set it.

**Errors become log lines and the app keeps running.** `raise*` catches
`:default` around every reaction and reports `Invalid behavior: X`. As a
resilience choice for a live-editable editor this is defensible — one bad
user behavior should not brick the app. Combined with the absence of
validation, though, it makes a half-wired application a *normal, stable
state*. Most of this work was conducted inside one.

**Singleton objects held in vars fight the object system.** `(def clj-lang
(object/create ::langs.clj))`, where `create` raises `:object.instant`
*during* the `def`, so a reaction that reads the global sees `undefined`.
The framework does the right thing — every reaction receives `this` — but
the architecture permits two ways to name the same object and does nothing
to discourage the broken one. See the `java-exe` wrinkle under "Current
state".

### What was genuinely good

The core instincts were sound, and are worth preserving in any rework:

- **Plugins use the identical mechanism as core.** No second-class extension
  API, no reduced-surface sandbox. This is why a plugin can restyle the
  editor or add a language as easily as core can. Most contemporaries got
  this wrong.
- **Data-file wiring is hot-reloadable.** Saving a `.behaviors` file
  re-applies it live. The "edit your editor while using it" thesis worked.
- **Namespaces are small and well factored.** The file-level organization is
  better than most projects of this size.
- **`:params` metadata already exists** on user behaviors to drive the
  settings UI — the declaration machinery needed for validation is present
  and simply unused for checking.

### Improvements, cheapest first

1. **Validate wiring at parse time.** Roughly an afternoon's work and by far
   the highest value. When parsing `.behaviors`, warn on unknown behavior
   names and unknown tags. This alone would have surfaced the entire
   keyword-hash class immediately, along with an orphaned `::console-log`
   rename found earlier in this upgrade. The single change most likely to
   have prevented this whole episode.
2. **Build plugins from source at install time.** Permanently eliminates the
   compiled-ABI bug class described above. `script/build.sh` currently clones
   a repo and uses its checked-in `*_compiled.js`.
3. **Namespace object keys** — `::clj/java-exe` rather than `:java-exe`.
   Idiomatic and cheap in ClojureScript; makes collisions impossible and
   provenance greppable.
4. **Use `this`; delete the singleton vars.** Behaviors already receive the
   object they act on.
5. **Commit a black-box smoke harness.** One was built ad hoc during this
   work: CDP scripts driving a real packaged build and asserting on real DOM.
   Roughly twenty assertions — app boots, editor renders, find works, a
   behavior fires, a background worker returns — would cover most of the
   value, starting from zero tests today.
6. **Declare trigger payloads**, even as documentation-only metadata on the
   `behavior` macro, so a trigger like `:eval!` has a stated shape.

### Available simplifications

- **Five global atoms could be one.** `obj-id`, `instances`, `object-defs`,
  `behaviors` and `tags` are one registry with five keys; as five independent
  atoms they are five independent opportunities to be inconsistent.
- **`:listeners` is a denormalized cache** of tags→behaviors, recomputed on
  every mutation and stored per object. It is a performance optimization that
  creates a consistency hazard, and stale listeners were a recurring symptom
  during this work. Compute on demand; memoize only if profiling justifies it.
- **The `background` macro hand-marshals arguments** via `pr-str` /
  `read-string` across a process boundary, with no schema, for three call
  sites. This is exactly where the `Invalid arity: 3` bug lived.

### Summary

This is not a badly designed system. It is a research prototype that shipped
and was subsequently *maintained* rather than *finished*. The dynamism was
the whole point, and it bought something still rare: an editor where
evaluation is woven into editing rather than bolted alongside it. What never
arrived was the second half — the validation, contracts and tests that make a
late-bound system maintainable rather than merely flexible. For five years of
active use that trade was invisible. It came due all at once.

---

## Current state

Working, verified on Windows: editor and rendering, find/replace,
autocomplete, background workers (workspace search, fuzzy navigate),
browser-tab CSS/CLJS eval, console capture, and an InstaRepl evaluating
`(+ 40 2)` to an inline `42` with `Connected to LightTable-REPL`.

Not yet verified on Linux — see `UBUNTU-START.md`, which is written but
untested on an actual Ubuntu machine.

Known remaining wrinkle: the Clojure plugin's `java-exe` user behavior is
`:object.instant` and its reaction ignores its `this` argument in favour of a
global that `object/create` has not yet assigned when it raises
`:object.instant`. It therefore applies only after behaviors are re-applied
(any `.behaviors` save). Putting a Java 8 `java` first on `PATH` avoids the
issue entirely.

## See also

- `ELECTRON-UPDATE-PLAN.md` — the full plan and phase-by-phase record
- `UBUNTU-START.md` — clone/build/run on Ubuntu, and the Java 8 requirement
- `CLAUDE.md` — orientation, including the two compatibility shims
- `doc/BOT.md` — the Behaviors/Objects/Tags architecture
