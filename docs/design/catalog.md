# chartMaker - Tile Source Catalog

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**Catalog** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

A tile service is only useful to somebody who knows it exists. [TSD](tsd.md) is the format a
source is written in and [the editor](tsd_editor.md) is where one is written; this is the
list of services the application ships knowing about, and the two ways of turning one of
them into a source.

## It is application material, not user data

The catalog is `catalog.json`, read from the resource folder that `Pub::Utils` resolves to
the in-repo `_res` in development and to the bundled resources when packaged. It is **read
only**, it is never copied into `$data_dir`, and `dm_source` never scans for it.

That is the whole reason it can be presumed coherent with the code: it ships with the code
and updates with it. A copy-on-install would have gone stale the first time a service moved,
and would have gone stale silently, in a file the user could not tell from one they had
written.

**What ships and what is catalogued are two lists with two jobs.** The `.tsd` files in
`_res/user_data` are installed into the user's sources folder under an existence guard and
become ordinary editable files. The catalog is a list of what the application knows about.
A source can be in either, both, or neither, and `google.tsd` is deliberately in the first
and not the second.

## A node is a group or an entry

A node carrying `nodes` is a group and a node carrying `tsd` is an entry. The tree nests to
whatever depth the file uses rather than to a fixed two, because services group the way the
world groups them: GIBS over its layers, Esri over World Imagery and Clarity, and whatever
is added next like neither.

**A child inherits the provider-level statement** and nothing that names a particular layer.
The terms, the licence, the attribution, the rate policy and what it may be used for are
said once by the provider; the id, the name, the `cache_key`, the url and the zoom range are
each layer's own. Without that split a provider's licence would be repeated once per layer
and would eventually disagree with itself.

**The child's own value wins outright** rather than merging into its parent's. A
half-overridden policy is a statement nobody wrote.

## What an entry says, and what it writes

An entry has two halves, and the line between them is exact.

Outside the `tsd` block is what a person **reads in order to judge**: the region, the cost,
the real depth, whether it may be built from, what it requires, and one sentence on what it
is worth to a mariner. None of it reaches a source file, and none of it is constrained by
what the TSD format can say.

Inside the `tsd` block is a **TSD field hash**. `dm_catalog` completes it with the three
fields that have exactly one legal value each - `tsd_version`, `tile_size` and `crs` - for
the reason the editor puts them back: a catalog able to state them is a catalog able to
state them wrongly.

**The name in the tree is short and the name in the file is not.** An entry is read under
its provider, so it calls itself "World Imagery"; standing alone in a source list it has to
say whose imagery it is. An entry may state its full `tsd.name`, and where it does not the
name is composed from the path it was found at.

**The suggested file name comes from `cache_key` before `id`**, because `cache_key` is what
the user will see as a folder in the tile cache, and having those two agree is worth more
than having the file agree with the id.

**A declared `displacement` is shown, and shown with the fact that nothing acts on it** -
the same sentence the Sources pane uses. Where imagery is knowingly misregistered the
[survey](../notes/source_catalog.md) names this as the moment to say so: creating a source
is when a person can still decide about it. A panel that showed the field without that
sentence would read as "handled", and one that omitted it - which this one did at first -
lets somebody create a displaced source without ever being told.

## Every service says where to ask it

A service carries a **canonical point**: one place it is known to have imagery, named, given
a position, and given the reason it was chosen. It is inherited exactly like the licence and
the terms, because where a service holds imagery is a fact about the service and not about
one of its layers.

**A service cannot be asked about nowhere.** Every question worth putting to a tile service
is placed - is this url right, how deep does it really go, is that a tile or a blank - and
the answer is only ever as good as the place. The point exists so that the question has one.

**Region prose does not predict where the tiles are, and neither does a bounding box.**
Measured against the live services: the one labelled "Japan" serves real imagery over Bocas
del Toro at z3 and z8 and nothing at z12; the one labelled "France" serves Bocas del Toro at
z12, pixel for pixel the same ground as Esri World Imagery; and "Spain" answers outside Spain
with a 200 carrying a blank JPEG rather than a refusal. A point in the middle of a declared
extent is no better - an extent is where a service is *entitled* to have imagery, which is
not where it has any.

**It is chosen by a person, which is why it ships here.** The choice is a judgement -
somewhere the service certainly flew, on a coast, because that is what this application is
for - and judgements belong beside the terms and the licence rather than being derived at
runtime from something that only correlates. Bathymetry is the instructive exception: what
those services hold is the sea floor, so their points are offshore, and a coastal city would
be the wrong question rather than a better one.

**A service may have no good point, and saying so is an answer.** One whose imagery is
nowhere near a coast is one this application cannot use, so the absence is a finding about
its fit rather than a hole in the file. The position is what may be omitted; the place and
the reason are not.

**It carries no result.** What a service actually answers there changes with the weather and
belongs to whatever asks; what is written here is only where to ask.

## Nothing it ships claims to be current

The dialog says in as many words that a row is a starting point for checking rather than a
fact. Services move, endpoints retire, and terms change without the endpoint changing.

**And it carries no date.** A date on a row reads as a currency it has not got, and it
borrows authority from a precision nobody earned - the entry that was most precisely dated
in this file was also the one that was wrong. The catalog ships inside the installer, so the
release already dates it more accurately than a hand-typed string could, and where each
service was last looked at is recorded once per service in
[the survey](../notes/source_catalog.md).

**A source created from an entry is untested by construction.** The catalog goes nowhere
near the network, so it cannot know whether a url still answers. [Test](tsd_editor.md#test)
is the instrument that finds out - and [the probe](build.md#the-probe) is the one that says
whether the imagery is any good over an area. Pretending otherwise would be worse than saying
nothing.

## The moniker is the join column

Every service carries a `moniker`: one short name, the same string in the survey, in
[the published list](../notes/source_catalog.md) and here. It is inherited exactly as the
licence is, because a provider's layers are all one service, and a child overrides it where
one provider publishes several.

**It is not the id.** An id names an entry and a moniker names the thing an entry is an
entry *of*, so `linz` publishes `linz_aerial`. Keeping the two identical would give a
service a name that reads like a layer the day it gains a second one.

What it buys is that a claim made at one end of the pipeline can be checked at the other.
Without it the three files were three retellings with no common key, and that is not a
theoretical objection: four addresses reached this file having never been fetched, three of
them invented at the distillation step, and no reader could have caught any of them. A test
asserts that every shipped moniker appears in the published list, and
`scripts/sweep_catalog.pl` asks each entry's service whether the address is real.

### What ships, and what is fetched

The line is the rate at which a fact changes.

| Changes on the scale of | Example | Where it lives |
| --- | --- | --- |
| Years | the provider, its terms, its licence, its cost | ships in the catalog |
| Years, and is a dated claim | a measured real depth | ships, dated |
| Months | a provider's layer list | fetched, by Expand |
| Months, and a correct TSD needs it | a layer's tile matrix set, format, time dimension | fetched, by Expand |

**Every node in the shipped catalog is therefore complete as shipped**, and a provider that
publishes hundreds of layers is catalogued at the two or three that were surveyed. What it
actually holds today is a separate act: **Expand**.

That reader speaks protocols the application otherwise does not, and the boundary survives
intact for one reason: **the application still reads exactly one shape of source, an XYZ
tile url.** The catalog speaks other protocols in order to produce one, and nothing it reads
is in the fetch or the build path.

## Expand: what the service says it publishes

A group may declare an `expander` naming a kind and a URL. Only a group may, because what
comes back is a list and a list has to hang under something: an entry that could expand
would have to become a group on being asked, which is a second shape for a node to be in.

**An empty group is legal only if it can fill itself.** Esri World Imagery Wayback publishes
over 150 archived releases and ships none of them, because pinning one would mean choosing a
release on somebody's behalf and inventing an identifier only the service knows. A provider
whose entire content is what it publishes live is a real shape, and it is the shape this was
built for. An empty group with no expander is refused at load, since nothing could ever
appear under it.

**The capabilities URL is stated, not derived.** GIBS publishes a RESTful document at a
path; IGN France and Spain IGN answer a KVP query. Deriving the address from a tile url
would work for the first and fail silently for the others.

**Reading it is `dm_meta`'s job**, and it was already most of the way there. That module
already fetched and scanned both a WMTS `GetCapabilities` and an ArcGIS MapServer's JSON in
order to ask *is this one source right*; expanding asks *what does this service publish*.
Same documents, same scanning, one set of rules about what a ceiling is and where a row
order is declared. A second module reading the same XML would be a second rulebook.

**The url comes from the service's own `ResourceURL` template**, with `{TileMatrix}`,
`{TileRow}` and `{TileCol}` rewritten to `{z}`, `{y}` and `{x}` and any time dimension
pinned to the default the service published. A KVP-only service has no `ResourceURL`, so
the address is built from the `GetTile` operation its capabilities advertises. **No part of
an expanded url is guessed**, which is the whole difference between an entry somebody typed
and one that came from the horse.

A layer is hidden, and counted with its reason, if it publishes no `GoogleMapsCompatible`
tile matrix set - that set *is* Web Mercator at 256 pixels, so a layer without one cannot
be addressed at all - if it serves neither JPEG nor PNG, or if it publishes no template
this reader can resolve.

**An undeclared zoom range is not one of those reasons.** A service that says nothing about
its depth is the ordinary case rather than a broken one, and hiding those would drop exactly
the sources whose depth has to be found by looking. A default ceiling stands in, and the
layer's `notes` say that is what it is. Finding the declared range at all is harder than it
sounds: `<TileMatrixSet>` is two elements sharing one name, a bare reference inside a
`TileMatrixSetLink` and the definition at the top level, so they are told apart by shape -
the definition is the one carrying `<TileMatrix>` children.

**Where depth ties, the service's own order stands.** Sorting equal-depth layers by name
imposes an order nobody chose, and Esri Wayback is the case that proves it: 195 releases at
one depth, published newest first, in a list whose entire purpose is picking a date.

### The structural filter is necessary and nowhere near sufficient

GIBS publishes **1268 layers, of which 1132 are readable**. Nearly every science product it
holds is served as PNG on `GoogleMapsCompatible`, so aerosol angstrom exponent is perfectly
addressable by this application and of no use whatever under a boat. The deepest layer on
that endpoint is z13.

**No usefulness filter exists.** That would be the machine forming an opinion it is not
entitled to, on the one screen a person is looking at in order to form their own. Two things
are done instead, and neither is a judgement about worth.

**The list is ordered deepest first**, where a chart author looks. A z6 climate product
sorts to the bottom without being hidden.

**Layers a service publishes only as PNG are folded into one group beneath it.** The format
is not an opinion: a service publishing both photographs and data products publishes them in
different formats because that is what the two formats are for. GIBS makes the point at
scale - **58 of its 1132 readable layers serve JPEG**, and they are Blue Marble, Landsat,
MODIS and VIIRS true colour, while the **1076** folded ones are aerosol depth, brightness
temperature, soil moisture and rain rate. No GIBS layer offers both formats, so there is
nothing here to choose between.

**It folds rather than filters, because the proxy leaks both ways.** `Landsat_WELD_NDVI` is
a JPEG vegetation index and `GOES-West_ABI_GeoColor` is a PNG photograph. A fold one click
wide, with its rule written on the group it collapses into, survives being wrong about a
layer; a filter would not. A folded layer is an ordinary entry in every other respect: it
inherits the provider's terms from the service rather than from the fold, the filter box
finds it, and it creates a file by the same path as any other.

**The fold appears only when both kinds arrive.** A service publishing one kind has nothing
to separate, and putting its whole list behind a "more" node would hide everything while
distinguishing nothing. Esri Wayback's 195 releases are all JPEG and get no fold.

A group of more than forty stays shut and says how many it holds, because a tree that
unrolled a thousand would bury every other service in the catalog.

### What it costs, and why it is a worker

The GIBS document is **5.3 MB of XML**, and a cold fetch of it was measured at 39 seconds.
So Expand runs on a worker thread under the progress dialog: on the main thread it would
freeze a modal dialog with no way out, and as a background task it would finish at an
unpredictable moment and rearrange a list somebody was reading. **Cancel abandons the answer
rather than stopping the request**, because nothing can interrupt a GET in flight, and the
dialog says so.

**It is asked for compressed**, which is the whole of the optimisation available here.
`fetchUrl` now sends `Accept-Encoding`, and GIBS answers 5,592,197 bytes in **199,393**, a
ratio of twenty-eight to one, taking that read to under two seconds warm. The header was in
its response all along; LWP simply does not ask unless told to. A tile is already a
compressed image and gains nothing, so this only ever pays on metadata.

**Caching the document is not available**, and it was checked rather than assumed. GIBS
publishes `Cache-Control: max-age=1800` with **no ETag and no Last-Modified**, and ignores
`If-Modified-Since`. Wayback publishes an ETag and then **ignores `If-None-Match`**, so its
validator is decorative. With nothing to revalidate against, the only cache left is an
unvalidated one that trusts a `max-age` - us guessing rather than the server telling us,
which is the staleness this design refuses. Compression turned out to be worth more than the
cache would have been.

The result crosses the thread boundary **as text**, encoded once and decoded once, for the
reason the build's report does: a nest of hashes cannot cross as a reference, and cloning it
into shared memory would make a second representation free to drift from the first.

### Nothing fetched is written back

Expanded layers live for as long as the dialog does. Persisting them would recreate exactly
the staleness that keeping the catalog out of `$data_dir` avoided, and it would be worse,
because a cached layer list looks identical to a current one.

A fetched entry is otherwise an ordinary entry: it inherits the provider's licence,
attribution and terms - which a capabilities document does not carry - and it goes through
the same Create plan and the same bridge to the editor, with no special case anywhere. It
carries **no survey date**, because it was not part of the survey, and it says instead that
it was read from the service just now and judged by nobody.

**A shipped entry wins over a fetched one of the same name.** The curated one carries a
measured depth and a sentence about what it is worth, neither of which is in any metadata
document. Replacing it with the machine's version would be a downgrade that looked like an
update.

**An ArcGIS MapServer publishes one tiled layer**, so there is no list to fetch and those
providers declare no expander. What that document offers instead is *refinement* of an entry
already present - the real LODs, `maxScale`, format and tile size - which is a different
verb, and is what [Probe](tsd.md#authoring-and-testing-a-source) already reports about an
installed source.

## Test, before anything is written

**Test asks the service whether an entry is true, without creating it.** Judging twenty
candidates by writing twenty files and testing each one is the long way round to a decision
that can be made first, and it leaves twenty files behind.

It is [the same verifier the editor uses](tsd_editor.md#what-a-test-actually-does), given the
same kind of field hash: an entry becomes one by exactly the path Create would take, so what
is tested is what would be written rather than an approximation of it. The entry hands over
its own canonical point, because nothing on disk names it yet and the verifier finds a point
by matching a saved source's url against this catalog.

**The refuted fields are listed in the summary and not only painted.** The editor is not here,
and a list of colours nobody can see is not a report, so the dialog names each field and says
where it is fixed.

It sits beside Expand rather than beside Create: both go to the network, neither writes a
file, and neither ends the dialog. It takes exactly one entry, because its answer is a column
of levels at a place and there is no way to read twenty of those at once.

## Two exits, and they are not alternatives

**Create writes files.** Every instrument the application has takes a TSD file - the map
shows one, Test and the probe measure one, the source list lists them - so writing files is the
on-ramp to all of it rather than a shortcut past it. Judging twenty services means first
having twenty files.

**Edit opens one in [the source editor](tsd_editor.md)**, with a leaf of `''` so the editor
treats it as a file that does not exist yet: every field purple, Save behaving as Save As,
and its own rules deciding the name and the uniqueness. Nothing is written unless the person
saves it. That is the exit for the entry somebody has already decided about, and it is where
a value only a person can supply gets typed.

## Create is a preflight, and the rules are the editor's

The editor settles uniqueness by asking a person, which is right for one file and impossible
for twenty. Create enforces **the same constraints** and differs only in resolving them up
front, showing the whole outcome, and taking one answer.

| Collision | What happens | Why |
| --- | --- | --- |
| The `id` is already installed | skipped, naming the file that holds it | The id is what a region points at, so inventing a new one would produce a source nothing refers to. It also almost always means the entry is already installed, which is the answer the user wanted. |
| The `cache_key` is held against a **different** url | skipped, naming the file that holds it | Renaming it *would* work, and would quietly begin a second copy of a cache that may hold gigabytes. That is precisely what `cache_key` exists to prevent. |
| The `cache_key` is held against the **same** url | not a collision | Two files addressing one service is what a declared `cache_key` asserts. |
| The file name is taken | renamed, and the rename is stated | The file name is the container and nothing points at it. It is the one thing that may be invented. |

**What is skipped is shown as prominently as what is written.** A list that showed only the
writes would read as though the rest had happened too.

**Entries in one plan cannot collide with each other either.** A plan that checked only what
was on disk would schedule two writes to one name and report both as creations.

## A keyed entry is created, and says what it is

A declared key_name is a legal url placeholder, so an entry needing an API key writes a
well formed file that loads, with the name declared and no value in it. The detail panel
names each key, says whether anything is bound to it, and where a value is missing gives
the `obtain_url` as the place to get one.

**Create and Test may PROMPT for a missing key**, because a person is sitting here and has
just clicked something. That is one of only two surfaces allowed to ask; build and probe
report and stop. See [Key Store](key_store.md#prompt-where-a-person-is-authoring-fail-where-the-act-is-mechanical).

**Expand needs a key before any file exists**, since a keyed service's capabilities
document is keyed too - which is the whole reason the store is a free standing map of name
to value rather than something hanging off an installed source. And what comes back has the
live key baked into it, so it is stripped back to `{key_name}` before anything is written.

## Where it is reached, and what it costs to open

`Edit > Tile Source Catalog...`, the `Catalog` button on the Sources pane, and that pane's
right-click menu. All three open the one dialog, the way the editor has three ways in. It
sits beside `New Source` rather than in the File menu because it is the other way of
arriving at the same act.

It is the sources pane in a dialog: a tree on the left with a filter above it, and what the
selection says on the right. That is the shape somebody already reads sources in, and it
uses no control the application did not already have.

A tree has no columns, so the two or three facts that decide whether an entry is worth
opening travel in the label itself. They are stated by the entry rather than composed,
because the useful compression differs: a source with no ceiling has to say whether a depth
is *stated* or *real*, and an overlay has no depth at all.

**An installed entry is marked rather than hidden.** On a second visit the point of the list
is largely to see what you already have.

Opening it reads one file that shipped inside the application, so it is instant and it works
with no connection at all. For a window whose entire content ships in the installer, nothing
else is defensible.

---

**Next:** [Build](build.md)
