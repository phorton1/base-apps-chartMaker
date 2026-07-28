# chartMaker - Implementation

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Design](design.md)** --
**Implementation**

Where [Design](design.md) describes the structures, this document describes the code that
implements them.

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

- **Project files** - the coverage models: regions, subregions, zoom ranges, detail areas.
- **TSD files** - the tile source definitions the application can build from. This is where
  chartMaker looks for sources, and where a user drops one that somebody sent them.
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

## Still To Come

- **Module inventory by layer** - foundational utilities, portable logic, wx components,
  and the top-level wx panes, in the order they may depend on one another.
- **The HTTP server and the Leaflet applet** - what is served from `_res/site`, and the
  request surface between the browser and the application.
- **The build engine and exporters** - which modules do the fetching, the assembly, and
  the conversion to each output format.
- **Separate executables** - anything living in an underscore-prefixed folder, what it is
  for, and why it is separate.

---

**Next:** [Home](readme.md)
