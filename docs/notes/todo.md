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

## BUILD AND FETCH

### The real fetch engine

Improvements to the current FETCH cycle including concepts like:

- queueing of tile fetch requests
- concurrent fetching of tiles over multiple async requests bound by a limit of concurrent requests at any given time
- rate limiting by interval or other techniques
- retry and resume methodologies
- failure classification in cases of dropped connections versus returned negative results

### SOURCE probing and testing

The program shall include the ability to ascertain whether a given source is valid, working,
workable, and to potentially ascertain things like the formats and resolutions it supports,
absent fingerprints it may utilize, the syntax (addressing-order), rate limitations, or other
characteristics.

### Build Analysis Features / Commands

- overzoom detector (downsample/upsample residual)
- identification of, remembering, and noticing sentinel "missing tile" images
- cache cleanups of tiles that are identified as sentinels or overzoomed into 0 length "none"
  or similarly indicated filenames, whether by promoting existing scripts/tools, like
  scripts/tool_prune_absent.pl, or writing new user-facing operation.

### Format conversion at the exporter seam

Decoding and re-encoding one tile, which is an encoder and not the image-processing stack this application refuses.
No resampling, no reprojection, no compositing. It carries a quality preference, and that preference is a legitimate
user-level setting precisely because it changes the bytes without changing what the card asserts - the same ground,
the same zooms, the same source. Anything that changed those would belong to the region, not to a preference.


### Credentials

The linking of sources to private credentials maintained in the $data_dir or other
folder(s) will be implemented and tested with at least one such source.



## SOURCES

### SOURCE Creation, Editing, and Validation

The program shall have the ability for the user to Create, Modify, and Delete Sources (TSD files)

The program shall ship with one or more existing TSDs that are usable for viewing in the leaflet
and, at a minimum, for building example outputs in a tutorial or user manual.

The program and/or documentation will include a catalog of known tile sources (i.e. GIBS) that
may be used for viewing and/or building and a way for users to generate TSDs from that catalog.
This list may include known paid services that require credentials in order to be used under their
respective TOS.





## User-Manual Tutorial

The repo will include a User Manual of a tutorial nature that will onboard users through
the entire process of creating region sets and doing builds within the constraints of the
shipped TSDs.


## Installable Application and Release Cycle

This application will have a sister repo in /base_dist that is used to build a release
Windows EXE installation program.  There will be a defined release mechanism and versioning
scheme ala the way that navMate is currently released.



## OTHER

### raster_chart_format.md

Potential addition of RCT "Build notes in the card" -
the RCT format can carry source, zoom range, encoding and date, etc.

