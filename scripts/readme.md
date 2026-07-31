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
| `test_set.pl` | region sets as folders, per-set ids, the ini selections and how they degrade, checked-is-a-view |
| `test_edit.pl` | containment, the dispatcher's refusals, the edit state and what it locks |
| `test_fetch.pl` | a live fetch, the cache, and negative caching |
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
| `tool_shot.ps1` | a screenshot of the running window, found by owning process |
| `tool_progress_demo.pl` | the build's progress dialog and report dialog driven by a **fake** worker that just counts - no model, no cache, no network. What can go wrong in that half is wx and threads, and none of it is about tiles |
| `tool_prune_absent.pl` | convert a source's cached "no data here" tiles into recorded absences |
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
