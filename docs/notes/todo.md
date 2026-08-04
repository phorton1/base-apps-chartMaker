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




## Phase P - KEY STORE

The linking of sources to private credentials or api keys maintained in the
$data_dir or other folder(s) will be implemented and tested with at least
one such source.

He have only a crude slot mechanism in tsds, no defined storage mechanism,
and a number of source_catalog.md entries not yet in catalog.json.
This may require me to obtain free keys or trial tiers to various
service, etc.  Please give me your idea of what we need to do for
CREDENTIALS.


## PNGS

Format conversion at the exporter seam

Decoding and re-encoding one tile, which is an encoder and not the image-processing stack this application refuses.
No resampling, no reprojection, no compositing. It carries a quality preference, and that preference is a legitimate
user-level setting precisely because it changes the bytes without changing what the card asserts - the same ground,
the same zooms, the same source. Anything that changed those would belong to the region, not to a preference.


## CACHE CLEANUP utility

to tiles only in some existing regionset

tiles get accumulated in testing and I have no way to easily trim the cache back to the tiles
I actually need.

cache cleanups of tiles that are identified as sentinels after fingerprints have been identfie





## USER MANUAL

Tutorial

The repo will include a User Manual of a tutorial nature that will onboaand rd users through
the entire process of creating region sets and doing builds within the constraints of the
shipped TSDs.


## INSTALLABLE

Installable Application and Release Cycle

This application will have a sister repo in /base_dist that is used to build a release
Windows EXE installation program.  There will be a defined release mechanism and versioning
scheme ala the way that navMate is currently released.



## OTHER



### Overlay TSD's

Other kinds of things can be served that are of interest including, but not limited to
- vector or rasterized region or political/administrative boundaries
- placenames, bathyrimic data, points of interest, etc
ok,


### raster_chart_format.md

Potential addition of RCT "Build notes in the card" -
the RCT format can carry source, zoom range, encoding and date, etc.

### navMate use vt, esri and esri clarity layer boxes

