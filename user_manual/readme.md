# chartMaker User Manual

**Home** --
**[Tutorial](tutorial/readme.md)** --
**[Reference](reference/readme.md)**

Welcome aboard. **chartMaker** builds **offline satellite chartsets** for your boat - the
aerial photograph of the water you are about to anchor in, on the plotter at the helm and on
the laptop at the chart table, working when the internet is not.

<a href="images/map_xarraca.png" target="_blank"><img src="images/map_xarraca.png" width="800" alt="Cala Xarraca on the north coast of Ibiza, boats anchored on pale sand patches between dark posidonia meadows"></a>

## Why you would want one

Look at that picture for a moment. Every boat in it is sitting on a pale patch, and every
pale patch is sand. The dark ground between them is *Posidonia oceanica* - seagrass, and in
the Balearics anchoring on it is illegal, enforced, and fined. Your chart shows a depth and a
bottom-type letter for the whole bay. It cannot show you which twenty metres of it you are
allowed to drop the hook into. The photograph can, unmistakably.

That is the general case, not a Mediterranean curiosity. Official charts are surveyed,
authoritative, and frequently wrong about the last hundred metres: the reef that grew, the
sandbar that moved, the unmarked pass every local uses and no chart shows. Satellite imagery
shows what is actually there.

chartMaker builds two kinds of output:

- **`.mbtiles`** files, read directly by [**OpenCPN**](https://opencpn.org/).
- **`.RCT`** files, read by the aerial photo overlay in the custom firmware for
  **Raymarine E-Series** (E80 / E120) plotters.

## What chartMaker does, and what it does not

You draw the areas you care about on a map, say how much detail each one deserves, point the
program at an imagery source, and it fetches, assembles and packages the result. What it
keeps between sessions is the thing worth keeping: **a durable description of what your
chartset is** - the regions, how they nest, the small areas worth going deeper on. You refine
that over years. The tiles are rebuilt from it whenever you like.

**chartMaker never ships imagery. Not one tile, ever.** What it ships is a handful of
*source definitions* - small text files describing where imagery lives - and only for
services whose publishers permit that use. It also ships a catalog of other services you can
create a definition from.

**Which service you point it at, and on what terms, is your decision and your
responsibility.** Every source carries its licence and its terms, and chartMaker shows them
to you; reading them is your part. The program deliberately has no opinion it is not entitled
to have, and the [Tutorial](tutorial/readme.md) works entirely within the sources that ship
with it.

### A chartset is a photograph, not a chart

Satellite imagery carries no soundings, no verified datum, no aids to navigation and no
survey authority, and it may be years out of date. It is an aid to navigation only - never a
substitute for official charts, published Notices to Mariners, a proper lookout, or your own
seamanship. Please read [NOTICE_TO_MARINERS.txt](../NOTICE_TO_MARINERS.txt) before you build
anything you intend to navigate with.

## Contents

### [Tutorial](tutorial/readme.md) - read in order

- **[Getting Started](tutorial/getting_started.md)** - install it, find your way around, and
  open the example region set.
- **[The Map](tutorial/the_map.md)** - the chart in your browser, and what every switch on it
  answers.
- **[Your First Region](tutorial/regions.md)** - draw Formentera from nothing, and understand
  the three zoom numbers that decide everything.
- **[Detail Areas](tutorial/detail_areas.md)** - go deep where it matters, and learn to draw
  for size instead of drawing a box.
- **[Choosing a Source](tutorial/choosing_a_source.md)** - probe a service, read what came
  back, and preview exactly what your chartset will contain.
- **[Building](tutorial/building.md)** - fetch, build, and get the result onto the boat.

### [Reference](reference/readme.md) - dip into as needed

- **[Sources and TSD Files](reference/sources_tsd.md)** - what a source definition is and how
  to write one.
- **[The Catalog](reference/catalog.md)** - the tile services chartMaker knows about.
- **[Preferences and Keys](reference/preferences_keys.md)** - folders, rates, and the key
  store.
- **[Housekeeping](reference/housekeeping.md)** - the tile cache, cleaning up, and where your
  files live.

## More

The **[design documentation](../docs/readme.md)** describes how chartMaker works and why it
is built the way it is. You do not need any of it to use the program, and this manual points
at it only where knowing one specific thing genuinely helps.

**[navMate](https://github.com/phorton1/base-apps-navMate/blob/master/user_manual/readme.md)**
is the companion application: a lifelong home for your waypoints, routes and tracks. It is
also the E-Series Firmware Builder - the thing that puts the aerial photo overlay on the
plotter in the first place, which is what chartMaker's `.RCT` files feed.

## License

chartMaker is free software, released under the GNU General Public License Version 3. It
comes with **no warranty of any kind**. See [LICENSE.TXT](../LICENSE.TXT).

---

**Next:** [Tutorial](tutorial/readme.md)
