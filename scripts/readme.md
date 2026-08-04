# chartMaker - scripts

Not part of the documentation. This folder is outside the `docs/` cycle on purpose and
carries no navigation header, because nothing here is for a reader of the project.

Things Claude uses. Headless harnesses and small tools that exercise the application from
outside it - not part of the program, not needed to run it, and not something a user has
any reason to open.

They are here rather than in a `test/` folder because they are not a hand-written test
suite in the usual sense; they were built alongside the code by the assistant that wrote it,
and they encode what was learned by getting things wrong.

## Naming

| Form | Meaning |
| ---- | ------- |
| `test_*` | Asserts. Prints `PASS`/`FAIL` per check and `ALL PASSED` or a failure count. |
| `tool_*` | Does a job and reports what it found. No pass or fail. |
| `_` prefix | **Less durable.** Spent one-offs, or things resting on something transient. |
| `my_` prefix | **Needs the author's own data**, and cannot run anywhere else. Not a candidate for deletion - the data is the point. |
| `old` in the name | **Depends on something outside this repo that is going away** - `chartMaker_old` or the pre-rewrite card in `OLD_RASTER`. Delete these before the repo is published. |

`my_` and `old` are opposite marks and must not be confused. `old` says *this will stop
working and should go*; `my_` says *this works, and only here*. `my_test_rct.pl` is the
clearest case: it checks the exporter against a card that actually ran on the plotter, which
is the only evidence that the semicircle projection is right - a synthetic fixture would
prove nothing except that the exporter agrees with itself.

A `tool_` that reads the author's data is NOT `my_`. Statistics are reported over whatever
they are pointed at, and `tool_coverage_time.pl` and `tool_rct_inspect.pl` would report just
as happily on a stranger's set; they read Patrick's because his is what is there.

## Running them

From this folder, with the shared Perl tree on the include path:

```
    perl -I/base test_source.pl
    powershell -File tool_shot.ps1 -out C:\_temp\shot.png
```

`use lib` resolves from the script's own location, so the repo can live anywhere. Every
scratch file, fixture directory and capture they produce is written under
`C:\_temp\base-apps-chartMaker\` and never beside the script - **that folder is cleared
at every commit**, so nothing worth keeping may live there.

**Anything that writes builds its own data dir first.** A script that forgets leaves
`$data_dir` empty, and the region-set loader then creates its folders at the root of the
drive - which has happened. The `tool_` reporters read a real data dir and only read.

Output goes through `Pub::Utils`, which emits console escapes - **capture it to a file and
read that**, rather than streaming it into a terminal that will be confused by it.

## What is here

| Script | What it covers |
| ------ | -------------- |
| `test_doc.pl` | the set as a document: only Save writes, dirty is derived, revert against commit, and a fixture that survives a whole session of edits unchanged |
| `test_source.pl` | TSD loading, validation, rejections, addressing, quadkey, row flip |
| `test_catalog.pl` | the shipped catalog: that every entry produces a hash `dm_source` would **load** - an entry that did not would put a red line in the source list with the reason in a log - plus what a child inherits and what it must not, that the three shipped `.tsd` files still agree with their catalog entries, that google ships and is deliberately not catalogued, that the survey date matches `docs/notes/source_catalog.md`, and every branch of the create plan with no sources folder in existence |
| `test_set.pl` | region sets as folders, per-set ids, the ini selections and how they degrade, checked-is-a-view |
| `test_edit.pl` | containment, the dispatcher's refusals, the edit state and what it locks |
| `test_fetch.pl` | a live fetch, the cache, and negative caching. Then `absent_headers` against the stub, with three controls fetching the SAME bytes from the SAME url and differing only in what their TSD declares |
| `test_observe.pl` | the observation record: the smoothed rate, one file per source, surviving a restart, what a fetch teaches it, that it stays bounded under twenty errors, and that a corrupt record is skipped rather than fatal. Entirely offline |
| `test_engine.pl` | the fetch engine, with the pacing **timed by the stub server** rather than by the engine's own counters. Composition both ways, a gate that holds across four workers, an unpaced source that still overlaps, each failure class and its one consequence, a 429 that backs off the SOURCE, interactive queueing ahead of a backlog, and every permit and ticket returning to zero |
| `test_probe.pl` | the metadata probe against the **live** ArcGIS and GIBS endpoints - a fixture would keep passing after the service changed, which is the failure the feature exists to catch - plus the two branches no real service will produce, against the stub. Then the same documents read the OTHER way, as a layer list: that GIBS enumerates, that every url it yields is addressable with no placeholder left unresolved, that the list is deepest first, and that Esri Wayback's 195 releases all survive - a matrix set naming no level, whose definition opens with a Title, ordered as the service published them, each carrying its own pinned release id |
| `test_verify.pl` | verifying a source against its service. The offline half is the rules: that only the CANONICAL column can verify and an empty column at the user's own point never fails, that a repeated identical image across levels is named as one image rather than counted as four tiles, that a column of honestly small tiles suspects nothing, and that a source with nowhere to be asked says so rather than implying a pass. Then two live services - Esri at its canonical point, where the four levels answered with its declared blank are NOT counted as imagery, and a url naming no service at all |
| `test_sample.pl` | the probe: that the SOURCE is the subject and the region supplies only polygons. The fixture is a trap - the region declares zauthor 12 / zmin 10 / zmax 12 and names source A, while the probe is run with source B over z9-z14, so a sampler consulting any of the region's numbers samples the wrong levels or the wrong service and is caught. Plus clamping to the .tsd range, samples meeting the polygon at every level, z19 without enumerating z19, all-versus-sampled, absences never confused with failures, a repeated body becoming one candidate fingerprint, a halt, and several sources accumulating |
| `test_image.pl` | the codec seam, with fixtures it draws itself so the truth is known: a flat tile detected exactly, a genuine magnification recognised as carrying no new detail, and real detail at the finer level NOT called a blow-up. **Skips itself when no decoder is installed**, which is a supported configuration rather than a failure |
| `test_fill.pl` | the cache filler: which source each node resolves to, the zmax cap, an uninstalled source, and the abort. Nearly offline - it plants the cache itself and asserts a 100% hit rate, which is what proves source resolution |
| `test_preview.pl` | the preview classification: carried at this zoom, the deepest carried ancestor past the built depth, innermost-wins on source, and outside coverage. Entirely offline - it tests the decision, never the drawing |
| `test_build.pl` | the build act: every guard, that each one refuses **and writes nothing**, that they run before the fetch, the ledger refusal that no abort catches, the two overrides, and per-node sources reaching the exporter. Offline on every path that should succeed |
| `test_preflight.pl` | the build configuration and the analysis: no file until something is configured, that editing it cannot make the set dirty, ALL against a list naming everything, an advisory rate that can only slow you down, the folder survey, and the index scan agreeing tile for tile with probing each tile. Entirely offline |
| `test_mbtiles.pl` | node identity and the MBTiles exporter: that a duplicate id anywhere in a region is refused, that the source map is keyed by path so two branches cannot collide, one file per node with its own zoom band, the TMS row flip checked against the arithmetic, blobs that round trip byte for byte, and a png source that builds here and is refused for a card. Entirely offline |
| `my_test_rct.pl` | calls the exporter, then reopens the file and audits every byte it wrote, against the card that ran on the plotter |
| `my_build_mbtiles.pl` | build one of Patrick's real regions as mbtiles, **from the cache only**, and print what it wrote by reading the files back |
| `run_chartmaker.bat` | **launch the app in a window that shows the log** - and that window is where console commands are typed. Hardcoded to this machine's Perl and repo root, which is what a launcher is |
| `tool_app_command.pl` | send one console command to the **running** application and print only that command's output |
| `tool_rct_inspect.pl` | run the firmware's own arithmetic over a card - the zero-step blocks it would silently skip, and the reveal-mask rectangle count against its budget |
| `tool_coverage_time.pl` | what coverage costs cold, warm, and after one region is edited |
| `tool_shot.ps1` | a screenshot of the running window, found by owning process - and **refusing** rather than guessing when more than one instance is up, since picking wrong means measuring somebody else's process. `-procId` says which |
| `tool_progress_demo.pl` | the build's progress dialog and report dialog driven by a **fake** worker that just counts - no model, no cache, no network. What can go wrong in that half is wx and threads, and none of it is about tiles |
| `tool_prune_absent.pl` | convert a source's cached "no data here" tiles into recorded absences |
| `tool_stub_source.pl` | **a tile server that misbehaves on purpose**, and the only way to reach the failure half of the fetch path - nobody can ask Esri for a 429, a 403, or a body that recovers on the third try. The path IS the instruction, so a fixture is a url template and nothing else, and `/stats` reports arrival times because the engine's own counters cannot testify about the engine |
| `tool_engine_soak.pl` | thousands of jobs across several sources at once, checking the things that should be INVARIANT rather than true once: every job collected exactly once, every permit returned, no duplicate tickets, nothing in flight at the end. These fail silently in production and never once in a short test |
| `tool_thread_spike.pl` | what this Perl's threads actually cost and can carry, measured **before** the engine was written because its shape depended on the answers. Spawn cost against a small and a loaded interpreter, whether a binary blob survives a queue, and whether a shared gate really paces |
| `tool_thread_cost.pl` | **the measurement behind the ceiling of 12** - address space per ithread with the application loaded, in a 32-bit process with 2 GB to spend. The number is a hard constant in `dm_engine` and in `Pub::HTTP::ServerBase`, so it should be reproducible rather than quoted |
| `tool_fetch_bench.pl` | does concurrency actually buy wall clock against a **real** tile server - the one claim in the engine that was asserted rather than measured, because a stub answers in 2 ms and at 2 ms there is no latency to cover. Its own cache under `C:/_temp`, so the real one is never touched |
| `tool_hold_port.pl` | occupy the HTTP port and sit on it, to see what a chartMaker started afterwards does. Binds the **wildcard**, because binding `127.0.0.1` does NOT collide with a wildcard bind - both succeed and the only symptom is a browser silently talking to the wrong listener |
| `tool_backoff_starve.pl` | reproduces a **known unfixed fault**: a worker backing off holds its slot, so a source being rate limited can occupy the whole pool and an interactive tile from a healthy source waits behind it. A tool and not a test precisely because it fails |
| `_tool_esri_probe.pl` | what resolution Esri actually holds over an area, by `MaxMapLevel` |
| `_old_test_rct_merc.pl` | the E80 semicircle projection, against the pre-rewrite card |
| `_old_tool_rct_compare.pl` | old card versus new, by byte region |
| `_old_tool_rct_bitmaps.pl` | old card versus new, presence bitmap by presence bitmap |

## The `_old_` group

Three of these were **deleted in Phase F**: `_old_test_region.pl`, `_old_test_coverage.pl`
and `_old_test_server.pl` all called a KML importer that no longer exists. It was the
one-way path out of the old chartMaker, its job is done, and the application has no notion
of importing a region set - it creates, modifies and saves them. The scripts could not run,
and most of what they covered is now in `test_doc.pl`, `test_set.pl` and `test_edit.pl`.

The three that remain compare this exporter's output against the card the OLD chartMaker
produced, and both reference files still exist, so they still do real work:

```
    C:/dat/openCPN/OLD_RASTER/BOCAS.RCT     the pre-rewrite card
    C:/dat/openCPN/RASTER/Bocas.rct         what this one wrote
```

**The comparison is finished, and these three are inert.** They did their job: every block
descriptor and every presence bitmap matched the card the old toolchain produced, the card
ran on the plotter, and the semicircle projection - the one thing that fails invisibly - is
proven. Nothing further is asked of them.

**They also cannot pass any more, by construction.** A card now carries an attribution blob
at the end and a pointer to it at `0x38`, which the old exporter never wrote, so a
byte-for-byte comparison against the old card *should* differ and reports a difference that
means nothing. Both hardcoded paths are stale as well - output folders became preferences,
so a build writes to `<RASTER_DIR>/<set>/`.

Do not repair them. They are kept only because deleting code is Patrick's call, and they go
before the repo is published.

**What replaced them** is `my_test_rct.pl`, which is a different kind of check and is not
affected by any of this: it builds a card and audits the bytes it just wrote, against no
external reference. Its value is undiminished - it is what proves an exporter change moved
nothing, and it earned that twice in one day.

## One thing worth saying plainly

**No script here writes a chart.** They read, drive, assert and report. Every byte of every
output format is produced by the application's own modules; a harness may *call* an exporter
and then check what it wrote, but it never reimplements one. If a script here ever starts
packing bytes, that is a bug in the script.
