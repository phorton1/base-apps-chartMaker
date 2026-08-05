# chartMaker - Cleanup

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)** --
**Cleanup**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

Two things accumulate that nothing else removes. Browsing to find a region fills the cache
with tiles no build will ever read, and surveying a service to see whether it holds anything
useful leaves a `.tsd` file behind whether or not it did. Neither is a fault, and both are
invisible: a cache is a folder of numbers, and forty source definitions look the same
whether one region uses them or none does.

Cleanup answers that, in the order the questions actually arrive. What is on disk, what
still uses it, and then what to remove.

It is in the **File menu**, below a separator, with the [Key Store](key_store.md) above it.
Neither belongs to the open set and both act on the user's own material on this machine,
which is what separates them from the region set commands above the line. Nothing here
needs a set open: a folder of tiles nothing uses is exactly the state somebody starts the
application in order to deal with.

## The row is the cache_key

Tiles are filed under a source's `cache_key` and not under the file that declares it, so a
list keyed by file would offer the same gigabytes twice under two names, and would have no
entry at all for a cache whose file is already gone. The unit is therefore the cache_key,
and a row carries the `.tsd` files that address it, which may be several and may be none:

- **del tsd** and **del cache**, the two things that can be ticked
- the **cache_key**
- the **files** addressing it, and whether they ship with the application
- **used by**, naming the regions
- **tiles**, **absent** and **size**

A row with no files is an orphan cache, which is what a renamed `cache_key` leaves behind. A
row with files and no tiles is a source that has never fetched anything.

## What counts as in use

Four things, and only the first is obvious:

- a region in any set names the source, so a build will read it
- a region in a set that is **not open** names it
- it is the **default source**, so it is drawing the map
- it **ships with the application**, so a new installation has it

The second is what makes the answer worth showing. The model holds the regions of the open
set alone, so a source used only by another set is invisible to everything else in the
application; the survey reads every set's folder to answer for all of them. The third is
what stops the imagery on screen being offered up for deletion. The fourth does not protect
a file, but it does keep it out of "check all unused", which would otherwise empty a fresh
installation in one click, every one of whose sources is unused until a region names it.

A subregion that inherits counts against the source it inherits, so a detail area keeps its
parent's tiles alive.

## The two sweeps

Neither is a deletion in the sense the two tick columns are, and both apply across every row
rather than to one, so they are stated above the list with the counts the survey found.

**Reclassify cached blanks.** A service that answers a request for ground it does not hold
with a 200 and a picture saying so gets those bytes fingerprinted in its `.tsd`, and from
then on a fetch records the tile as the absence it is. Tiles cached before the fingerprint
existed are still imagery. This converts one into a `.none` marker, which frees the bytes
and keeps the finding. It is not a delete: deleting would make the tile unknown again and
the next pass would fetch it back, at the cost of a request, to learn what is already known.
The fetcher applies the same rule lazily on the way out of the cache, so this changes what
is true of the disk rather than what is true of a build.

**Trim tiles outside every region.** The rendering cache going away, which is what it is
for: a browse is cheap to make again. It removes images only. The `.none` markers are not
imagery and are not trimmed - each one cost a request to learn, each one is nine bytes, and
removing them would spend bandwidth to free nothing.

A trim over a cache **no region anywhere uses** is refused rather than performed. Every tile
in it is outside every region, so the trim would empty the folder under a name that does not
say so. Deleting that cache outright is a legitimate thing to want and it is the column
beside it.

## The two deletions

They are independent on purpose.

Deleting a **cache** is only ever a cost decision. The tiles come back if they are wanted
again, so it needs no guard beyond the count and the size.

Deleting a **definition** is the one act here that can lose work that cannot be recovered by
fetching. It is a few kilobytes of authored text, often with a survey behind it, so it is
the column that carries "used by" and the column that starts unticked.

Deleting a source from the source tree opens the same dialog filtered to that source's
cache_key. The file it was asked about is already ticked, its tiles are offered beside it,
and where a second `.tsd` addresses the same cache the tiles are kept and the dialog says
which file they are shared with.

## The preflight is the survey

The count and the size in front of the button are what the act then produces, because the
same walk with the same rules produced both. Nothing recounts and nothing estimates.

The survey is a directory walk of every cache and a read of every set, so it runs on a
worker thread behind the progress dialog rather than freezing the window; so does the act.
Both can be cancelled, and a cancelled act reports what it had already done.

The regions of the **open set** are read from the model rather than from its folder, so a
region drawn and not yet saved keeps its tiles. What is on screen is what is kept.

## No automatic policy

Nothing here happens on its own. There is no preference that trims the cache on exit or
removes a source that stopped being used, because both would act on a region drawn tomorrow,
and for some services a re-request is not free. A cleanup is something a person asks for
while looking at what it would do.

---

**Next:** [Implementation](../implementation.md)
