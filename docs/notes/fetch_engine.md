# chartMaker - the fetch engine

Design thinking for a fetch engine that has not been designed. Moved here out of
`docs/design/build.md`, where it sat under a "Still to specify" heading and made a
specification read like a plan. It is not linked from any official document.

When this becomes a design it belongs in `build.md`, and this file should be deleted rather
than left to disagree with it.

## What exists today

The fill is **serial**. It walks the coverage enumerator, asks for each tile in turn, and
honours only the `min_interval_ms` a source declares. Every TSD also declares a
`max_concurrency` and nothing reads it, which is most of an order of magnitude of wall clock
on ground that has never been fetched.

Two properties of the current shape are worth keeping through any redesign, because they
came from somewhere:

- **Errors are never cached.** An absence the source asserted is recorded and never asked
  for again; a timeout or a refused connection is not, because it says nothing about
  whether the tile exists.
- **Resume is nearly free.** The request path is cache first, so an interrupted run asks
  the network only for what the previous run did not reach.

## The queue

Concurrency, interval limiting, retry policy, and the failure classification that tells a
rate limit from a missing tile from a dead source.

What makes this a design conversation rather than a change to a loop:

- **Concurrency turns pacing into a scheduler.** An interval between two sequential requests
  is arithmetic. An interval across several requests in flight, against several sources with
  different declared limits, is a scheduling problem with a queue in it.
- **Telling a rate limit from a dead source stops being optional** the moment several
  requests are in flight at once. Serially, a run can stop after a few consecutive errors
  and a person sorts it out. In parallel, the same policy either trips on one slow source or
  keeps hammering one that has started refusing.
- **Backing off on failure belongs here too, and composes in one direction only.** It may
  move below the user's advisory baseline, never above it. A fast advisory that could raise
  the rate would let the system accelerate back into the wall it just hit. This is the same
  `max()` rule the build configuration's advisory interval already follows.

## Resume

A run of thousands of tiles that is interrupted must continue rather than restart. The cache
makes this nearly free already. What is missing is the specification of **what a run records
about itself** - which is also what would let a run report where it stopped, rather than
leaving the cache as the only evidence.

## Where it lives

`dm_fill` walks the coverage and asks for every tile; `dm_fetch` retrieves one tile from one
source and has no control flow of its own. The engine is the thing between them, and the
layer rule says it sits at or above `dm_fill`, never inside `dm_fetch`.
