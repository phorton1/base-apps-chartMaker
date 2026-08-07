# chartMaker Tutorial

**Tutorial** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Zoom Levels](zoom_levels.md)** --
**[Your First Region](regions.md)** --
**[Detail Areas](detail_areas.md)** --
**[Choosing a Source](choosing_a_source.md)** --
**[Building](building.md)**

folders: **[Home](../readme.md)** --
**Tutorial** --
**[Reference](../reference/readme.md)**

This tutorial takes you from a fresh installation to a finished chartset, over one small
piece of water: the **Pityusic islands** - Ibiza and Formentera - in the Spanish Balearics.

We chose them for three reasons. The imagery over them is published by Spain's national
geographic institute under an open licence, so everything here is something you may
legitimately do. They are an *archipelago*, which is what a region set is for. And their
north-coast bays are the clearest demonstration there is of what an aerial photograph tells a
mariner that a chart cannot.

**But Ibiza is where we demonstrate, not where you should work, and Spain IGN is not the
service you should use.** Almost certainly neither is anywhere near your water. They are here
because one small real set contains every idea you need, and ideas are what transfer:

| what the example shows you | what you will do with it |
| --- | --- |
| a **region set** you open as a document | make your own, for your own coast |
| a **region** with an outline and three zoom numbers | draw yours, and choose those numbers on purpose |
| a **source** named on that region | choose a service that covers *your* ground |
| **detail areas** going deeper inside it | go deep only where you actually anchor |
| a **build** to `.mbtiles` and `.rct` | put your own chartset on your own boat |

Learn those five here, where nothing you break matters, and your own chartset is the same
five with different values. **The tutorial deliberately makes you do the two acts people
most often skip** - opening a set, and telling a region where its pixels come from - because
nothing is guessed for you and nothing will build until you have.

By the end you will have:

- opened the example region set that ships with chartMaker, and understood what is in it
- drawn a **region of your own** around Formentera, with a **detail area** inside it
- **probed** a tile service to find out how deep its imagery really goes, and chosen your
  numbers from what came back rather than by guessing
- **previewed** exactly what your chartset will contain, before spending an hour fetching it
- **built** it, in both output formats, and put it where OpenCPN and an E-Series plotter can
  read it

**Read these in order.** Each chapter leaves the program in the state the next one starts
from, and the region you draw in [Your First Region](regions.md) is the one you go deeper on
in [Detail Areas](detail_areas.md) and build in [Building](building.md).

Nothing here can hurt anything. The example set is restored by one menu item whenever you
want it back, and nothing you do reaches a file until you save it.

## The chapters

- **[Getting Started](getting_started.md)** - install chartMaker, meet the two windows it
  runs in, and open a region set - which you have to do before almost anything else works.
- **[The Map](the_map.md)** - finding your way around the chart in your browser, the source
  you are looking *at*, the palette down the left, and the tile counts up the right.
- **[Zoom Levels](zoom_levels.md)** - what a zoom level is, why each one down costs four
  times the last, and how deep is worth going. Everything after this is numbers.
- **[Your First Region](regions.md)** - create and draw Formentera; `zauthor`, `zmin` and
  `zmax`; **choosing the imagery it is built from**; and the two Saves that are not the same
  Save.
- **[Detail Areas](detail_areas.md)** - subregions and the bands they add; snapping to the
  tile grid; and why the example region is drawn as two strips rather than one box.
- **[Choosing a Source](choosing_a_source.md)** - display against build, probing a service
  over your own water, and preview.
- **[Building](building.md)** - Fetch, Build RCT, Build MBTiles, the preflight, and what to
  do with what comes out.

---

**Next:** [Getting Started](getting_started.md)
