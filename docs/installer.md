# chartMaker - Installer

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Design](design/readme.md)** --
**[Implementation](implementation.md)** --
**[Deployment](deployment.md)**

How the source becomes an installable, Perl-free Windows program. This is a **procedure**
rather than a specification, which is why it sits off the reading chain: every other
document answers what chartMaker is and why, and this one answers which tool is run in what
order. [Deployment](deployment.md) describes what the result places on a machine.

The method is arcane and rests on abandonware. All of the source is public, and the recipe
is here so that what is published can be checked against what is built.

## Toolchain

- **Cava Packager 2.0** - scans a Perl/wxPerl application and bundles a private ActivePerl
  5.12 plus wxWidgets 3.0 into Windows executables. The `.cpkgproj` project file is a SQLite
  database. The build is a **GUI operation** - Distribution, then Scan and Build Project;
  `cavaconsole.exe` is a runtime diagnostic console and not a headless builder.
- **Inno Setup 5.5.9** - compiles the generated `innosetup.iss` into the user-facing
  installer executable.
- **ActivePerl 5.12.4** as the development Perl - the same version Cava bundles, so every
  module that works in development is ABI-compatible with the packaged build.

The version of each is recorded in the release log entry it produced, because a packaging
tool is as much a part of a build's provenance as the source is.

## The packaging project is a separate repository

`base_dist/chartMaker` is private and holds the Cava project and the installer
configuration. It carries no source: it `USES` the chartMaker repository, and the two are
tagged together at a release.

Its `.gitignore` ignores everything and re-includes by exception, so the repository holds
the project configuration and nothing regenerable - no built executables, no scan logs, no
release tree. The one lesson worth stating in advance is that **the `.gitignore` has to be
added before the first commit**, because it cannot evict files that are already tracked.

## What chartMaker requires of a scan

These follow from the source rather than from the packager, so they are knowable before a
build has ever been run.

**The source folder must be on the scan path.** chartMaker loads its own modules by bare
name - `use cm_defs;`, `use dm_set;`, `use w_frame;` - which is a permanent convention, so
the application folder goes on `extrapaths` alongside `C:/base`, which is what resolves
`Pub::`.

**Modules a static scan cannot see have to be forced in.** Three cases exist in this
application:

- **`DBD::SQLite`** - `dm_mbtiles` speaks to `DBI`, which loads its driver by name at
  runtime. The MBTiles exporter is the only thing that needs it, and it is exactly the kind
  of dependency a scan misses.
- **`threads` and `threads::shared`** - used throughout, and the build worker depends on
  them.
- **`JSON` and `JSON::PP`** - regions, sources and the build configuration are all JSON.

**`_res` is the resource tree**, and the Leaflet applet in `_res/site` is served from it by
the embedded HTTP server. It bundles wholesale, and `$resource_dir` is what the application
resolves it through in both environments.

Two other things live there and are reached the same way. **`_res/user_data` mirrors the
default data dir**, one folder per tree the application reads:

```
    _res/user_data/sources/*.tsd
    _res/user_data/region_sets/<set>/*.region
```

Its contents are copied into the user's own folders under an existence guard, which is what
makes a shipped source an ordinary editable file. **The layout is the mapping** - in the
ordinary case, where nobody has moved a folder, each destination is identical to its source,
so the copy is the simple thing. It is still a *mapping* rather than a recursive copy,
because every one of those trees is a preference and may point elsewhere; a blind copy into
`$data_dir` would put a shipped source where a user who moved `SOURCES_DIR` would never find
it.

**The installer is no longer the only path to it** - `Help - Regenerate Examples` performs
the same copy at runtime, which is what lets a deleted source come back without a reinstall
and what seeds a development installation. `_res/catalog.json` is the
[tile source catalog](design/catalog.md) and is **not** copied anywhere: it is read where it
lies, because it is application material that has to stay coherent with the code rather than
user data that may be edited.

**The source is packed as plain text rather than masked.** It is public on GitHub, so
masking would obscure nothing and would only make the shipped copy harder to compare against
the published one.

## The two executables

chartMaker packages as two targets from one project: a console-bearing build and a
console-less one, described in [Deployment](deployment.md#the-two-executables). Neither
requires elevation - chartMaker writes only to the user's own directories and opens one
listening socket on the loopback interface.

## The build

1. Open Cava and confirm the project loaded. It is single-instance, and editing the
   `.cpkgproj` directly requires it closed.
2. Run **Distribution, Scan and Build Project**, then read the scan and build logs. Zero
   warnings is the target; each module a static scan missed becomes another forced include,
   and the build is repeated until the log is clean.
3. Inno compiles the installer from the generated `.iss`. Cava 2.0 emits that file for an
   older Inno than 5.5.9, so a pre-installer script rewrites the incompatible directives
   before the compile.
4. Install the result and smoke-test it against a real region set: the map applet in a
   browser, a build to both output formats, and the console executable's output.
5. Commit the packaging repository. That commit is the recipe that produced this executable.

## Cutting a release

The four-repository provenance freeze is specified in
[Deployment](deployment.md#a-release-is-a-tag-in-four-repositories). The order matters more
than the commands do:

1. Commit the source repositories clean.
2. Bump the version and build, which dirties only the packaging repository.
3. Commit the packaging repository.
4. Install the built executable and test it.
5. **Commit nothing further to any of the four**, or the tags will not pin what shipped.
6. Tag all four with `chartMaker<version>` and push the tags, noting each commit.
7. Append the release-log entry and commit it.
8. Create the GitHub Release with the installer as its asset, review it as a draft, publish.
9. **Download the published asset and install it again.** It is the only step that proves
   the uploaded file is intact, and it is the only one that tests what a user will actually
   receive.
