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

- **Region files** - the coverage model: geometry, nesting, and the depth each area
  deserves. One file per region, found by scanning the folder, so dropping in a region
  somebody sent you is how you add it. See [Design: Regions](design/regions.md).
- **TSD files** - the tile source definitions the application can build from. Found the
  same way, for the same reason. See [Design: TSD](design/tsd.md).
- **The workspace index** - the small file holding what a folder scan cannot answer: the
  named sets, and which regions are currently checked.
- **The credential store** - the secrets for those sources that require one.

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

### `$temp_dir` - everything regenerable

`$temp_dir` holds only what chartMaker can rebuild by itself, which makes deleting it a
question of time rather than loss. The principal occupant is the **tile cache**, and it is
keyed by source:

```
    $temp_dir/cache/<tsd_leaf_name>/<z>/<x>_<y>.<ext>
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

## Still To Come

- **Module inventory by layer** - foundational utilities, portable logic, wx components,
  and the top-level wx panes, in the order they may depend on one another.
- **`cm_visibility`** - the observer and batch mechanism that keeps the native panes and
  the browser agreeing about what is checked, and where its state is written.
- **The build engine and exporters** - which modules do the fetching, the assembly, and
  the conversion to each output format, and whether the engine runs on a thread or in a
  separate process.

---

**Next:** [Home](readme.md)
