# chartMaker - Deployment

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Design](design/readme.md)** --
**[Implementation](implementation.md)** --
**Deployment**

chartMaker runs in two environments - from source during development, and from the Windows
installer once packaged. This document is the program as a **deployed artifact**: where it
keeps the user's material, where it keeps its own, what an installation places, and what a
release is made of.

## Two environments, one program

The two differ only in where they keep their files. The switch is
`$Cava::Packager::PACKAGED`, and the directories come from `Pub::Utils`, which resolves them
once at startup:

| Directory       | Development                  | Installed                                       |
| --------------- | ---------------------------- | ----------------------------------------------- |
| `$data_dir`     | `/base_data/data/chartMaker` | `Documents/phorton1/chartMaker`                 |
| `$temp_dir`     | `/base_data/temp/chartMaker` | `AppData/Local/phorton1/chartMaker`             |
| `$resource_dir` | `_res` in the source tree    | resolved by Cava from inside the installed app  |

The `phorton1` publisher segment appears only in the installed paths, where the application
is a guest in the user's own directories and needs a namespace of its own. In development
`/base_data` is already a private namespace, so it adds nothing.

Nothing else differs between the two. There is no packaged-only code path and no
development-only feature - only environment-keyed defaults, which is what keeps the
installed application testable by running the development one.

**`CHARTMAKER_PROFILE` is one more such default**, and it moves **both** roots to a suffixed
sibling - `chartMaker.manual` for `CHARTMAKER_PROFILE=manual`. Moving `$temp_dir` with
`$data_dir` is what makes a profile independent rather than cosmetic: the ini holding the
selections, the single-instance lock and the observation records all live there, so two
profiles that shared it would contend for all three. Because they do not, **two profiles run
at the same time** - which is the case it exists for, an application whose panes hold nothing
but the shipped material, beside one holding real work. The port and the cache location are
ordinary preferences and are set in the profile's own `chartMaker.prefs`.

## `$data_dir` - the user's material

`$data_dir` holds everything the user authored or acquired, and nothing chartMaker can
regenerate:

- **Region sets** - `region_sets/<set>/`, one folder per chartset. The files present in a folder
  ARE the set; there is no index, so dropping in a region somebody sent you is the whole of
  adding it. Each file is one region: geometry, nesting, and the depth each area deserves.
  See [Design: Regions](design/regions.md). One set ships - the example the
  [user manual](../user_manual/readme.md) is written against - installed under the same
  existence guard the `.tsd` files use, and restorable from
  `Help - Restore Shipped Sources and Examples`.
- **TSD files** - `sources/*.tsd`, the tile source definitions the application can build
  from. Found the same way, for the same reason. See [Design: TSD](design/tsd.md).
- **The key store** - the values for those sources whose urls need one.

There is deliberately **no index file** in `$data_dir`. What a scan cannot answer is which
set and which source are *selected*, and those are per-machine facts that live in the
application's ini in `$temp_dir` - not in the user's own material, where they would travel
to another machine and be wrong there.

It lives in **My Documents deliberately**. This is the user's own work: it is what they
would want backed up, carried to another machine, or handed to another mariner. Putting it
anywhere else - buried in AppData, or inside the installation - would make all three of
those harder and would misrepresent whose data it is.

## The key store

A TSD declares **key names** and never contains a key value, so the values themselves need
somewhere to live. That somewhere is `chartMaker.keys.json`, a flat JSON object of
`key_name` to `key_value`, which sits in `$data_dir` by default and whose **folder is
relocatable by preference**. See [Design: Key Store](design/key_store.md).

The preference is the point. The default keeps a user's own keys with the rest of their own
material, where they will not be lost or forgotten. But `$data_dir` is a backed-up and
frequently a cloud-synced location, and a user who does not want their keys copied to a
sync service - or who would rather keep them on removable media, or on an encrypted
volume - needs somewhere else to put them without giving up the default for everything
else. Splitting the store's location from `$data_dir`'s costs one preference and settles
the question for every user in either camp.

**The preference names the folder and the file name is a constant**, so there is never a
second setting for one thing. The name is namespaced by the application for a reason that
only appears once the folder has been moved: an encrypted volume or a USB stick is exactly
the sort of place something else has already left a `keys.json`.

**It is plain text and the dialog says so.** A key this application uses unattended has to
be recoverable by this application, so encrypting it under another key kept beside it would
be theatre. The folder is the real answer.

## Every folder is a preference

The six trees chartMaker reads and writes are each a preference, and each defaults to a
leaf under `$data_dir` - except the key store, whose default *is* `$data_dir`, because it
is one file rather than a tree:

```
    SOURCES_DIR       $data_dir/sources          the .tsd files
    REGION_SETS_DIR   $data_dir/region_sets      one folder per set
    MBTILES_DIR       $data_dir/mbtiles          built chartsets
    RASTER_DIR        $data_dir/raster           built .rct files, one folder per set
    CACHE_DIR         $data_dir/cache            fetched tiles
    KEYS_DIR          $data_dir                 holds chartMaker.keys.json
```

**`$data_dir` itself is deliberately not a preference.** The preferences file lives in it,
so a preference naming it could not be read without already knowing it. That single fact
fixes the order of operations: establish `$data_dir`, read the preferences, then resolve
every folder from them.

**The folder defaults are computed on every read, never stored.** Two things follow, and
both matter. A folder line appears in `chartMaker.prefs` only when somebody actually sets
one, so the file stays a statement of what was *changed* rather than a snapshot of
everything. And a headless test can point the whole application at a fixture directory by
assigning `$data_dir` alone.

**The application creates only the folders it chose the location of.** A preference naming
a folder that is not there is reported, never made: a missing path is far more likely to be
a typo, an unmounted drive, or a preferences file copied from another machine than an
instruction to build an empty tree somewhere unexpected - and building it would look like
success while hiding the real one.

## The tile cache is not temporary

The cache defaults into `$data_dir` rather than `$temp_dir`, and the distinction is
deliberate: *temp* is a promise that anything may delete it, and these tiles are bandwidth,
wall clock, and for some sources requests that should not be repeated. Reconstructible is
not the same as disposable.

```
    <CACHE_DIR>/<tsd_leaf_name>/<z>/<x>_<y>.<ext>
```

**The source key is not optional.** A tile is identified by its z/x/y coordinate, and that
coordinate means something different in every source. A cache without a source dimension is
cache-first by nature and will silently answer a request for one source's tile with another
source's image - producing a build that looks complete, contains the wrong imagery, and
gives no indication that anything went wrong. Keying the cache by source makes that failure
structurally impossible rather than merely unlikely.

The key is the TSD's **`cache_key` field**, which defaults to the **leaf name of the `.tsd`
file** when the file does not declare one - the file name, not the `id` inside it. The
default makes the mapping legible in a file browser: a user can look at the cache, see one
folder per source they have used, and delete exactly one of them.

**Declaring it is what makes a `.tsd` file movable.** Tiles are the expensive and persistent
thing in this application, and a file is a container: renameable, copyable, and about to
become editable. A key that is only ever a shadow of the container strands gigabytes on a
rename and starts a fresh cache for every saved variant of one source. A declared key also
lets several files - an edit in progress, a backup, a variant differing only in `uses` -
address the same tiles deliberately.

Two properties of `$temp_dir` are worth stating because they are inherited rather than
chosen: it is **never cleaned up automatically**, and it is **not process-specific**.
Anything that must be per-instance has to carry the process id in its own name.

## The observation record

The tier between a TSD and the cache. A TSD is **declared**, shareable and protocol-level: it
says what is true wherever the source is reachable, and a person wrote it. The cache is
**discovered** and per tile: it says what is at one coordinate. Neither has a home for a
discovered fact about the **server** - how fast it answers this connection, whether it has ever
rate limited us, whether its declared ceiling is honest - which is what both the fetch engine
and the probe need.

```
    $temp_dir/observations/<cache_key>.json
```

**Keyed by the same `cache_key` the cache uses**, so a user has one name per source rather
than two and can prune both together. The two move together in every case: whatever reaches
one reaches the other, and a source whose key changes leaves both behind at once, which is
at least coherent and costs one run's measurements.

**In `$temp_dir` because losing it is cheap.** It is a fact about this computer's connection to
that server at this time of day, not about the user's material; carried to another machine it
would be wrong, and every value in it re-converges within a run or two.

**Bounded by construction, and that is a commitment.** Everything continuous is a smoothed
average, which deliberately forgets; everything event-shaped is a ring of the last few. A
record is a dozen scalars and two short lists, permanently, however long the program runs.
What grows without bound is the cache, and it always did - that is the user's real survey, and
this is the small bounded thing beside it. Nothing **placed** ever belongs here: a per-location
finding would need a spatial index, would go stale, and would recreate the declared coverage
the TSD format refuses.

**One file per source, and a dirty bit per source.** That gives no read-modify-write contention
between threads touching different sources, a truncated write that loses one source's
observations rather than all of them, and room for one source's content to grow without any of
the others caring. A flush writes nothing at all in the common case.

**The in-memory copy is the live one and the file is a checkpoint of it** - the opposite
arrangement from the cache, and right here for the same reason it is wrong there: losing the
last few seconds of timing observations costs nothing, and losing a tile costs a fetch. Every
in-process reader uses the live structure and never the file, so nothing is ever waiting on a
flush. It flushes on a clock, at the end of any bounded act, and at exit; browsing has no end,
so without the clock a session that only panned the map would never record what it measured.

**Nothing here ever edits a TSD.** A person promotes a finding into a file, deliberately. That
keeps "declared, not detected" intact while still making detection worth doing - and it is
load-bearing for the one finding that could otherwise cause real damage: a source that answers
with the same bytes over and over is *probably* saying "no tile", but a source that legitimately
serves identical tiles - solid ocean, a uniform icecap - would have real imagery declared
missing, and nothing downstream could tell.

## Running both at once

Because both environments resolve to different roots, a development chartMaker and an
installed chartMaker run side by side without touching each other's files.

The same has to hold for anything else the two would otherwise contend for, and the
**HTTP server port** is the one that bites: two servers cannot bind the same port, so
without an environment-keyed default the second application to start simply fails. The
defaults are **9884 in development** and **9874 when installed**, and like the key store
location, the port is a preference and can be overridden.

## Two of the same kind are refused

Development beside installed is supported. **Two copies of the same one are not**, and the
second is stopped before it has done anything rather than left to discover the problem in
pieces. They would otherwise share one HTTP port, one ini holding the selections, and one
tile cache written by two processes each believing it was alone.

The guard is an exclusive `flock` on a file in `$temp_dir`, taken before the worker pool is
spawned or the port is bound, and reported in a dialog because at that moment there is no
window and no log anyone is watching. Two properties fall out of the mechanism:

- **The lock is released by the operating system when the process ends**, however it ends, so
  a crash leaves nothing stale behind. A recorded process id could not promise that - after a
  crash there is no way to tell a live instance from a dead one whose id has been reused.
- **`$temp_dir` is already environment-keyed**, so development and installed take different
  locks and coexist without a rule of their own.

The check lives in `Pub::SingleInstance` rather than in the HTTP server, because being the
only copy is a property of an application and not of a port - and because it has to happen
before the server starts, which is the wrong side of the server to live on.

## When the port is not available

A taken port is **not fatal**. Without the server there is no map, no tile proxy and no web
API, but the region tree, editing, preferences and a build from what is already cached all
work, so the application starts and says what is missing rather than refusing to run.

Saying so at all takes some care, because the bind does not happen where anyone can see it.
The server binds on its own thread, after `start()` has returned, so there is nothing for
`start()` to hand back; and a worker thread must not raise a dialog even if a window existed
by then, which it does not. So the thread **records** the outcome against the port and the
main thread reads it once the frame is up. The report therefore arrives after the window is
showing, deliberately - a modal thrown over a blank screen reads as "it failed to start",
which is exactly what did not happen.

The map menu item explains itself for the rest of the session rather than doing nothing,
which is the part that stops a dismissed warning from becoming a mystery. The outcome is
settled at startup and is not re-tested, so freeing the port does not restore the map until
the next run.

## The two executables

The installed application ships twice: one executable running under `perl`, with a console
window, and one under `wperl`, without. They are the same program.

The console build is where the application's output is visible. There is deliberately **no
monitor pane** - the console window is the monitor, and shipping the console build means
that surface is available to an installed user and not only to a developer. When something
looks wrong in the windowed build, the answer is to run the other one.

Output is not written to a file. `Pub::` supports it - it needs only the shared `$logfile`
variable set - so it is a candidate for the preferences dialog rather than a second
mechanism.

## What an installation owns, and what it does not

The division is the whole of what makes an uninstall safe:

| Lives in | Holds | On uninstall |
| -------- | ----- | ------------ |
| the installation | the executables, the bundled Perl, `_res` | removed |
| `$data_dir` | region sets, TSDs, the key store, built output, the cache | **kept unless asked for** |
| `$temp_dir` | the ini, the per-source observation records | removed, silently |

**Nothing the user authored is inside the installation**, which is why an upgrade is an
install over the top and a removal takes nothing away that anybody typed.

`$temp_dir` goes without a question because there is nothing in it to ask about: every value
it holds is derived and re-converges within a run or two of the next installation.

**`$data_dir` is a question, and the question states what it is about to destroy.** The
folder is walked before the prompt is shown and the prompt names the file count, the total
size, and separately the number of **cached tiles**, because that is what makes this
different from asking about a document folder. Tiles are bandwidth, wall clock, and for some
sources requests that should not be repeated - a survey that may have taken hours - and a
user who answered Yes to a bare "delete your data folder" would not know that is what they
were discarding. It defaults to No.

The walk is why the uninstaller says it is working first: a large cache is hundreds of
thousands of files, and enumerating them is not instant.

**It asks about the folder rather than about the preferences**, and the distinction is real.
Every tree is relocatable, so a user who moved `CACHE_DIR` elsewhere has tiles the
uninstaller will neither count nor delete. Reporting only what is actually in the folder it
is actually about to remove is the only claim it can make honestly.

## Version scheme

A version is `major.minor.release`. A leading `0.` marks a pre-release, where formats may
change and a release is throwaway. **`1.0.0` is the contract line**: from it, releases are
permanent and the `.tsd`, `.region` and `.RCT` formats become a backward-compatibility
commitment, which is what the `tsd_version` and `region_version` fields exist to carry.

**Which version is current is not stated here.** The release log in
[`releases/`](../releases/readme.md) is the record of what has been released, and a number
written into any other document is a second account of it that will eventually disagree.

## A release is a tag in four repositories

A build is made from four repositories, and a release stamps the **same tag string**,
`chartMaker<version>`, across all four. `git checkout chartMaker<ver>` in each reconstructs
exactly the source a release was built from.

| Repository | Path | GitHub | Gets |
| ---------- | ---- | ------ | ---- |
| chartMaker | `C:\base\apps\chartMaker` | base-apps-chartMaker (public) | the tag, and the GitHub Release |
| Pub | `C:\base\Pub` | base-Pub (public) | the tag, as provenance |
| base_dist/chartMaker | `C:\base_dist\chartMaker` | base_dist-chartMaker (private) | the tag, as provenance |
| Perl | `C:\Perl` | Perl (private) | the tag, as provenance |

**The private ones are tagged and pushed too.** A provenance freeze with a hole in it
freezes nothing, and two of the four things a build is made from are private.

Only chartMaker gets an actual Release, with the installer as its asset. The repository
itself stays text-only: `/releases` holds the release **log**, not the installers.

**Anything linking to a download points at the `/releases` PAGE and never at
`latest/download`.** GitHub excludes a pre-release from `latest`, so a one-click link to the
newest asset would resolve to nothing at all for as long as this is below 1.0. Pointing at
the page costs the reader one click and has the side effect of putting the pre-release
marking in front of them on the way past. At `1.0.0` that reverses and a direct link becomes
correct.

**The tag IS the provenance, and nothing else records it.** No list of commit hashes is
written anywhere - not in the log, not in the release notes. A hash block is a second
account of what the tags already say exactly, it has to be transcribed by hand at the one
moment when care is most expensive, and being wrong is indistinguishable from being right
until somebody tries to reconstruct a build. `git checkout chartMaker<ver>` in each of the
four is the whole mechanism.

**The log is not a changelog.** One row per release, and optionally a few lines of
highlights. Every release is tagged in every repository, so `git log chartMaker<old>..<new>`
reconstructs the changes on demand and no second account of them has to be maintained.

The packaging procedure itself - the toolchain, its configuration, and the steps that turn
the source into an installer - is in [Installer](installer.md).

---

**Next:** [Home](readme.md)
