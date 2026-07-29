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
| `old` in the name | **Depends on something outside this repo that is going away** - `chartMaker_old` or the pre-rewrite card in `OLD_RASTER`. Delete these before the repo is published. |

## Running them

From this folder, with the shared Perl tree on the include path:

```
    perl -I/base test_source.pl
```

`use lib` resolves from the script's own location, so the repo can live anywhere. Every
scratch file, fixture directory and capture they produce is written under
`C:\_temp\dat-openCPN-chartMaker\` and never beside the script.

Output goes through `Pub::Utils`, which emits console escapes - **capture it to a file and
read that**, rather than streaming it into a terminal that will be confused by it.

## What is here

| Script | What it covers |
| ------ | -------------- |
| `test_source.pl` | TSD loading, validation, rejections, addressing, quadkey, row flip |
| `test_fetch.pl` | a live fetch, the cache, and negative caching |
| `test_rct.pl` | calls the exporter, then reopens the file and audits every byte it wrote |
| `tool_app_command.pl` | send one console command to the **running** application and print only that command's output |
| `tool_rct_inspect.pl` | run the firmware's own arithmetic over a card - the zero-step blocks it would silently skip, and the reveal-mask rectangle count against its budget |
| `_tool_esri_probe.pl` | what resolution Esri actually holds over an area, by `MaxMapLevel` |
| `_old_test_region.pl` | region files, ids, the workspace, KML import |
| `_old_test_coverage.pl` | the grid, the band rule, parents versus re-intersecting, tile counts |
| `_old_test_server.pl` | the applet protocol against an in-process server |
| `_old_test_rct_merc.pl` | the E80 semicircle projection, against the pre-rewrite card |
| `_old_tool_rct_compare.pl` | old card versus new, by byte region |
| `_old_tool_rct_bitmaps.pl` | old card versus new, presence bitmap by presence bitmap |

## The `_old_` group is not meant to survive

Three of them import a coverage KML that lives in the old repository, and three read the
card the old exporter produced. Both go away.

The three tests among them are worth keeping, and the way to keep them is **not** to copy
that KML in here - it is to have them write their own small synthetic polygons the way
`test_source.pl` already writes its own `.tsd` fixtures. That removes the dependency, makes
them publishable, and promotes them out of `_old_`. Until somebody does that, they are on
borrowed time.

The three tools are spent: they compared the new exporter against the old card, the
comparison passed, and the card is on the hardware.

## One thing worth saying plainly

**No script here writes a chart.** They read, drive, assert and report. Every byte of every
output format is produced by the application's own modules; a harness may *call* an exporter
and then check what it wrote, but it never reimplements one. If a script here ever starts
packing bytes, that is a bug in the script.
