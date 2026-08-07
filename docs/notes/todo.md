# chartMaker - ToDo List

This is the official chartMaker TODO List.

## This is a Patrick-only document

It is owned by Patrick and is not to be edited or written by Claude.

It contains items that Patrick has determined either will be done, or might be done,
now or in the future to the code, documents, and anything else in this repo, and
potentially other folders associated with this repo, including its distribution
and publishing on github.

Nothing in here shall be construed by Claude to mean that any thing in this file
is actionable, prioritized, or ordered in any sense whatsoever.  This document is
merely a convenience for Patrick to keep a persistent document of his own thoughts.
Patrick, at any time, may direct what is next for Claude to do, including things
that are not in this document.  Patrick may pivot to or change the focus of the
work in this repo at any time.

Except when specifically instructed, Claude shall keep no overriding persistent
notion of a project plan, what is next to do, and furthermore shall not keep any
history or memory of its own as to the overall progress state of this repo and project.

From time to time the work to be accomplished may necessitate the creation of
plan-like memories.   In general those plan like memories are only valid for the
duration of accomplishing that particular task or set of tasks, and once that task
or set of tasks has been accomplished, those plan like memories shall be removed
from Claude's memories.

This document is organized into various sections according to Patrick's current
prioritization or other axes that Patrick determines.  This document and the
structure of it may be changed at anytime by Patrick, and only by Patrick.





## OTHER


### Dont offer dark tiles as blank sentinal possibliities

### cache source display text

I think it takes a long time to swtich between sources and
that occasionally the sources are refreshed during other operations
which slows down the ux thread, even though no new tiles have been
fetched.

My idea is to keep an in memory "version index" per source and
bump it when the tile count changes, and to only regenerate that
text when it is zero or changes and you would have normally done it.

I think the counts are likely what is taking the time.
Not sure but I think its likely.



### Documentation and User Manual/Reference Rework


### Overlay TSD's

Other kinds of things can be served that are of interest including, but not limited to
- vector or rasterized region or political/administrative boundaries
- placenames, bathyrimic data, points of interest, etc
ok,



### navMate use vt, esri and esri clarity layer boxes



### raster_chart_format.md


  ? Two adjacent statements in the Coverage block descriptor section disagree, and producers have been written to the stricter one. The document says
  ? "Blocks within one zoom of one file are disjoint: no tile belongs to two", and then three lines later describes a renderer that scans every block at
  ? a zoom and tests presence rather than rectangle containment. aerial.c confirms the second: block_for walks the whole array calling block_has, which
  ? is the range test and the presence bit in one expression, and its own comment calls duplicates "don't-care". Blocks from every .RCT are fused into
  ? one zoomdir_t at mount, so within-file overlap is indistinguishable from the cross-file overlap that exists on every card by construction; draw_level
  ? iterates the view rather than the blocks, so a cell is drawn once however many blocks hold it; and build_mask says overlap "would be correct but
  ? wasted" and in any case clamps its cut to zoom_author, so overlap finer than that costs nothing at all. Overlapping rectangles are therefore legal
  ? and normal, and the sentence forbidding them is not describing the format. What the format genuinely cannot survive is one tile marked present in two
  ? blocks whose imagery differs, because block_for returns the first match and the array is filled in the order scan_rct_files reads FAT directory
  ? entries, so the picture shown is decided by the order files were copied onto the card. The document currently covers that case only by assumption, in
  ? the clause "duplicates are the same tile by construction", which is a statement about producers presented as a property of the format. It should be
  ? a stated requirement. Note also that the 48-byte descriptor is fully consumed and every field is read by the renderer, so there is no room for a
  ? producer to express a preference between two copies. Suggested replacement for both: "Any two coverage blocks that both mark a tile PRESENT must
  ? serve identical imagery for it, at any zoom, within one file or across every file on a card. Their rectangles may overlap freely. Identical imagery
  ? rather than 'the same source', because one service can serve different bytes for a z/x/y on different days." This is a documentation change only; no
  ? reader or writer code needs to move. It matters because chartMaker enforced the rectangle reading and refused to write files that would have worked,
  ? at the end of multi-minute builds, over two detail areas whose polygons do not intersect at all.


Potential addition of RCT "Build notes in the card" -
the RCT format can carry source, zoom range, encoding and date, etc.
