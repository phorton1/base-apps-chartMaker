# chartMaker - TSD Editor

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**TSD Editor** --
**[Catalog](catalog.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

Sources are written, changed and removed from inside the application. [TSD](tsd.md) is the
field reference; this document is what the editor does with those fields.

It is reached three ways: `Edit > New Source...`, the right-click menu on the source list,
and an `Edit` button beside `Probe`. Every one of them opens the same dialog.

## A dialog, not a pane

The regions editor is a pane because a region is a spatial object edited against a spatial
view: you need the map in front of you while you set a `zmax`. A TSD has no geographic
content at all, so the single thing a pane buys is the single thing this does not need.

What a dialog buys instead is a transaction. Open, edit, Save or Cancel, and no question
about what becomes of half-typed text when somebody clicks a different source in the tree.

## It edits a file, not a source

The dialog is built from a plain field hash rather than from a loaded source, and that is
what lets it open a file that **does not load** - which is the case that matters most,
because a refused file is exactly the one somebody has to repair.

**The source list shows files.** Every `.tsd` in the folder appears, whether it loaded or
not. One that did not is drawn in red and reads `name.tsd - REFUSED`, and the reason appears
as red text in the panel above the properties. It can be selected and edited; it cannot be
shown on the map, fetched from or probed, because it is not a source.

The one file the editor cannot open is one whose JSON is malformed, because there are no
fields to show. It says so and stops.

## Colour is the state, and there are three

| Colour | Means |
| ------ | ------------------------------------------------------------------------ |
| Red    | The editor knows this field is wrong. |
| Orange | A web hit has **proven** this field wrong. Nothing in the editor can decide this. |
| Purple | Changed since the last commit. Every field of a new file is purple. |

**Red beats orange beats purple**, on the label and on the text of the control.

**There is no "unproven" state.** A purple field is taken to be correct until something
proves otherwise. Nothing is stored, nothing goes stale, and the absence of a colour is not
a claim that anything was checked. One piece of bookkeeping follows: an orange finding is
dropped the moment its field is edited, because a refutation of a value that no longer
exists is worse than no finding at all.

**One reason line**, at the foot of the dialog. The colour on the field says *which*; the
sentence says *what*. The properties control in the source pane is a plain text control and
cannot colour a line, which is why a refusal is stated above it rather than inside it.

## What Save requires

**Save needs the file to be dirty AND coherent.** Coherent alone would let an idle click
rewrite a file nobody had changed, and that is not harmless: the writer emits canonical field
order, so it would reflow somebody's hand-formatted TSD and move its timestamp for no change.

**Save As needs only coherent**, because copying an unchanged file to a new name is how a
variant begins.

**Nothing red can be written.** An editor able to write a file the loader will refuse is an
editor able to make its own work vanish from the list, with the reason in a log rather than
in front of the person who caused it.

Coherence is asked of `dm_source` twice and in two grains: `checkSourceField` for one value,
which is what colours a field, and `checkSource` for the whole file, which is the same
verdict the loader gives. Both live in `dm_source` because a copy of those rules in the
dialog would be a second rulebook able to disagree with the one that decides what loads.

## Identity, and what each operation costs

The three names and their three jobs are set out in [TSD](tsd.md#the-cache-is-keyed-by-source).
What the editor adds is that uniqueness is settled **before** writing rather than discovered
on the next scan, because a collision refuses *both* files - so writing a colliding file
would break the one that was working a moment ago.

- **Changing `id`** is a region-reference question. The cache is untouched.
- **Save As** takes a new file name, and the `id` has to be new as well.
- **Delete** removes the `.tsd` and never the cache. Tiles are keyed by `cache_key`, another
  file may address them deliberately, and deleting a definition says nothing about imagery.
  It warns first, and names the regions that will stop resolving.

## What it does not touch

`credentials`, `absent_fingerprints` and `absent_headers` have no controls yet and are
**carried through unchanged**. A file that lost them by passing through the editor would be
a file quietly damaged by being looked at.

`tile_size` and `crs` have exactly one legal value each, so no control offers them: an
editable one could only ever be used to make the file invalid.

## Test

**Test asks the service whether the values in this dialog are true.** It runs on a worker
under the progress dialog, it changes nothing here or on disk, and the answer arrives in two
places at once.

The contract with the dialog is two calls, `setProven($field,$why)` and `clearProven()`.
Orange paints, loses to red, and is dropped when its field is edited, so a refutation of a
value that no longer exists cannot survive. Neither call can edit a value, which keeps
*nothing rewrites a TSD without a person* true. Every previous finding is dropped before a
run starts, because a mark left over from a run being replaced is a claim nothing currently
supports.

**The answer lands twice, deliberately.** Fields the verifier can name go orange here, where
they are edited. *All* of it goes into a modal summary, because a person who pressed a button
expects to be answered by a dialog, and because the same rendering has to serve the catalog,
where there are no fields to paint. The summary is where the columns, the levels and the
suspected blanks are read.

**A test is not a preflight to a save.** A save is a disk act and a test is a network act,
and making one a precondition of the other would mean no saving while offline and no saving
a source whose service is down. It also tests the values **in the dialog**, never the file on
disk, so it cannot disturb a working source.

Every field row carries an annotation slot beside it, because a finding belongs next to the
field it is about.

## What a test actually does

Two halves, and only one of them has a place.

**Unplaced, and it can only ever refute.** The file's own coherence, asked of `dm_source`
because a second opinion about what a TSD may be is a second rulebook, plus the service's own
metadata where it publishes any - which is [the probe](build.md#the-probe), unchanged and not
reimplemented. This half settles a malformed url, a credential slot the file does not
declare, the wrong grid, a scrambled row order, a ceiling below what is claimed. It never
confirms imagery and is never worded as though it had.

**Placed: a column of tiles over one point**, every level from the declared floor to the
declared ceiling, walked in full.

### The place is never derived

Measured against the live services on 2026-08-04: a service labelled "Japan" serves real
imagery over Bocas del Toro at z3 and z8 and nothing at z12; one labelled "France" serves
Bocas del Toro at z12, the same ground as Esri World Imagery pixel for pixel; and "Spain"
answers outside Spain with a 200 carrying a blank JPEG. Region prose predicts nothing, a
declared extent is where a service is *entitled* to hold imagery rather than where it does,
and the middle of a bounding box is water as often as not.

So a point comes from the [catalog](catalog.md#every-service-says-where-to-ask-it), where a
person chose it, or from the user, and from nowhere else.

**The user's point is the map's centre when there is a map**, and what is selected in the
tree when there is not. Where somebody is looking right now is a more current statement of
where they care than a selection made at some point, and it is the one they can change in a
second if the answer surprises them; a region or a subregion is the only other thing in this
application that is a place a person chose.

**The map's centre rides on `/poll`** for the reason the probe's sequence does: `/poll` is
already the one message that says a map exists, and where it is looking is part of what that
means. It is not persisted and it expires with the poll, because a remembered centre from a
map since closed is a stale place presented as a current one.

**A selected node contributes its position and not its band.** The full declared range of the
source is walked either way, because a test is about the *service* and the region is only
supplying an additional "here". Walking each node's own band would answer a different
question for every node, which is the opposite of a baseline.

### Two columns, doing different jobs

**The canonical column** is somewhere the service is known to have imagery, so an empty
answer there is about the service. It is the only column entitled to say a source works.

**Your column** is wherever the map is looking. It has nothing to be compared against, so it
is *descriptive* and can never fail. A service with nothing at Bocas del Toro is not a broken
service, and the report says so in words rather than leaving the reader to infer it.

**The column is walked in full and never stops at the first hit.** Japan GSI over Tokyo
answers z2 to z18 unbroken and refuses z0 and z1; over Panama it answers only z3 to z8.
Present in the *middle* of the column, with no floor to climb from and no ceiling to descend
from. Stop-at-first-hit would call that a pass and say nothing about the levels a chart is
actually built at.

### The status is not the answer, the body is

Of twelve services measured, four returned a 200 for something that was not imagery: a JSON
refusal carrying `Token Required`, a 929 byte blank JPEG, a 334 byte transparent PNG, and a
white world with one blue speck of New South Wales painted on it. A verifier reading status
codes would have passed all four.

So each level is classified from what came back. A declared `absent_fingerprint` is asked of
`dm_fetch` rather than measured again here, because that test having two implementations is
not a hypothetical fault - it is a bug this application has already had.

**And what the server said is carried whole.** A 200 carrying text is the one failure that
explains itself, and discarding it cost exactly the sentence somebody needs: Queensland
answers a tile request with 200 and `{"error":{"code":499,"message":"Token Required"}}`,
which says in four words what "not a recognised image" cannot say at all. Markup is stripped,
it is reduced to one short line, and it is not gathered for a 404 - that is a definite
absence whose body cannot tell a missing tile from a wrong path, which is a question the
shape of the column answers instead.

**Every level is printed and none is collapsed.** The shape of a column is what a person
reads it for. What twenty identical lines fail to supply is the reason, so a column that
answered the same way throughout gains **one sentence** saying so, with the server's own
words beneath it.

**A blank the file does not declare is found from the column itself**, with two signals of
very different strength and worded differently:

- **The same image at several levels is conclusive** and needs no threshold. Zooming in
  changes what a tile contains, always, so one identical image answering four levels is not
  imagery at any of them. Esri World Imagery declares z23 and returns the same 2521 byte
  JPEG at z20 through z23 over Singapore; its real ceiling there is z19.
- **Far smaller than its own column** is a suspicion and says so. Open water is genuinely
  small, so this only fires where the rest of the column is substantial.

Either way the bytes and the md5 are **offered** as an `absent_fingerprint` and never added.
A checker that quietly corrected the file it was checking would make every source a cache of
a server's current mood.

### Three outcomes, and only one is a pass

| | |
|---|---|
| **It works** | a tile arrived at the canonical point |
| **Nothing was disproved, and little was proved** | it answered, and little was settled |
| **There are problems** | something was disproved, or the service refused |

The middle one is the honest result for a service that publishes no metadata and has no
canonical point, and it is **not** a pass. A source with nowhere to be asked says *nowhere to
ask* rather than implying anything.

### It is always a worker

Not because of the count but because of the first request: a dead host burns the whole
timeout before anything at all is known, and that is exactly when somebody most needs to see
that it is asking rather than hung. The progress dialog names the place and the level it is
on.

## The window is the user's

It is resizable, and **where it was left and how big it was left are remembered** across
opens - recorded on Save, Save As, Cancel and the title-bar close alike, and kept with the
other per-machine facts in the ini rather than in anybody's preferences. A remembered
rectangle is checked against the display before it is used, so a monitor that has been
unplugged cannot put the dialog somewhere unreachable.

The fields scroll; the reason line and the buttons do not. A field list grows - credentials
and the two absence lists have no controls yet and will want them - and the way out of a
modal dialog must never be the thing that falls off the bottom edge.

---

**Next:** [Catalog](catalog.md)
