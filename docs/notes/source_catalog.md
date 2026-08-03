# chartMaker - candidate tile services

Surveyed 2026-08-01. A working list of tile and imagery services that could plausibly
be used with chartMaker, with what each operator's own published terms appear to say.

**Every service listed publishes a tile pyramid.** chartMaker reads one shape of source:
a remote XYZ tile service serving 256 pixel tiles in EPSG:3857. A service that renders an
image per request, or that publishes its tiles on a national grid, cannot be addressed by
a tile client at all, so it is not a candidate here whatever its licence or its imagery.

**This is not legal advice and not a ruling.** The terms columns summarise what was
found at the operator's own published terms on the date above, and the obligation to
read them belongs to whoever uses a source. Services move, endpoints retire, and terms
change without the endpoint changing, so treat every row as a starting point for
checking rather than as a current fact.

**Viewing is assumed permitted** wherever a credential or licence has been properly
obtained, so there is no display column. The column that varies is **Buildable**: may
tiles be systematically retrieved and cached offline, which is what constructing a
chartset is. Where a lookup was made and the answer could not be determined, the entry
reads `indeterminate` rather than guessing.

**Nothing here decides what is useful.** Where a source has a known registration
error, or where an operator states a fitness limit in its own terms, that is recorded
as the fact it is. What a user does with the information is theirs to judge: they may
have a consumer that compensates for an offset, or a purpose that is not navigation.

Two axes decide the practical value of everything below, and they are in tension:
**depth and geography**. Nothing found is free, deep and global at once. The free deep
services are national. The deep global services are commercial.

---

## Open licence and public mandate

| Source | Region | Buildable | Cost | Real depth | Value to a mariner |
| --- | --- | --- | --- | --- | --- |
| NASA GIBS, Blue Marble | global | yes, US Government work | free, no key | z8 | A backdrop. Far below chart depth. |
| NASA GIBS, Landsat WELD annual | global | yes, US Government work | free, no key | z12 | Ocean scale. Below the depth a chartset wants. |
| Copernicus / Sentinel Hub | global | yes for the data under EU open data policy; the service applies its own quota | free tier, key embedded in the URL path | Sentinel-2 is 10 m native, so real detail ends around z14 | Too shallow for a chart. Notable for putting its credential in the path rather than a query parameter. |
| EOX Sentinel-2 cloudless | global | the 2016 mosaic is CC BY 4.0; the 2018 to 2024 mosaics are CC BY-NC-SA 4.0, so non-commercial and share-alike | free, fair use; production use is a paid tier | z13 | Shallow, and the later mosaics carry a licence that restricts reuse. |
| OpenAerialMap | global | yes, CC BY 4.0 with Open Imagery Network attribution | free | varies per contributed image, occasionally very high | Opportunistic. Coverage is wherever somebody flew and uploaded, so it is a supplement and never a base source. |
| Allen Coral Atlas | global reefs | yes, CC BY 4.0 | free | benthic mapping under 10 m water, geomorphic under 15 m | A classification product rather than imagery, and genuinely relevant to reef navigation. |
| GEBCO | global | yes, public domain, attribution required | free | coarse | Bathymetric context. Commercial exploitation is expressly permitted. **GEBCO's terms of use state the grid should not be used for navigation or any purpose involving safety at sea**, and that users must not imply IHO or IOC endorsement. |
| OpenSeaMap seamarks | global | yes, ODbL, which carries share-alike obligations | free | transparent overlay | Seamark overlay. Most tiles are empty. |
| USGS Imagery Only | United States | yes, US Government work | free, no key | z16, confirmed from the service metadata | The best free option in US waters. The service declares `format: MIXED`, so PNG tiles can appear where JPEG is expected. |
| NOAA Chart Display Service | US waters | yes, US Government work | free | chart rendering rather than imagery | NOAA ENC data drawn with paper-chart symbology. Also distributed as MBTiles for offline use. |
| IGN France, overseas departments | Guadeloupe, Martinique, Guyane, Reunion, Mayotte, Saint Pierre et Miquelon | yes, French open licence with attribution | free, no key | z19, confirmed from the tile matrix set `PM_0_19` | The only open source found at chart depth over Caribbean cruising ground. |
| IGN France, metropolitan | France | yes, French open licence with attribution | free, no key | z19, confirmed from the tile matrix set `PM_0_19` | The deepest open imagery found anywhere in this survey. |
| Spain IGN PNOA | Spain | yes, CC BY 4.0; the WMTS `AccessConstraints` field states "CC BY 4.0 scne.es" and `Fees` states none | free, no key | **z0 to z20** in EPSG:3857, confirmed from the WMTS capabilities. 25 cm and 50 cm mosaics, updated several times a year | Layer `OI.OrthoimageCoverage`, jpeg and png, tile matrix sets for EPSG:3857 and GoogleMapsCompatible among others. Reachable today with no new request path. |
| EMODnet bathymetry | European seas | yes, attribution | free | coarse | Bathymetric context for European waters. |
| Norway, Norge i bilder | Norway | no; access is reserved to Norge digitalt parties | token required | published in UTM grids rather than EPSG:3857 | Not reachable. Open access was withdrawn, and older recipes pointing at the previous endpoints are still circulating. |
| Digital Earth Africa | Africa | yes | free | Sentinel derived at 10 m, so real detail ends around z14 | Continental context. No chart depth. |
| South Africa CD:NGI | South Africa | the imagery is open, but no official tile service was found | free, distributed on physical media | 25 cm source imagery | Only a community-hosted mirror exists on the web. Open data and a usable tile service are separate things, and a tile client needs the second one. |
| LINZ Basemaps | New Zealand | yes, CC BY 4.0 | free API key; **standard access is capped at 1,000 tile requests per minute**, developer access is uncapped | **z0 to z22** in EPSG:3857, per LINZ documentation. 5 cm over urban areas down to 10 m satellite elsewhere | Excellent New Zealand coverage including the Chathams and the offshore islands. WebP, JPEG, PNG or Avif. **Standard access uses a rotating dynamic key and developer access a static one**, and only the static one can live in a credential slot. |
| NSW Spatial Services (SIX) | New South Wales | yes, CC BY 4.0, with an added term asserting DCS Spatial Services as author of the original material | free, no key | declares LODs **0 to 23** with `maxScale` also at level 23, so the service states no real ceiling; 10 cm over towns above 500 people, 50 cm regional | Excellent on that coast. `format: MIXED`, so PNG can appear where JPEG is expected. Newer and higher-resolution coverage supersedes older below 1:150,000, so depth varies by place. |
| Queensland Government | Queensland | yes, but the licence varies per image between CC BY, CC BY-SA and public domain, so it must be checked per dataset rather than once | free, no key | tile cache built to 1:1129, which is level 19 | Excellent on that coast. The whole-of-state satellite mosaic derives from Planet and is CC BY-SA, which imposes share-alike on anything built from it. |
| Japan GSI, seamlessphoto | Japan | yes, subject to the conditions in the GSI tile terms | free, no key | z18, confirmed from the layer specification | Excellent in Japan. Returns 404 outside the country, so an absence is unambiguous. |
| Tianditu | China | `indeterminate`. The service is marked noncommercial with registration required for commercial use; the operative terms are published only on `tianditu.gov.cn` and were not readable | free, but the key requires a mainland China (+86) mobile number to register | not yet checked | **The imagery is aligned to GCJ-02, not WGS 84**, as Chinese regulation requires, so it sits 300 to 500 m from the coordinates it is served at, varying with position. The tile grid itself is correct EPSG:3857, so nothing structural is wrong and no check detects it. Anything built from it is misregistered by that amount unless the consumer compensates. |

---

## Commercial

| Source | Region | Buildable | Cost | Real depth | Value to a mariner |
| --- | --- | --- | --- | --- | --- |
| Esri World Imagery | global | **no.** The item's own `licenseInfo` states "This layer is not intended to be used to export tiles for offline", and Esri's general terms prohibit systematically harvesting a Service. **Viewing is a different matter**: the general terms grant anyone the right to "download, view, copy, and print" for internal or noncommercial external purposes, no named permission needed, which is why the endpoint is used openly everywhere | Esri Master License Agreement; free noncommercial use is at Esri's determination | declares LODs **0 to 23** with `minScale` and `maxScale` both 0, so the service states no ceiling at all and will answer anywhere by upsampling; real cached detail is around z19, measured at z17 to z18 over Panama | The deep global source. JPEG at 90 percent quality. Sourced from Vantor products at 15 cm to 1.2 m plus community aerial down to 3 cm, and 15 m TerraColor worldwide. |
| **Esri World Imagery (for Export)** | global | export is permitted up to 150,000 tiles per request, and the licence scopes **those** exported tiles to "offline use in ArcGIS applications and other applications built with an ArcGIS Runtime SDK". That scoping is a term of this product and does not govern the public World Imagery endpoint | Esri Master License Agreement. **Requires an ArcGIS Online organizational subscription or an ArcGIS Developer account**, consuming no credits. Access is by signing in, or by registering an application and using its credentials | as World Imagery | `https://tiledbasemaps.arcgis.com/arcgis/rest/services/World_Imagery/MapServer`. Unreachable from a TSD regardless of licence: authentication is a credential handshake, and a declarative file cannot make one request in order to construct another. |
| Esri World Imagery (Clarity) | global | **no**, on the same Esri Master License Agreement and general terms as the other Esri layers | Esri Master License Agreement | declares LODs **0 to 23**, `maxScale` at level 23, so no stated ceiling | An alternative view onto the Living Atlas archive that is often clearer than the default, at the cost of being older. In mature support since January 2022 and scheduled to retire in March 2028. |
| Esri World Imagery Wayback | global | **no**, on the same Esri Master License Agreement and general terms as the other Esri layers | Esri Master License Agreement | as World Imagery, per archived release | Over 150 archived releases back to February 2014, each addressable by release id and each pinned permanently. The available answer to cloud, sun glint, turbidity and tide state, none of which depth fixes. |
| MapTiler | global, with deep coverage over USA, Europe and Japan | the Cloud terms forbid storing or redistributing tiles from a cache; the Engine and on-prem data products permit generated tiles to form part of the customer's own products | Cloud from about USD 29 per month; on-prem quoted | 8 cm over USA, Europe and Japan; 10 m cloudless elsewhere | The only commercial source found that offers a licensed path to offline chart building rather than only a prohibition. |
| Maxar, Planet, Airbus | global | contract dependent | quotation and subscription; no free tier | 30 cm global for Maxar Vivid | The paid answer to tropical depth. |
| Google | global | **no.** The published Google Maps and Map Tiles policies forbid pre-fetching, caching for offline use and bulk downloading of tiles, which is a direct description of building a chartset. Viewing is the ordinary use and is what every public tile client does | the undocumented `mt{0-3}.google.com/vt` path is free and needs no key; the documented Map Tiles API is keyed and billed per request | answers to about z21. It never returns 404 and never returns a fixed no-data image, so it magnifies past real detail indefinitely and **no absence can be detected at all**; byte means per level measured 12843, 9212 and 6957 across z20 to z22 over one area, which is magnification rather than absence | The deepest and most widely available global imagery. The `lyrs` code selects the layer: `s` satellite, `y` hybrid, `m` map, `p` terrain. The `/vt` path is undocumented, so it has no published terms of its own and no deprecation notice either: it will fail one day as a 403, a redirect or a placeholder rather than as an announcement. |

---

## Excluded, and why

- **Bing / Microsoft.** Left out because it cannot be expressed as a chartMaker source
  at all: the documented route requires a metadata call that returns the real URL
  template and valid subdomains, and a TSD has no way to make a request in order to
  build a request.
- **Yandex.** Published in EPSG:3395 elliptical mercator. A different grid, so the
  tiles cannot align with anything chartMaker produces.
- **Apple.** The tile endpoint requires a session token from a MapKit handshake and is
  not reachable by a plain tile client.
- **Maxar and DigitalGlobe imagery via OpenStreetMap.** The grant was withdrawn around
  2021, though recipes pointing at the old endpoints remain widely published.
- **OpenStreetMap standard tiles**, and the other community basemaps on the same
  footing. Fair use for viewing, with bulk downloading prohibited by the tile usage
  policy, and in any case a rendered map rather than imagery.

---

## Commentary

**No open source reaches chart depth over Central or South America.** The Central
America and Caribbean row above is IGN France covering the French overseas
departments, and there is nothing else. No national imagery tile service was found
for any other Caribbean or Central American country, and the South American national
services that were found are topographic or thematic rather than orthoimagery. For
that ground a commercial global mosaic is the only option that reaches useful depth.

**Where a national service exists, it usually beats the global commercial mosaics.**
IGN France at z19, Japan GSI at z18, LINZ at 5 cm and NSW at 10 cm are all deeper than
a 30 cm global product, all free, and all carry an open licence rather than a
negotiation. The catch is that each stops at its own border.

**Depth is not the only axis of imagery quality over water.** Cloud, sun glint,
turbidity and tide state vary between passes, and a current mosaic is whichever pass
the operator selected rather than the clearest one. Esri World Imagery Wayback is the
only service found that makes an alternative pass addressable, by publishing every
archived release separately.

**A national service is only listed here if it publishes a tile pyramid.** Spain's WMTS at
`https://www.ign.es/wmts/pnoa-ma` is the southern European entry that qualifies, and it is
reachable today. Several neighbouring countries publish orthophotography that no tile client
can address, so it is not a candidate and does not appear.

**Two entries carry statements a licence field cannot hold, and they are different in
kind.** GEBCO's terms of use say the grid must not be used for navigation or any
purpose involving safety at sea, which is an operator stating a limit about its own
product. Tianditu's imagery is displaced several hundred metres by regulation, which
the operator does not state and no structural check reveals.

Neither is a reason to stop anyone using either one. A consumer may apply its own
offset, and a purpose may not be navigation at all. What the two cases do establish is
that **misregistration is detectable in advance where it is known**, so a source whose
imagery is known to be transformed is something a user can be told about at the point
they create or import a TSD. Warning is available; preventing is not warranted.

**Some services state their real ceiling and some state nothing.** NASA GIBS puts it
in the tile matrix set name (`GoogleMapsCompatible_Level12`) and IGN France does the
same (`PM_0_19`), so a capabilities document answers the depth question without a tile
being fetched. Spain's WMTS declares z0 to z20 outright, and LINZ documents z0 to z22.
At the other end, Esri World Imagery declares LODs 0 to 23 with `minScale` and
`maxScale` both zero, which states no ceiling at all, and NSW declares 0 to 23 with
`maxScale` at level 23. USGS is the useful middle case: it declares 0 to 23 but its
`maxScale` corresponds to level 16, which is the real answer. **Where an ArcGIS
service sets `maxScale` to level 23 or to zero, it is telling you nothing.**

**Most free public-mandate services publish no numeric rate limit, but not all.**
Nothing was found for NASA GIBS, USGS, IGN France or Japan GSI. **LINZ is the
exception and publishes one**: 1,000 tile requests per minute on standard access, and
uncapped on developer access. This corrects a claim made earlier in this survey's
working notes. Where an operator states no figure, any figure recorded against that
source is an assumption rather than a fact.

**Three separate Esri documents govern three separate things, and conflating them
produces wrong answers in both directions.**

1. **The general web site and service terms** grant the public the right to
   "download, view, copy, and print" a Service for internal or noncommercial external
   purposes. No named permission, no account. This is why the World Imagery endpoint
   appears unremarked in every basemap list, in QGIS recipes, in `leaflet-providers`
   and in editor-layer-index. The same terms separately prohibit systematically
   harvesting information contained within a Service.
2. **The ordinary World Imagery item** adds that the layer "is not intended to be used
   to export tiles for offline".
3. **World Imagery (for Export)** is a separate authenticated service, needing an
   organizational subscription or a free developer account, allowing 150,000 tiles per
   request, and scoping **the tiles it produces** to ArcGIS applications and ArcGIS
   Runtime SDK applications.

The third document's ArcGIS scoping applies to tiles obtained from the third service.
It does not attach to the public endpoint, and reading it as though it does overstates
the position considerably. What bears on a user fetching from the public endpoint is
documents 1 and 2: a clear grant to view and copy, a prohibition on systematic
harvesting, and a statement that offline export is not the layer's purpose.

**None of this constrains a tool.** Distributing a URL and a set of field values is
not distributing imagery and grants nobody any right to imagery. The terms bind
whoever operates the client. That is the whole reason `uses` records the user's
assertion rather than the application's opinion: what is shipped says what it is
shipped for, and what a user changes it to is their reading of their own obligations.

**Sources rot, and the undocumented ones rot silently.** Norway withdrew open access
and Maxar withdrew its OpenStreetMap grant, and in both cases the superseded recipes
are still the ones most easily found. An endpoint with no published documentation has
no deprecation notice either, so it fails as a 403, a redirect, or a placeholder image
rather than as an announcement.
