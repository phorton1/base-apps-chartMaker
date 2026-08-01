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

## `$data_dir` - the user's material

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

## The credential store

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

## Every folder is a preference

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

The key is the **leaf name of the `.tsd` file** - the file name, not the `id` field inside
it. That choice makes the mapping legible in a file browser: a user can look at the cache,
see one folder per source they have used, and delete exactly one of them. The cost is that
renaming a TSD orphans its cache directory, which costs a refetch and nothing else.

Two properties of `$temp_dir` are worth stating because they are inherited rather than
chosen: it is **never cleaned up automatically**, and it is **not process-specific**.
Anything that must be per-instance has to carry the process id in its own name.

## Running both at once

Because both environments resolve to different roots, a development chartMaker and an
installed chartMaker run side by side without touching each other's files.

The same has to hold for anything else the two would otherwise contend for, and the
**HTTP server port** is the one that bites: two servers cannot bind the same port, so
without an environment-keyed default the second application to start simply fails. The
defaults are **9884 in development** and **9874 when installed**, and like the credential
store location, the port is a preference and can be overridden.

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
| `$data_dir` | region sets, TSDs, the credential store, built output, the cache | **kept** |
| `$temp_dir` | the ini, the per-machine timing record | kept, and disposable |

**Nothing the user authored is inside the installation**, which is why an upgrade is an
install over the top and a removal takes nothing away that anybody typed.

## Version scheme

`0.9.x`: `0.9` marks a pre-release, `.x` the build. **`1.0.0` is the contract line.** Before
it, formats may change and a release is throwaway. From it, releases are permanent and the
`.tsd`, `.region` and `.RCT` formats become a backward-compatibility commitment - which is
what the `tsd_version` and `region_version` fields exist to carry.

## A release is a tag in four repositories

A build is made from four repositories, and a release stamps the **same tag string**,
`chartMaker<version>`, across all four. `git checkout chartMaker<ver>` in each reconstructs
exactly the source a release was built from.

| Repository | Holds | Gets |
| ---------- | ----- | ---- |
| chartMaker | the application | the tag, and the GitHub Release |
| Pub | the shared Perl library | the tag, as provenance |
| base_dist/chartMaker | the packaging project | the tag, as provenance |
| Perl | the exact interpreter bundled | the tag, as provenance |

Only chartMaker gets an actual Release, with the installer as its asset. The repository
itself stays text-only: `/releases` holds the release **log**, not the installers.

**The log is not a changelog.** One row per release, plus the four commits it was built
from. Every release is tagged in every repository, so `git log chartMaker<old>..<new>`
reconstructs the changes on demand and no second account of them has to be maintained.

The packaging procedure itself - the toolchain, its configuration, and the steps that turn
the source into an installer - is in [Installer](installer.md).

---

**Next:** [Home](readme.md)
