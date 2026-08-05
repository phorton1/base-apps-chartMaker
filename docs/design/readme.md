# chartMaker - Design

**Design** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)** --
**[Cleanup](cleanup.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

Where [Architecture](../architecture.md) says what chartMaker is and why it is shaped the
way it is, these documents say how it is actually built - the level at which decisions stop
being philosophy and start being data structures, file formats and rules a program can
check.

Two of them describe things a user can hold in their hand and hand to somebody else - a
**region** and a **source**. Two describe things chartMaker writes - an **mbtiles** file and
**RCT files**. One describes what happens in between, and one what happens afterwards, when
what a build and a season of browsing left behind has to be reckoned with. The remaining
five are about changing the model: the rules both coverage-authoring surfaces obey, then
each of those surfaces, then the editor for a source, and then the shipped list a source can
be created from without writing one.

## The documents

- **[Regions](regions.md)** -
  The coverage model on disk: the region file and its nested subregions, how depth is
  requested and where it is capped, the containment and overlap rules, and the workspace
  that holds regions without being a project file.

- **[Editing](editing.md)** -
  The rules for changing the coverage model, stated for no particular interface: the modes,
  what dirty means, when an action is refused, and what the two authoring surfaces must
  agree about.

- **[Map Editing](editing_map.md)** -
  The Leaflet applet: right-click menus, drawing and editing bars, the create dialogs, and
  the snap-to-grid that makes a shared boundary exact without anything having to track it.

- **[Tree Editing](editing_tree.md)** -
  The wx region tree: the two levels that each name something on disk, the zoom columns
  that make a set's inconsistency visible, staged properties with Save and Revert, and what
  it does while the map holds an edit.

- **[TSD](tsd.md)** -
  The Tile Source Definition in full: every field, the closed placeholder set, the
  validation rules, what key names are and are not, and how a source is authored,
  tested and evaluated.

- **[TSD Editor](tsd_editor.md)** -
  Writing and changing a source from inside the application: why it is a dialog, why it
  lists files rather than loaded sources, what the three field colours mean, and what Save
  requires before it will write anything.

- **[Catalog](catalog.md)** -
  The tile services the application ships knowing about: why the list is application
  material rather than user data, what a catalog entry says that a TSD cannot, the two ways
  out of it, how creating twenty sources at once keeps the editor's rules without asking
  twenty questions, and what asking a service for its own layer list does and does not
  settle.

- **[Build](build.md)** -
  The build as one act: the two preflight dialogs, what it refuses before it starts, the
  tile proxy every request passes through, the cache and its keying, and the preview that
  answers what a build will actually contain.

- **[MBTiles](mbtiles.md)** -
  An output and not a hub: what chartMaker writes into a standard MBTiles container, why
  the file is one per node, and the metadata that carries provenance downstream.

- **[RCT](rct.md)** -
  The E-Series raster format: what chartMaker guarantees a reader, the nested coverage the
  format depends on, and the two constraints only the producer can see.

- **[Cleanup](cleanup.md)** -
  What accumulates and how it is removed: the four things that count as using a source, why
  a declared blank is reclassified rather than deleted, why a trim keeps the absence markers
  and refuses a cache no region uses, and why none of it ever happens on its own.

---

**Next:** [Regions](regions.md)
