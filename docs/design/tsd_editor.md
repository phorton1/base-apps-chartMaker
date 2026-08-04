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

**The button exists and its behaviour does not.** Verification against a live service is a
later phase; what this phase owes it is somewhere for an answer to land.

The contract is two calls, `setProven($field,$why)` and `clearProven()`. Orange already
paints, already loses to red, and is already dropped when its field is edited, so the phase
that writes the test touches nothing else in the dialog. Neither call can edit a value,
which keeps *nothing rewrites a TSD without a person* true.

**A test is not a preflight to a save.** A save is a disk act and a test is a network act,
and making one a precondition of the other would mean no saving while offline and no saving
a source whose service is down. It also tests the values **in the dialog**, never the file on
disk, so it cannot disturb a working source.

Every field row already carries an empty annotation slot beside it, because a finding belongs
next to the field it is about and a row with no room for one would have to be rebuilt.

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
