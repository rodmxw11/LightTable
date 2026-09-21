# Upgrading the InstaRepl / Clojure plugin runner to JDK 17

Notes on what it would take to remove the Java 8 requirement documented in
`UBUNTU-START.md` and `UPGRADE-RETROSPECTIVE-NOTES.md`.

## Root cause, precisely

`deploy/plugins/Clojure/runner/target/lein-light-standalone.jar` isn't built
by our `script/build.sh` — it's a prebuilt ~15MB uberjar checked into the
upstream `LightTable/Clojure` repo (cloned at tag `0.3.3`). It's AOT-compiled
from `runner/project.clj`, which pins `leiningen "2.5.2"`. That version's
transitive `dynapath`/`pomegranate` classes have compiled-in type references
to `sun.misc.Launcher$ExtClassLoader`, used for the classloader tricks
Leiningen normally relies on. That class was removed in Java 9, so the JVM's
class verifier fails as soon as those classes get touched — hence the crash
happening at bare startup, not at some deeper dispatch point.
`runner/src/leiningen/light_nrepl.clj` (LT's thin wrapper) calls
`leiningen.core.project`/`leiningen.repl` directly in-process rather than
shelling out the way the real `lein` launcher does, so there's no subprocess
boundary to hide behind.

## What it would take, in order of effort

1. **Fork `LightTable/Clojure`** (no push access upstream, and CONTRIBUTING
   already establishes the pattern of forking for these fixes) so
   `runner/project.clj` can be edited and the jar rebuilt.
2. **Try the narrow fix first**: override just `[dynapath "1.0.0"]` (or
   newer) in `project.clj`'s deps, keeping Leiningen at 2.5.2 — Maven-style
   nearest-wins resolution should let a JDK9+-safe dynapath shadow the
   broken transitive one, with minimal risk to `light_nrepl.clj`'s API
   usage.
3. **Rebuild the jar** with `lein uberjar` — ironically this step still
   needs JDK 8 (or at least a JDK the old Leiningen tool itself tolerates)
   to run, even though the *output* jar would then run on 17. That's a
   one-time build-machine constraint, not a runtime one.
4. **If the narrow override doesn't fully clear it**, fall back to bumping
   `leiningen` itself to a modern release (2.9.x+), which will likely
   require adapting `light_nrepl.clj`'s calls into
   `leiningen.core.project`/`leiningen.repl` since those internal APIs have
   drifted since 2.5.2.
5. Point `script/build.sh`'s `PLUGINS` entry for `Clojure` at the fork/tag
   instead of `https://github.com/LightTable/Clojure`, same as the existing
   `ClojureInstarepl` linking logic already assumes a matching jar.
6. Re-verify on both platforms: rebuild, launch with plain JDK 17 on `PATH`
   (no Java 8 fallback), open an InstaRepl, confirm `(+ 40 2)` evaluates —
   the exact check already documented in `UBUNTU-START.md`.

## Recommendation

Try the narrow dynapath-override patch first since it's cheap to disprove;
fall back to a full Leiningen version bump only if that doesn't actually
kill the JDK 8 dependency.
