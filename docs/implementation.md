# chartMaker - Implementation

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Design](design/readme.md)** --
**Implementation**

Where [Design](design/readme.md) describes the structures, this document describes the code
that implements them.

## Installed versus Development Versions

chartMaker runs in two environments - from source during development, and from the Windows
installer once packaged - and they differ only in where they keep their files. The switch
is `$Cava::Packager::PACKAGED`, and the directories come from `Pub::Utils`, which resolves
them once at startup:

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

### `$data_dir` - the user's material

`$data_dir` holds everything the user authored or acquired, and nothing chartMaker can
regenerate:

- **Region sets** - `region_sets/<set>/`, one folder per card. The files present in a folder
  ARE the set; there is no index, so dropping in a region somebody sent you is the whole of
  adding it. Each file is one region: geometry, nesting, and the depth each area deserves.
  See [Design: Regions](design/regions.md).
- **TSD files** - `sources/*.tsd`, the tile source definitions the application can build
  from. Found the same way, for the same reason. See [Design: TSD](design/tsd.md).
- **The credential store** - the secrets for those sources that require one.

There is deliberately **no index file** in `$data_dir`. What a scan cannot answer is which
set and which source are *selected*, and those are per-machine facts that live in the
application's ini in `$temp_dir` - not in the user's own material, where they would travel
to another machine and be wrong there.

It lives in **My Documents deliberately**. This is the user's own work: it is what they
would want backed up, carried to another machine, or handed to another mariner. Putting it
anywhere else - buried in AppData, or inside the installation - would make all three of
those harder and would misrepresent whose data it is.

### The credential store

A TSD declares credential **slots** and never contains a credential value, so the values
themselves need somewhere to live. That somewhere is the credential store, which sits in
`$data_dir` by default and is **relocatable by preference** to any folder the user
nominates.

The preference is the point. The default keeps a user's own keys with the rest of their own
material, where they will not be lost or forgotten. But `$data_dir` is a backed-up and
frequently a cloud-synced location, and a user who does not want their keys copied to a
sync service - or who would rather keep them on removable media, or on an encrypted
volume - needs somewhere else to put them without giving up the default for everything
else. Splitting the store's location from `$data_dir`'s costs one preference and settles
the question for every user in either camp.

**The mechanism by which a TSD's declared slot resolves to a stored credential is not yet
specified** - neither the store's format nor how a slot is bound to an entry in it. Only
its location is settled here.

### Every folder is a preference

The five trees chartMaker reads and writes are each a preference, and each defaults to a
leaf under `$data_dir`:

```
    SOURCES_DIR       $data_dir/sources          the .tsd files
    REGION_SETS_DIR   $data_dir/region_sets      one folder per set
    MBTILES_DIR       $data_dir/mbtiles          built chartsets
    RASTER_DIR        $data_dir/raster           built cards, one folder per set
    CACHE_DIR         $data_dir/cache            fetched tiles
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

### The tile cache is not temporary

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

The key is the **leaf name of the `.tsd` file** - the file name, not the `id` field inside
it. That choice makes the mapping legible in a file browser: a user can look at the cache,
see one folder per source they have used, and delete exactly one of them. The cost is that
renaming a TSD orphans its cache directory, which costs a refetch and nothing else.

Two properties of `$temp_dir` are worth stating because they are inherited rather than
chosen: it is **never cleaned up automatically**, and it is **not process-specific**.
Anything that must be per-instance has to carry the process id in its own name.

### Running both at once

Because both environments resolve to different roots, a development chartMaker and an
installed chartMaker can run side by side without touching each other's files.

The same has to hold for anything else the two would otherwise contend for, and the
**HTTP server port** is the one that bites: two servers cannot bind the same port, so
without an environment-keyed default the second application to start simply fails. The
defaults are **9884 in development** and **9874 when installed**, and like the credential
store location, the port is a preference and can be overridden.

## The HTTP Surface

The embedded server answers two unrelated audiences, and they are kept apart on purpose.

**`/api/...` is the drive surface.** It is the console vocabulary exposed over HTTP - what
a developer calls by hand, what a test harness calls, and what makes a running chartMaker
inspectable from outside. It is stable, because things outside the application depend on
it.

**Everything else is the applet's own protocol.** These paths are a private contract
between the server and the JavaScript in `_res/site`, and they change whenever the applet
changes. Nothing outside the application should depend on them.

| Path                      | Surface | Purpose                                        |
| ------------------------- | ------- | ---------------------------------------------- |
| `/api/command?cmd=<cmd>`  | drive   | Dispatch a command through `em_command`.       |
| `/api/log?since=<seq>`    | drive   | Output-ring entries since a point.             |
| `/poll`                   | applet  | A cheap version probe.                         |
| `/state`                  | applet  | Everything currently visible, as one document. |
| `/coverage?z&w&s&e&n`     | applet  | Tiles in coverage at one zoom, in view.        |
| `/preview?z&w&s&e&n`      | applet  | The same tiles, each named with the source it would be built from. |
| `/counts?id=<id>`         | applet  | Tiles and bytes by level, for the set and the chain down to one object. |
| `/tile/<src>/<z>/<x>/<y>` | applet  | The tile proxy.                                |
| `/edit`                   | applet  | A model mutation carrying structured data.     |

### The poll protocol

The application holds the truth; the browser renders it and asks for changes. `/poll`
returns a version number, and the client refetches `/state` when that number differs from
what it last rendered.

**One version counter, one state document.** The visible regions, the source list, the
active source, an evaluator result - all of it arrives together, so no two parts of the
display can be out of step with one another. The temptation to add a second channel for
some later feature is the thing to resist.

**A second counter says whether the MODEL moved, and it is published to nobody.** Selecting
an object and entering an edit both change what should be on screen, so both bump the poll
counter - and neither moves a polygon, so anything derived from the geometry is still valid
across them. Coverage costs about a second for a set; keyed on the poll counter, that work
was thrown away by every click in the tree. The default is the safe one: a mutation that
says nothing bumps both, which is merely slow, where the opposite default would serve a
stale answer.

**`/poll` also records when it was last asked.** One timestamp, no session - see
[Tree Editing](design/editing_wx.md). It answers whether a browser is there, which is what
lets an edit left behind by a closed window be cleared instead of blocking the tree forever.

**The model travels between threads as a document, not as a folder.** Each thread holds its
own copy and reloads when the shared counter moves, as before - but it refills from the
published document rather than from disk, because with a set open the disk no longer holds
what the user is looking at.

Three properties of the protocol are worth stating because each is easy to lose:

- **The server has no notion of a connected browser.** It answers questions. That is what
  makes closing and reopening the browser a non-event, with no session to clean up.
- **Reconnect is client-owned.** Every fetch carries a short timeout; on failure the client
  clears its layers and resets its last-rendered version, so the next successful poll sees a
  mismatch and resyncs everything.
- **The render loop must yield.** JavaScript is single-threaded, so a long render blocks
  the poll timer. Rendering in chunks with a yield between them is what keeps the
  connection alive under load - it looks like an optimisation and is actually a
  correctness requirement.

### Mutations and the applet

The applet edits geometry, so `/edit` carries structured data rather than a command line -
a polygon does not fit in a query string. It **dispatches into the same `em_command`
vocabulary** as the console and `/api/command`, which is what keeps the "anything one door
can do, the others can" property true even for the one operation only the map can perform.

That requires the dispatcher to accept an optional structured payload alongside the verb
and its text arguments. The console passes none.

One applet-side rule follows from the poll loop: **an object being edited leaves the
poll-rendered layer.** While a polygon is under the user's hand it is rendered from local
state and skipped by the renderer; on commit the edit is sent, the version advances, and
the application's copy becomes the truth again. Without that, the poll would deliver the
old geometry back mid-drag and fight the user.

## The Two Executables

The installed application ships twice: one executable running under `perl`, with a console
window, and one under `wperl`, without. They are the same program.

The console build is where the application's output is visible. There is deliberately **no
monitor pane** - the console window is the monitor, and shipping the console build means
that surface is available to an installed user and not only to a developer. When something
looks wrong in the windowed build, the answer is to run the other one.

Output is not written to a file. `Pub::` supports it - it needs only the shared `$logfile`
variable set - which makes it a candidate for a preferences dialog later rather than
something to design now.

## There is no `cm_visibility`, and there will not be

An earlier draft of this document promised one: an observer and batch mechanism keeping the
native panes and the browser agreeing about what is checked. It was never built, because
**the state version counter already does the job**. Both wx panes poll it on a timer and the
browser polls it over HTTP, so a change made anywhere is picked up everywhere on the next
tick.

Polling is not a lazy substitute here, it is the only correct choice: a region can be
changed from an HTTP thread, and a callback firing on that thread must not touch a wx
widget. An observer would have to hop threads to be safe, which is a queue and a timer
wearing a different name.

## The modules, by layer

Four prefixes, and they are a dependency order rather than a filing system: a module may
use anything above it and nothing below. The rule that keeps it honest is that
**everything above `w_` must load and run with no wx at all** - which is what lets the whole
model, the whole build and the whole analysis be tested headlessly, and is why a defect in
a dialog is the only kind that needs a person.

**`cm_` - foundations.** Constants, preferences, and the two shared structures.

```
    cm_defs      constants, window and command ids; depends on nothing but Pub::
    cm_prefs     the preference names, their defaults, and the folder resolution
    cm_utils     the resource root, the output ring, and the progress record
    cm_state     the version counter the map polls, and the view state it publishes
    cm_config    the per-set build configuration - what, where, and how fast
```

**`dm_` - the model and the work.** Everything that knows what a region is, what a tile is,
and how one becomes the other. No wx, and no user.

```
    dm_source    TSD files: reading, validating, addressing
    dm_cache     the tile cache, keyed by source
    dm_fetch     one tile from one source; no control flow of its own
    dm_set       region sets as folders
    dm_region    the coverage model, as a document
    dm_coverage  which tiles a region covers - the predicate and the enumerator
    dm_fill      walk the coverage and ask for every tile
    dm_analysis  what a run would cost, before committing to it
    dm_rct       the RCT exporter
    dm_mbtiles   the MBTiles exporter - a peer, not a conversion
    dm_build     the build act: validate, fill, refuse or export
```

**`em_` - the doors in.** One vocabulary, three transports.

```
    em_command   the command vocabulary and dispatcher - beneath all three doors
    em_console   keystrokes
    em_server    HTTP: the applet's protocol and the /api drive surface
```

**`w_` - wx.** Nothing here is depended on by anything above it.

```
    w_resources  the menus and command labels
    w_ini        the few things that survive a session
    w_frame      the frame; owns the document and launches the long acts
    w_prefs      the Preferences dialog
    w_buildcfg   preflight one - what and where
    w_preflight  preflight two - what it will cost
    w_progress   the two-level progress dialog over a worker thread
    w_report     what the build did
    winRegions   the region tree
    winSources   the source tree
```

`w_progress` and `w_prefs` are written here as **`Pub::` candidates** - general enough to
belong in the shared tree, kept local until a second application wants them.

## Still To Come

- **The fetch engine** - the queue, concurrency and interval limiting, retry policy, resume,
  and the failure classification that keeps a lost connection from being cached as "the
  source does not have this tile". See [Build](design/build.md).
- **A cache maintenance command.** Declaring an `absent_fingerprint` reclassifies matching
  tiles as they are next read, so correctness needs nothing - but the bytes stay on disk
  until something rewrites them. Converting them all at once is a real user-facing
  operation and currently lives only in a development script.

## The build runs on a thread

Settled, and worth recording because the alternative was a separate process. The build is a
detached worker thread carrying a shared record, and the exporter stays synchronous with no
opinion about any of it. See [Build](design/build.md#progress-and-where-the-build-runs).

**This is the one thread spawned after wx exists.** The server and console threads are
created before the application object, deliberately, so that they inherit a loaded model and
copy an interpreter with no widgets in it. A worker launched from a menu cannot do that.
There is precedent outside this application - the same shared-record-and-detached-worker
shape is what drives a card write from navMate's GUI - and none inside it, which is the
reason to say so here.

**Fetch and build are one piece of machinery.** They differ only in which function the worker
calls and what the report says; building it twice is how the two end up behaving
differently.

---

**Next:** [Home](readme.md)
