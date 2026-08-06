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




## Initital implementation Phase T - INSTALLABLE

Installable Application and Release Cycle

This application will have a sister repo in /base_dist that is used to build a release
Windows EXE installation program.  There will be a defined release mechanism and versioning
scheme ala the way that navMate is currently released.

chartMaker has a slightly different set of needs than navMate -
there is only one application as opposed to three in navMate,
and chartMaker has a need to populate the new users $data_dir
in a different way than navMate did.

Thus chartMaker will have its own, slightly different repo /
_installer/PreInstallApp.pm.   It will use a similar releases/
folder, versioning scheme (begining at 0.1.1 pre-release) and
so on.


You have permission to create /base_dist/chartMaker and populate it.

We will need a shell chartMakerGUI.pm scrip like navMate has
and an icon pair for the "pure guid" vs "console + app" executables
that cava will build for us.  For the initial test builds use
the navMate icons (copy them to our appropriate folder). We also
need a favicon in _res/site for the brownser to find.

You are already familiar with how CAVA packager works generally and
specifically via its SQLite database files, icon collections, and so
forth.

Please survey the entire situation,in detail, and show me a plan
and any questions before you create base_dist/chartMaker and we
try a build.

We will only push the 1st pre-release to github after we have built
and tested at least one, but probably several versions.



## OTHER


### Documentation and User Manual/Reference Rework


### Overlay TSD's

Other kinds of things can be served that are of interest including, but not limited to
- vector or rasterized region or political/administrative boundaries
- placenames, bathyrimic data, points of interest, etc
ok,


### raster_chart_format.md

Potential addition of RCT "Build notes in the card" -
the RCT format can carry source, zoom range, encoding and date, etc.

### navMate use vt, esri and esri clarity layer boxes

