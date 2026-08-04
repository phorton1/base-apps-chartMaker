# chartMaker - build analysis and source probing

Design thinking for two things that have not been designed: what a build could measure while
it runs, and what a source can be measured for rather than asserted to be. Moved here out of
`docs/design/build.md` and `docs/design/tsd.md`, where they sat under "Still to specify" and
"Deferred and settled" headings. Not linked from any official document.

When either becomes a design it belongs in `build.md` or `tsd.md`, and this file should be
deleted rather than left to disagree with them.

## Build analysis, and the dry run that produces it

A build already reads every tile it will write, so the facts worth knowing are free at the
moment they pass through. Three are known to be worth collecting:

- **Repeated byte-identical tiles.** This is how a server that serves a "no data here"
  placeholder instead of a 404 confesses: its placeholder is one fixed image, so it repeats
  exactly. What is discovered this way is written into a TSD as an `absent_fingerprint`,
  which is the file that remembers.
- **The depth at which a level stops carrying information its parent did not already have.**
- **The resulting deepest genuinely-resolved zoom, per region rather than per source**,
  because it is a fact about ground and not about a server.

**The output is feedback rather than a decision.** It tells the author which zooms are worth
building, and the author sets `zmax`. That is the same position the application takes about
imagery depth everywhere else: the human decides, the machine guides.

What it must also be able to do is **act on its own findings against the cache** - pruning
levels that carry nothing, so disk is not held by tiles that will never be written to a
card. That is the user-facing shape of what `scripts/tool_prune_absent.pl` does today.

### Overzoom is a choice, not only a defect

Magnified imagery is not *wrong*. It is the provider's resampler instead of the plotter's,
and one may legitimately prefer it. What must not happen is shipping it **unknowingly**, at
four times the tiles per level, on a card whose space is the binding constraint.

**Detecting it needs no parent tile.** Downsample 2:1, upsample back, subtract: a near-zero
residual means the top octave is empty, which means the level was derived rather than
photographed. Per tile the measure is noisy - JPEG and flat water both kill high frequencies
- but aggregated over a zoom level, restricted to tiles with real variance, it separates
cleanly.

**The dependency question to settle before this is scheduled** is that the test needs a JPEG
decoder, in an application that deliberately refuses an image stack. That is the decision,
not the implementation.

## Source probing

What a TSD can be **measured** for rather than asserted to be: reachability, the format
actually served, real depth as against declared `zoom.max`, the fingerprints of any
placeholder tile, and whether the addressing order is right.

**Addressing order is testable rather than eyeballed.** Correlating one low-zoom tile
against a source already trusted collapses if rows and columns are transposed. The old
Python toolchain used ArcGIS's `/tilemap/z/y/x/h/w` endpoint for the depth question, which
answers "does this service hold tiles here" for a whole block in one request rather than by
downloading tiles and looking at them.

**Deliberately excluded: probing for where a server begins refusing.** Finding a rate limit
by walking into it is the behaviour that earns a permanent refusal, and no answer it
produces is worth that.

## The key store

SETTLED. What was open here - how a declared name resolves to a stored value, and what the
store is keyed by - is now specified in `docs/design/key_store.md`. It is keyed by
`key_name`, because one value serves every file that names it.
