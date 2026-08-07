# Zoom Levels

**[Tutorial](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**Zoom Levels** --
**[Your First Region](regions.md)** --
**[Detail Areas](detail_areas.md)** --
**[Choosing a Source](choosing_a_source.md)** --
**[Building](building.md)**

folders: **[Home](../readme.md)** --
**Tutorial** --
**[Reference](../reference/readme.md)**

Almost every number you will type into chartMaker is a **zoom level**, and almost every
decision you make is really a decision about one. This chapter is fifteen minutes that will
save you a wasted afternoon, and you can read it with the map in front of you.

## What a level actually is

Every online map in the world - this one, Google's, OpenSeaMap's - is built the same way. The
earth is cut into square pictures called **tiles**, each 256 pixels across, and the same earth
is cut up again at a series of increasingly fine **levels**.

At **level 0** the whole world is one tile. At level 1 it is cut into four. At level 2, into
sixteen. Every level doubles the resolution in each direction, so:

> **each level down quadruples the number of tiles.**

That single sentence is the whole of the arithmetic, and it is the reason chartMaker asks you
so carefully how deep you want to go. Going one level deeper over the same water costs four
times as many tiles, four times the download, and four times the disk. Going three levels
deeper costs **sixty-four** times.

| Level | One tile covers roughly | Useful for |
| ----- | ----------------------- | ---------- |
| **z8** | 150 km | a whole sea |
| **z10** | 40 km | an island group - a sensible overview |
| **z12** | 10 km | an island |
| **z15** | 1.2 km | a stretch of coast; a bay fits in a few tiles |
| **z16** | 600 m | coastal detail - you can see individual boats |
| **z18** | 150 m | an anchorage - you can see the sand between the weed |
| **z20** | 40 m | a dock. Almost no marine service really holds this |

Those distances are at the equator and shrink as you go north or south - a z15 tile in the
Baltic covers rather less ground than a z15 tile in Panama. It does not change any decision
you make; it is worth knowing only so the numbers on screen make sense.

## Seeing them

Reading about this is much less useful than looking at it, and the map will show you directly.

Switch on **`tile grid`** in the palette. The map draws the edges of the tiles at the level
you are looking at, right across the view. Now zoom in one step, and watch: the grid redraws,
and every square you were looking at has become four.

Do that four or five times, from an island down to a single beach. That is the cost curve,
drawn on the water in front of you. It is worth doing once, properly, because from here on
every number in this manual is that picture.

**`tile footprint`** is the other half. Instead of the whole view it draws only the tiles a
*region* is made of, and it puts a **count** on them. This is where "how much am I asking for"
stops being an abstraction: pick a level in the spinner beside it and the count is the number
of pictures chartMaker would have to fetch, one request each.

## How deep is worth going

The honest answer is **as deep as the imagery is actually good, and not one level further**,
and that is a different depth for every service and every piece of water.

This is the trap the whole of [Choosing a Source](choosing_a_source.md) exists to get you out
of, so here it is in one paragraph. Most imagery services will answer a request for *any*
level you ask for. If they do not hold imagery that fine, the vast majority of them do not
refuse - they simply magnify what they do have and send that. It arrives looking like a
picture, it costs a full request, it takes a full share of your disk, and it contains not one
thing that the level above it did not already contain. Asking for three levels more than a
service really holds costs sixty-four times the tiles for **no additional information
whatsoever**.

Which is why chartMaker has a **probe** - a way of finding out where a service really stops
before you spend the afternoon - and why this manual asks you to use it before choosing your
numbers rather than after.

**As a starting point for coastal work:** an overview around **z10**, general coastal cover to
**z16**, and the anchorages you actually care about at **z18**. Those are the numbers the
example set uses, and they are good numbers to copy until you have a reason of your own.

## Why chartMaker asks you three times

You will meet three separate zoom numbers on a region, which seems like two too many until
you see what each is for. They get their own section in
[Your First Region](regions.md#the-three-numbers), but in one line each:

| | |
| --- | --- |
| **`zmin`** | the coarsest level to carry - your zoomed-right-out overview |
| **`zmax`** | the finest level to carry - how deep this water deserves |
| **`zauthor`** | the level your **outline** is cut at, which is a different kind of question |

The first two are the top and bottom of a range. The third is the odd one, and it is
explained where it is used.

## A tile is a request

One last thing to carry forward, because it is the connection between all of this and other
people's servers.

**Every tile is one request to somebody else's machine.** A region at z16 is a few thousand
of them; a set with several regions and detail areas at z18 is tens of thousands. That is
why chartMaker paces itself, why it caches everything it has ever fetched and never asks
twice, and why the number in the preflight is worth reading before you press the button.

It is also why display-only sources exist, and why the difference matters. Panning around a
map makes a few dozen requests shaped like your screen. Building a chartset makes thousands,
systematically, as fast as the service allows. Publishers who are happy with the first are
often not happy with the second, and they say so in their terms.

---

**Next:** [Your First Region](regions.md)
