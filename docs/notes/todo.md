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




## Initital implementation Phase S - USER MANUAL

Reference-Like Tutorial

The repo will include a User Manual of a tutorial nature that will onboard users through
the entire process of creating region sets and doing builds within the constraints of the
shipped TSDs, and explaining how they can use our catalog and build their own tsds.

The attitude, voice, and basic structure of the user manual would be very similar to that of the
navMate /user_manual.  You will have permission to create that folder when the in-context plan
for the user manual is completed.

One interesting question that may have changed since program inception is whether or not there
are now any tile servers that have a TOS that we can use to drive the tutorial besides the low
res GIBS weld tileserver.   In that regards there is a question as to whether the manual should
only show images (screenshots) of the actual sources and the user can legimately use, or better
ones.

Another interesting question is whether or not we provide a fixture initial region set as
demonstration data.

I note that this version of claude seems to have better control of the app and leaflet at
runtime than previous versions and my idea is for you to at least prototype actual screen
grabbed images in the document.  I find that at least one or sometimes a few screenshots
makes the user manual much more visually apealing to the user.

We will need to start with an outline of the md files that will exist, and their contents,
and how we guide the user through creating a region set, modifying it, adding subregions
etc, the relationship between sources and rendering and building, previewing and probing
sources versus regionsets,  building outputs.  I view the Catalog and building of TSDs almost
as more reference like additional things in addition to things like managing and using the
preferences, key store, managing the cache, and so on, so maybe the user manual itself is broken into a
Tutorial and Reference sections, although I dont want to try to build a complete reference
to every possible concept in the system.


All of this must be carefully couched in the fact that we dont deliver tiles and that the
user accepts any responsibility for the tiles they view or build.  The user manual should
definitely include a reference and link to our own licences and main design documentation
but should not contain many embedded references to it, although a few strategic refernces
to technical docs might be appropriate.


I am looking for something that we can complete in one or two context windows.
You can do more in a single context window than you think you can.

### Example Region and User Built Region

I can see us providing a region around Elvissa with a few subregions as
a standing example, and guiding the user through creating an additional
region aroudn Formenttera with a subregion in it.  I can even see how we
"optimize out" of the center of Elvisaa for file size by drawing our region
correctly (possibly as two disjoint polygons).
































## Initital implementation Phase T - INSTALLABLE

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

