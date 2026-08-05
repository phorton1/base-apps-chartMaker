# chartMaker - candidate tile services

Services that can be reached by a tile client, what each is worth to a mariner, and the
address to reach it at. This is the public middle of a three stage pipeline: a fact about a
service is found and written down privately, distilled here, and codified in the
application's shipped catalog. The **moniker** in the first column is what ties the three
together, so a claim made here can be checked at either end.

**Every service listed publishes a tile pyramid.** chartMaker reads one shape of source: a
remote XYZ tile service serving 256 pixel tiles in EPSG:3857. A service that renders an
image per request, or that publishes its tiles on a national grid, cannot be addressed by a
tile client at all, so it is not a candidate here whatever its licence or its imagery.

**This is not legal advice and not a ruling.** The terms columns summarise what was found at
each operator's own published terms, and the obligation to read them belongs to whoever uses
a source. Treat every row as a starting point for checking rather than as a current fact.

**Viewing is assumed permitted** wherever a credential or licence has been properly
obtained, so there is no display column. The column that varies is **Buildable**: may tiles
be systematically retrieved and cached offline, which is what constructing a chartset is.
Where a lookup was made and the answer could not be determined, the entry reads
`indeterminate` rather than guessing.

**Nothing here decides what is useful.** Where a source has a known registration error, or
where an operator states a fitness limit in its own terms, that is recorded as the fact it
is. What a user does with the information is theirs to judge: they may have a consumer that
compensates for an offset, or a purpose that is not navigation.

Two axes decide the practical value of everything below, and they are in tension: **depth
and geography**. Nothing found is free, deep and global at once. The free deep services are
national. The deep global services are commercial.

---

## How to read a row

**The moniker names the service, not one of its layers.** `linz` is the service and
`linz_aerial` is the entry the application ships from it. A provider publishing several
distinct services gets one moniker each, which is why there are five `esri_*` rows.

**As of** is one date for the whole service, not one per fact. Work happens a service at a
time, and the things recorded here - the endpoint, the terms, the licence, where a key comes
from - move on the scale of years. It is coarse to the month deliberately: a precise date on
a claim reads as a currency it has not got.

**Provenance** says how each row is known, because that is more useful than a verified flag:

| Provenance | Means |
| --- | --- |
| `fetched` | A tile was asked for at a real place and what came back was looked at. |
| `metadata` | The service's own capabilities document or `?f=json` was read. |
| `docs` | The operator's published documentation or terms pages were read. |
| `listed` | It appears in a third party service list and has not been checked here. |
| `recalled` | An endpoint that circulates widely, written down from memory. |

A row is usually several of these. `fetched` is the only one that survives a service moving,
and it is the reason the shipped entries are swept rather than trusted.

**Ships** names the entry in the application's catalog, where there is one. A service can be
worth documenting and not worth shipping, and most of them are.

---

## Open licence and public mandate

| Moniker | Service | Region | Buildable | Cost | Real depth | Value to a mariner |
| --- | --- | --- | --- | --- | --- | --- |
| `gibs` | NASA GIBS | global | yes, US Government work | free, no key | Blue Marble z8, Landsat WELD z12 | Backdrops. Far below chart depth, and complete everywhere, which is what makes them the sane thing to open on. |
| `usgs` | USGS Imagery Only | United States | yes, US Government work | free, no key | z16, from the service metadata | The best free option in US waters. Declares `format: MIXED`, so PNG can appear where JPEG is expected. |
| `ign_fr` | IGN France Geoplateforme | France and the overseas departments | yes, French open licence with attribution | free, no key | z19, from the tile matrix set `PM_0_19` | The deepest open imagery found anywhere, and the only open source at chart depth over Caribbean cruising ground. Says "nothing here" three ways over one build range - navy fill z10-12, a declared white fingerprint z13-16, honest 404s from z14. Its coastal footprint runs about one z15 tile offshore, so it closes over bays completely and leaves open coast marginal. |
| `ign_es` | Spain IGN PNOA | Spain | yes, CC BY 4.0 | free, no key | z20 declared; **z18 measured**, falling at z19 and marginal at z20 | 25 cm and 50 cm mosaics updated several times a year. Never refuses and sends no fixed no-data body, so nothing bounds it by absence. Its coastal footprint runs about one z15 tile offshore and fills beyond that with a dark blue backdrop rather than white, which is what makes its edge liveable on a chart. |
| `gsi` | Japan GSI seamlessphoto | Japan | yes, under the GSI tile terms | free, no key | z18, from the layer specification | Excellent in Japan. Returns 404 outside the country, so an absence is unambiguous. |
| `nsw` | NSW Spatial Services (SIX) | New South Wales | yes, CC BY 4.0 with an authorship term | free, no key | declares LODs 0 to 23 with `maxScale` also at 23, so it states no real ceiling; 10 cm over towns, 50 cm regional | Excellent on that coast. `format: MIXED`. Newer coverage supersedes older below 1:150,000, so depth varies by place. |
| `qld` | Queensland Government imagery | Queensland | licence varies per image between CC BY, CC BY-SA and public domain | free, no key | 21 levels with `maxScale` 1:564, which is z20 | Excellent on that coast. The whole-of-state satellite mosaic derives from Planet and is CC BY-SA, which imposes share-alike on anything built from it. |
| `linz` | LINZ Basemaps | New Zealand | yes, CC BY 4.0 | free key, no account for the standard tier | the whole-country `aerial` mosaic holds real detail to about z18 and upsamples above it; the individual survey layers go to 7.5 cm, which is real to about z21 | Excellent New Zealand coverage including the Chathams and the offshore islands. It publishes 138 layers, each named for its place, year and resolution - `auckland-2024-0.075m` - which is the only statement of real depth the service makes. `aerial` is those layers blended, so **name a layer to pin an acquisition** rather than to gain detail: the mosaic changes when LINZ re-flies and a card built from it is not reproducible. |
| `de_africa` | Digital Earth Africa | Africa | yes | free | Sentinel derived at 10 m, so real detail ends near z14 | Continental context, and the only free option covering that coastline at all. Slow: it renders on demand. |
| `eox` | EOX Sentinel-2 cloudless | global | 2016 mosaic CC BY 4.0; 2018 onward CC BY-NC-SA 4.0 | free, fair use; production use is paid | z13 | Shallow, and the later mosaics carry a licence that restricts reuse. |
| `oam` | OpenAerialMap | global | yes, CC BY 4.0 with Open Imagery Network attribution | free | varies per contributed image, occasionally very high | Opportunistic. Coverage is wherever somebody flew and uploaded, so it is a supplement and never a base source. |
| `coral` | Allen Coral Atlas | global reefs | yes, CC BY 4.0 | free | benthic under about 10 m of water, geomorphic under 15 m | A classification product rather than imagery, and genuinely relevant to reef navigation. |
| `gebco` | GEBCO | global | yes, public domain, attribution required | free | coarse | Bathymetric context. **GEBCO's terms state the grid should not be used for navigation or any purpose involving safety at sea**, and that users must not imply IHO or IOC endorsement. |
| `emodnet` | EMODnet bathymetry | European seas | yes, attribution | free | coarse | Bathymetric context for European waters. |
| `openseamap` | OpenSeaMap seamarks | global | yes, ODbL, which carries share-alike obligations | free | transparent overlay | Seamark overlay. Most tiles are empty. |
| `noaa` | NOAA Chart Display Service | US waters | yes, US Government work | free | chart rendering rather than imagery | NOAA ENC drawn with paper-chart symbology. **Not reachable by a tile client** - see below. Distributed as MBTiles for offline use, which is the route that works. |
| `pdok` | Netherlands PDOK luchtfoto | Netherlands | CC BY, commercial use permitted | free | not established | WMS only, so not addressable. Most PDOK data is CC0; the aerial imagery specifically requires attribution. |
| `dgt` | Portugal DGT orthophotos | Portugal | CC BY 4.0 | free | 10 cm over coastal zones | WMS only, so not addressable. |
| `minambiente` | Italy, Ministero dell'Ambiente | Italy | **no reuse grant** - the national geoportal licenses CC BY-SA 3.0 IT and expressly excludes the orthophotos | free to view | not established | WMS only. Some regional portals publish the same imagery under IODL 2.0. |
| `kartverket` | Norway, Norge i bilder | Norway | no; access is reserved to Norge digitalt parties | token required | published on UTM grids | Not reachable. Open access was withdrawn, and older recipes pointing at the previous endpoints still circulate. |
| `swisstopo` | Switzerland swisstopo | Switzerland | open | free | not established | Landlocked. Listed for completeness. |
| `bkg` | Germany BKG TopPlusOpen | Germany | open | free | not applicable | A map rather than imagery. |
| `cdngi` | South Africa CD:NGI | South Africa | the imagery is open | free, distributed on physical media | 25 cm source imagery | No official tile service exists; only a community mirror. Open data and a usable tile service are separate facts, and a tile client needs the second. |
| `vworld` | Korea VWorld | South Korea | keyed, bounded to the country | free key | not established | Not reached through a documented XYZ template. |
| `bhuvan` | India Bhuvan (ISRO) | India | keyed, bounded to the country | free key | not established | As above. |
| `nlsc` | Taiwan NLSC | Taiwan | keyed, bounded to the country | free key | not established | As above. |
| `tianditu` | China Tianditu | China | `indeterminate`; marked noncommercial with registration required for commercial use | free key, but registration needs a mainland China (+86) mobile number | not established | **The imagery is aligned to GCJ-02, not WGS 84**, so it sits 300 to 500 m from the coordinates it is served at, varying with position. The tile grid itself is correct EPSG:3857, so nothing structural is wrong and no check detects it. |
| `ga_au` | Geoscience Australia | Australia | open | free | not applicable | Topographic rather than imagery. |
| `geogratis` | Canada GeoGratis CBMT | Canada | open | free | not applicable | Topographic or thematic rather than orthoimagery. |
| `ibge` | Brazil IBGE | Brazil | open | free | not applicable | As above. |
| `inpe` | Brazil INPE | Brazil | open | free | not applicable | As above. |
| `ign_ar` | Argentina IGN | Argentina | open | free | not applicable | As above. |

### Where to reach them

| Moniker | As of | Provenance | Tile url | Ships |
| --- | --- | --- | --- | --- |
| `gibs` | August 2026 | fetched, metadata, docs | `https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/<LAYER>/default/<TIME>/GoogleMapsCompatible_Level<N>/{z}/{y}/{x}.jpeg` | `gibs_bluemarble`, `gibs_weld_annual` |
| `usgs` | August 2026 | fetched, metadata, docs | `https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}` | `usgs_imagery_only` |
| `ign_fr` | August 2026 | fetched, metadata, docs | `https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&STYLE=normal&TILEMATRIXSET=PM&FORMAT=image/jpeg&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}` | `ign_fr_ortho` |
| `ign_es` | August 2026 | fetched, metadata, docs | `https://www.ign.es/wmts/pnoa-ma?service=WMTS&request=GetTile&version=1.0.0&layer=OI.OrthoimageCoverage&style=default&tilematrixset=GoogleMapsCompatible&format=image/jpeg&TileMatrix={z}&TileRow={y}&TileCol={x}` | `ign_es_pnoa` |
| `gsi` | August 2026 | fetched, docs | `https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg` | `gsi_seamlessphoto` |
| `nsw` | August 2026 | fetched, metadata, docs | `https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_Imagery/MapServer/tile/{z}/{y}/{x}` | `nsw_imagery` |
| `qld` | August 2026 | fetched, metadata, docs | `https://spatial-img.information.qld.gov.au/arcgis/rest/services/Basemaps/LatestStateProgram_AllUsers/ImageServer/tile/{z}/{y}/{x}` | `qld_imagery` |
| `linz` | August 2026 | fetched, metadata, docs | `https://basemaps.linz.govt.nz/v1/tiles/{layer}/WebMercatorQuad/{z}/{x}/{y}.jpeg?api={linz_api_key}` and `https://basemaps.linz.govt.nz/v1/tiles/WMTSCapabilities.xml?api={linz_api_key}` | `linz`, expanded |
| `de_africa` | August 2026 | fetched, metadata | `https://ows.digitalearth.africa/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=gm_s2_annual&style=simple_rgb&tilematrixset=WholeWorld_WebMercator&format=image/png&TileMatrix={z}&TileRow={y}&TileCol={x}` | `de_africa` |
| `eox` | August 2026 | fetched, docs | `https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/GoogleMapsCompatible/{z}/{y}/{x}.jpg` | `eox_s2cloudless` |
| `oam` | August 2026 | docs | per image, from the OpenAerialMap API | - |
| `coral` | August 2026 | fetched, metadata, docs | `https://allencoralatlas.org/geoserver/gwc/service/tms/1.0.0/coral-atlas%3Abenthic_data_verbose@EPSG%3A900913@png/{z}/{x}/{-y}.png` | `coral_atlas` |
| `gebco` | August 2026 | fetched, docs | `https://tiles.arcgis.com/tiles/C8EMgrsFcRFL6LrL/arcgis/rest/services/GEBCO_basemap_NCEI/MapServer/tile/{z}/{y}/{x}` | `gebco` |
| `emodnet` | August 2026 | fetched, docs | `https://tiles.emodnet-bathymetry.eu/2020/baselayer/inspire_quad/{z}/{x}/{y}.png` | `emodnet_bathymetry` |
| `openseamap` | August 2026 | fetched, docs | `https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png` | `openseamap_seamarks` |
| `noaa` | August 2026 | fetched, metadata, docs | none - WMS only, see below | - |
| `pdok` | August 2026 | listed, docs | `https://service.pdok.nl/hwh/luchtfotorgb/wms/v1_0?` WMS | - |
| `dgt` | August 2026 | listed, docs | `https://cartografia.dgterritorio.gov.pt/ortos2018/service?` WMS | - |
| `minambiente` | August 2026 | listed, docs | `https://wms.pcn.minambiente.it/ogc?map=/ms_ogc/WMS_v1.3/raster/ortofoto_colore_12.map` WMS | - |
| `kartverket` | August 2026 | listed, docs | `https://tilecache.norgeibilder.no/wmts/utm32_euref89` | - |
| `swisstopo` | August 2026 | listed | `https://wms.geo.admin.ch/?` WMS | - |
| `bkg` | August 2026 | listed | `https://sgx.geodatenzentrum.de/wmts_topplus_open/1.0.0/WMTSCapabilities.xml` | - |
| `cdngi` | August 2026 | docs | `http://aerial.openstreetmap.org.za/wms-ngi-aerial` community mirror, WMS | - |
| `vworld`, `bhuvan`, `nlsc` | August 2026 | listed | not resolved to an XYZ template | - |
| `tianditu` | August 2026 | docs | `http://t{0-7}.tianditu.gov.cn/img_w/wmts?...&tk={key}` | - |
| `ga_au`, `geogratis`, `ibge`, `inpe`, `ign_ar` | August 2026 | listed | topographic or thematic, not pursued | - |

**Terms and licence pages**, where the licence column above summarises one:
[GIBS](https://www.earthdata.nasa.gov/engage/open-data-services-software/data-information-policy) --
[USGS](https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits) --
[IGN France](https://geoservices.ign.fr/cgu-licences) --
[Spain IGN](https://www.ign.es/) --
[Japan GSI](https://maps.gsi.go.jp/development/siyou.html) --
[NSW](https://www.spatial.nsw.gov.au/copyright) --
[Queensland](https://www.qld.gov.au/legal/copyright) --
[LINZ](https://www.linz.govt.nz/linz-copyright) --
[EOX](https://s2maps.eu/) --
[Allen Coral Atlas](https://allencoralatlas.org/terms/) --
[GEBCO](https://www.gebco.net/data-products-gridded-bathymetry-data/gebco-terms-use) --
[EMODnet](https://emodnet.ec.europa.eu/en/use-emodnet-data) --
[OpenSeaMap](https://www.openseamap.org/index.php?id=impressum)

---

## Commercial

| Moniker | Service | Region | Buildable | Cost | Real depth | Value to a mariner |
| --- | --- | --- | --- | --- | --- | --- |
| `esri_world` | Esri World Imagery | global | **no.** The item's own `licenseInfo` states the layer is not intended to be used to export tiles for offline, and Esri's general terms prohibit systematically harvesting a Service. **Viewing is a different matter**: the general terms grant anyone the right to download, view, copy and print for internal or noncommercial external purposes | Esri Master License Agreement; free noncommercial use at Esri's determination | declares LODs 0 to 23 with `minScale` and `maxScale` both 0, so it states no ceiling and answers anywhere by upsampling; real cached detail measured z17-18 over Panama, z19 over Miami | The deep global source. JPEG at 90 percent quality, from Vantor products at 15 cm to 1.2 m plus community aerial down to 3 cm. |
| `esri_clarity` | Esri World Imagery (Clarity) | global | **no**, same terms | Esri MLA | declares LODs 0 to 23, `maxScale` at 23, so no stated ceiling | An alternative view onto the Living Atlas archive, often clearer than the default at the cost of being older. In mature support since January 2022, scheduled to retire March 2028. |
| `esri_wayback` | Esri World Imagery Wayback | global | **no**, same terms | Esri MLA | as World Imagery, per archived release | Over 150 archived releases back to February 2014, each pinned permanently. The available answer to cloud, sun glint, turbidity and tide state, none of which depth fixes. |
| `esri_export` | Esri World Imagery (for Export) | global | export permitted up to 150,000 tiles per request, with **those** tiles scoped to ArcGIS applications and ArcGIS Runtime SDK applications. That scoping is a term of this product and does not govern the public endpoint | Esri MLA, plus an ArcGIS Online organizational subscription or a free developer account | as World Imagery | **Unreachable from a TSD regardless of licence**: authentication is a credential handshake, and a declarative file cannot make one request in order to construct another. |
| `esri_ocean` | Esri World Ocean Base | global | **no**, same terms | Esri MLA | coarse | Bathymetric basemap. |
| `maptiler` | MapTiler | global, deep over USA, Europe and Japan | the Cloud terms forbid storing or redistributing tiles from a cache; the Engine and on-prem products permit generated tiles to form part of the customer's own products | free tier with an account; Cloud from about USD 29 per month; on-prem quoted | 8 cm over USA, Europe and Japan; 10 m cloudless elsewhere | The only commercial source found that offers a licensed path to offline chart building rather than only a prohibition. |
| `mapbox` | Mapbox | global | terms restrict caching | keyed, billed per request | deep | Keyed and billed. |
| `google` | Google | global | **no.** The published Google Maps and Map Tiles policies forbid pre-fetching, caching for offline use and bulk downloading, which is a direct description of building a chartset | the undocumented `/vt` path is free and needs no key; the documented Map Tiles API is keyed and billed | answers to about z21, never 404s and never sends a fixed no-data image, so it magnifies past real detail indefinitely and **no absence can be detected at all** | The deepest and most widely available global imagery. `lyrs` selects the layer: `s` satellite, `y` hybrid, `m` map, `p` terrain. |
| `bing` | Bing / Microsoft | global | terms restrict caching | keyed | deep | **Cannot be expressed as a chartMaker source**: the documented route requires a metadata call that returns the real URL template and valid subdomains, and a TSD has no way to make a request in order to build a request. |
| `copernicus` | Copernicus Data Space / Sentinel Hub | global | yes for the data under EU open data policy; the service applies its own quota | free tier; registration is mandatory and asks first name, last name, country and user type, retained six to ten years | Sentinel-2 at 10 m, so real detail ends near z14 | Too shallow for a chart. Notable for putting its credential in the URL path rather than a query parameter. |
| `maxar` | Maxar | global | contract dependent | quotation and subscription; no free tier | 30 cm global for Vivid | The paid answer to tropical depth. Its OpenStreetMap grant was withdrawn around 2021, though recipes pointing at the old endpoints remain published. |
| `planet` | Planet | global | contract dependent | subscription | high | Basemaps under contract. Supplies the Queensland satellite mosaic and the Allen Coral Atlas source imagery. |
| `airbus` | Airbus | global | contract dependent | quotation | 30 cm to 1.5 m | Pleiades and SPOT under contract. |
| `yandex` | Yandex satellite | global | - | free | - | **Published in EPSG:3395 elliptical mercator.** A different grid, so the tiles cannot align with anything chartMaker produces, and `crs` refuses it. |
| `apple` | Apple | global | - | - | - | The tile endpoint requires a session token from a MapKit handshake and is not reachable by a plain tile client. |

### Where to reach them

| Moniker | As of | Provenance | Tile url | Ships |
| --- | --- | --- | --- | --- |
| `esri_world` | August 2026 | fetched, metadata, docs | `https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}` | `esri_world_imagery` |
| `esri_clarity` | August 2026 | fetched, metadata, docs | `https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}` | `esri_world_imagery_clarity` |
| `esri_wayback` | August 2026 | metadata, docs | from `https://wayback.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/WMTS/1.0.0/WMTSCapabilities.xml`, one url per release | `esri_wayback`, expanded |
| `esri_export` | August 2026 | docs | `https://tiledbasemaps.arcgis.com/arcgis/rest/services/World_Imagery/MapServer` - authenticated | - |
| `esri_ocean` | August 2026 | listed | `https://services.arcgisonline.com/ArcGIS/rest/services/Ocean/World_Ocean_Base/MapServer/tile/{z}/{y}/{x}` | - |
| `maptiler` | August 2026 | docs | `https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key={key}` | - |
| `mapbox` | August 2026 | docs | `https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.jpg?access_token={token}` | - |
| `google` | August 2026 | recalled, docs | `https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}` undocumented; the Map Tiles API is a separate keyed product | installed as user data, deliberately not catalogued |
| `bing` | August 2026 | docs | requires a metadata call first | - |
| `copernicus` | August 2026 | docs | `https://services.sentinel-hub.com/ogc/wmts/{instance_id}` - credential in the path | - |
| `maxar`, `planet`, `airbus` | August 2026 | docs | under contract | - |
| `yandex` | August 2026 | recalled | EPSG:3395, refused by `crs` | - |
| `apple` | August 2026 | docs | session token, not reachable | - |

**Terms pages:**
[Esri service terms](https://www.esri.com/en-us/legal/terms/web-site-service) --
[MapTiler](https://www.maptiler.com/terms/) --
[Mapbox](https://www.mapbox.com/legal/tos) --
[Google Maps Platform](https://cloud.google.com/maps-platform/terms) --
[Bing Maps](https://www.microsoft.com/en-us/maps/product) --
[Copernicus Data Space](https://dataspace.copernicus.eu/terms-and-conditions)

---

## Display-only basemaps

Listed because `uses: display` is a real category and a context layer under a preview has to
come from somewhere. None of these is imagery, and none of them ships.

| Moniker | Service | Endpoint | Note |
| --- | --- | --- | --- |
| `osm` | OpenStreetMap standard | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` | Fair use for viewing; **bulk downloading is prohibited** by the tile usage policy. |
| `osm_hot` | OSM Humanitarian | `https://tile-a.openstreetmap.fr/hot/{z}/{x}/{y}.png` | Fair use. |
| `opentopo` | OpenTopoMap | `https://a.tile.opentopomap.org/{z}/{x}/{y}.png` | Fair use. |
| `carto` | CARTO Positron | `https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png` | Free tier, attribution. |

---

## What asking the endpoints taught

Everything above except the `fetched` rows is what operators' documents say. The shipped
entries are also asked directly, by `scripts/sweep_catalog.pl`, which fetches a tile per
entry at that entry's own canonical point. The document is not what makes a claim true; the
sweep is.

**Four addresses in the shipped catalog had never been fetched, and all four were wrong.**
Not one of the four failures was a fact about the service, and not one is visible in any
licence document.

| Service | What was recorded | What is true |
| --- | --- | --- |
| `qld` | "a token is required", from a `499 Token Required` at every level | The host was wrong. `spatial-gis` is a live ArcGIS server that does not publish this service; `spatial-img` does, and answers with imagery and no key. |
| `noaa` | a WMTS tile template | No such path exists. The Maritime Chart Service publishes MapServer and WMSServer and nothing else, and the old `tileservice.charts.noaa.gov` resolves but no longer accepts connections. |
| `coral` | `allencoralatlas.org/tiles/benthic/{z}/{x}/{y}.png` | Invented. The real path is a GeoWebCache TMS, whose rows count from the south. |
| `de_africa` | a RESTful WMTS path with `GoogleMapsCompatible` | Invented. It is a KVP WMTS whose matrix set is `WholeWorld_WebMercator` and whose default style is `simple_rgb`. |

**`499 Token Required` is not a statement about credentials.** It is what an ArcGIS server
says for a service that is not there, or not visible to you, on a secured directory. It is
that server's 404. Reading it as "get a token" is how a catalog entry acquired a credential
slot it never needed, and how a wrong hostname acquired a confident sentence.

**A 200 is not a yes.** Beside that refusal, services that genuinely work answer with
something that is not imagery: OpenSeaMap sends a 334 byte transparent PNG almost
everywhere, and NSW answers z0 with a white world carrying one blue speck of New South
Wales.

**A repeated small body is not a sentinel either.** Spain IGN was recorded here as sending
a 929 byte blank outside Spain. Probed in three unrelated places it sends several different
small bodies at several different lengths, because what it serves past its own coverage is
an upsampled global backdrop that averages down to a flat colour - blue over ocean, green
over forest. A sentinel is byte identical across ground that has nothing in common; a
backdrop only repeats within one patch. Two distant samples separate them.

**The row-order trap is real and it is silent.** Asked with a northward row, Allen Coral
Atlas answers HTTP 200 with a 1,784 byte empty tile rather than an error. Every tile arrives,
nothing reports a problem, and the map is scrambled. That is what `{-y}` is for.

**Where a service holds nothing it often says so in bytes rather than in a status.** Allen
Coral Atlas sends one fixed empty PNG, byte identical at 1,784 bytes across three levels and
three places, which is now declared as an `absent_fingerprint`. Esri sends a fixed 2,521 byte
grey image past its real depth, which is declared as another. IGN France sends a 1,651 byte
flat white, confirmed identical offshore of Guadeloupe and offshore of Corsica, which is
declared as a third.

**One service can say it several ways at once, and the ways are banded by zoom.** IGN France
over one region's build range returns a flat navy sea fill at z10-z12, that white at
z13-z16, and honest 404s from about z14, with the proportions shifting by place. So the
absent column alone never bounds such a service, and a fingerprint found at one level says
nothing about the level above it.

**A fingerprint is not the whole answer where coverage ends on a metric grid.** IGN France's
footprint is a coastal buffer about one z15 tile wide whose edge follows a projected delivery
grid - Lambert-93 in metropolitan France, UTM in the overseas departments - so it can never
align with a tile boundary. Tiles along that edge are part imagery and part fill, which is
unique bytes and beyond the reach of any fingerprint. The consolation is geometric: a
distance-from-land buffer closes over CONCAVE water completely, so bays, calas and inlets are
solid while open coast is marginal - and concave water is where a photograph beats a chart.

**Region prose does not say where the tiles are.** Japan GSI serves real imagery over Bocas
del Toro at z3 and z8 and nothing at z12; IGN France serves Bocas del Toro at z12, the same
ground as Esri World Imagery pixel for pixel; USGS serves Panama down to z8; and LINZ, a New
Zealand service, answers over Bocas del Toro as well. Four global low-zoom backdrops under
national labels, none of it discoverable from a terms page - and only Japan GSI, which 404s
outside Japan, gives an unambiguous absence anywhere.

**A column is not monotonic.** Japan GSI over Tokyo answers z2 to z18 unbroken and refuses z0
and z1, which is its cache floor rather than a gap. Esri declares z23 and, at Singapore,
returns the same 2,521 byte JPEG at z20 through z23, so its real ceiling there is z19.

**A global commercial mosaic may BE a national open one.** Esri World Imagery over the
Chatham Islands is pixel for pixel LINZ's imagery at z19, because Esri's mosaic ingests
contributed government aerial and LINZ contributes. IGN France and Esri agree the same way
over Bocas del Toro. The practical consequence is a licence one: Esri ships display only,
the national services ship open licences that permit building. **Where the deep global
mosaic looks good, ask who flew it** - the buildable original may be sitting right behind it.

**A blended mosaic is not reproducible and a named layer is.** LINZ's `aerial` is its
individual surveys stitched together, best pass per place - identical to the survey layer
wherever the mosaic chose it - and it changes when the operator re-flies. Two cards built a
year apart from one region are therefore not the same card, and neither one records which
pass it got. Naming the survey pins it. That is a reason to prefer a named layer for a
BUILD which does not apply to browsing at all.

**A service's own metadata can declare nothing at all about depth.** LINZ publishes 25
levels to z24 with no per-layer limits and a whole-world bounding box, so every one of its
138 layers reads as z24 to anything that trusts the document. What it does instead is name
the resolution in the layer identifier - `auckland-2024-0.075m` is 7.5 cm - which is a
better answer than the metadata and is available to a person rather than to a parser.

**A keyed service's capabilities document is keyed too**, and hands back templates with the
live key baked into them. LINZ does exactly that, which is why reading one and writing
files from it has to take the key back out.

**Some services are slow rather than absent, and the difference is invisible to a status
code.** Digital Earth Africa and Allen Coral Atlas both render on demand: a seeded level
answers in under a second and an unseeded one does not return inside any timeout worth
setting. Allen Coral Atlas is floored at z8 in the catalog for that reason.

---

## Commentary

**No open source reaches chart depth over Central or South America.** The only entry
covering Caribbean cruising ground at depth is IGN France, over the French overseas
departments, and there is nothing else. No national imagery tile service was found for any
other Caribbean or Central American country, and the South American national services found
are topographic or thematic rather than orthoimagery. For that ground a commercial global
mosaic is the only option that reaches useful depth.

**Where a national service exists, it usually beats the global commercial mosaics.** IGN
France at z19, Spain at z20, Queensland at z20, Japan GSI at z18, LINZ at 5 cm and NSW at
10 cm are all deeper than a 30 cm global product, all free, and all carry an open licence
rather than a negotiation. The catch is that each stops at its own border.

**Depth is not the only axis of imagery quality over water.** Cloud, sun glint, turbidity and
tide state vary between passes, and a current mosaic is whichever pass the operator selected
rather than the clearest one. Esri World Imagery Wayback is the only service found that makes
an alternative pass addressable, by publishing every archived release separately.

**A national service is only listed here if it publishes a tile pyramid.** Several European
countries publish excellent orthophotography that no tile client can address, which is why
`pdok`, `dgt` and `minambiente` are documented and do not ship. Open data and a usable tile
service are separate facts.

**Some services state their real ceiling and some state nothing.** NASA GIBS puts it in the
tile matrix set name (`GoogleMapsCompatible_Level12`) and IGN France does the same
(`PM_0_19`), so a capabilities document answers the depth question without a tile being
fetched. Spain declares z0 to z20 outright and LINZ documents z0 to z22. At the other end,
Esri World Imagery declares LODs 0 to 23 with `minScale` and `maxScale` both zero, which
states no ceiling at all, and NSW declares 0 to 23 with `maxScale` at 23. USGS is the useful
middle case: it declares 0 to 23 but its `maxScale` corresponds to level 16, which is the
real answer. **Where an ArcGIS service sets `maxScale` to level 23 or to zero, it is telling
you nothing.**

**Most free public-mandate services publish no numeric rate limit, but not all.** Nothing was
found for NASA GIBS, USGS, IGN France or Japan GSI. **LINZ is the exception**: 1,000 tile
requests per minute on standard access, uncapped on developer access. Where an operator
states no figure, any figure recorded against that source is an assumption rather than a
fact.

**Three separate Esri documents govern three separate things, and conflating them produces
wrong answers in both directions.**

1. **The general web site and service terms** grant the public the right to "download, view,
   copy, and print" a Service for internal or noncommercial external purposes. No named
   permission, no account. This is why the World Imagery endpoint appears unremarked in every
   basemap list, in QGIS recipes, in `leaflet-providers` and in editor-layer-index. The same
   terms separately prohibit systematically harvesting information contained within a Service.
2. **The ordinary World Imagery item** adds that the layer "is not intended to be used to
   export tiles for offline".
3. **World Imagery (for Export)** is a separate authenticated service, needing an
   organizational subscription or a free developer account, allowing 150,000 tiles per
   request, and scoping **the tiles it produces** to ArcGIS applications and ArcGIS Runtime
   SDK applications.

The third document's ArcGIS scoping applies to tiles obtained from the third service. It does
not attach to the public endpoint, and reading it as though it does overstates the position
considerably. What bears on a user fetching from the public endpoint is documents 1 and 2.

**None of this constrains a tool.** Distributing a URL and a set of field values is not
distributing imagery and grants nobody any right to imagery. The terms bind whoever operates
the client. That is the whole reason `uses` records the user's assertion rather than the
application's opinion.

**Two entries carry statements a licence field cannot hold, and they are different in kind.**
GEBCO's terms say the grid must not be used for navigation or any purpose involving safety at
sea, which is an operator stating a limit about its own product. Tianditu's imagery is
displaced several hundred metres by regulation, which the operator does not state and no
structural check reveals. Neither is a reason to stop anyone using either one. What the two
cases establish is that **misregistration is detectable in advance where it is known**, so a
user can be told at the point they create the source. Warning is available; preventing is not
warranted.

**Sources rot, and the undocumented ones rot silently.** Norway withdrew open access, Maxar
withdrew its OpenStreetMap grant, and NOAA shut down the RNC tile service; in all three cases
the superseded recipes are still the ones most easily found. An endpoint with no published
documentation has no deprecation notice either, so it fails as a 403, a redirect, or a
placeholder image rather than as an announcement.

**And a service list is not a measurement.** Every wrong address in this repository arrived
by being written down from something that looked authoritative. The sweep is the only part of
this document that cannot be wrong in that particular way.
