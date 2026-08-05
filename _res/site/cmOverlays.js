// ============================================================================
// cmOverlays.js -- the shipped overlay layers
// ============================================================================
// LABELS AND SEAMARKS ARE APPLICATION FURNITURE, NOT SOURCES.  A source is
// something the user chose, can edit, and may name in a region.  These are
// none of those: they are chrome, like the scale bar.  Shipping them as .tsd
// files would misrepresent what the Sources window is for and would leave
// somebody maintaining two files they never asked for.
//
// SO THEY ARE DECLARED HERE, AND THEY DO NOT GO THROUGH THE TILE PROXY.
// That is a deliberate exception to the rule that the browser never contacts
// a tile server, taken with its eyes open and recorded in
// docs/architecture.md along with what it costs.  What it buys is the
// absence of a whole mechanism -- no application-owned source ids, no proxy
// that has to resolve two kinds of source, and nothing new in front of the
// user.
//
// THE ENDPOINTS ARE A TABLE BECAUSE SERVICES ROT.  When one of these moves,
// the repair is one url on one line of one file, which an installed user can
// patch with a text editor -- rather than a hunt through the map code.
//
// NOTHING HERE IS EVER BUILT.  chartMaker builds imagery and an overlay is
// not imagery, so none of this reaches the cache, the coverage model or an
// exporter.  A screenshot of a chart with seamarks on it is a picture of the
// EDITOR, not of the card.

const CM_OVERLAYS = [
    {
        key:           'labels',
        label:         'labels',
        url:           'https://services.arcgisonline.com/ArcGIS/rest/services/' +
                       'Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
        attribution:   'Labels: Esri',
        maxNativeZoom: 19,

        // {z}/{y}/{x} -- ROW BEFORE COLUMN.  That is Esri's REST tile
        // convention and not slippy order.  Written the other way round
        // every tile still arrives, nothing reports a problem, and the
        // labels land in the wrong places.
    },
    {
        key:           'seamarks',
        label:         'seamarks',
        url:           'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png',
        attribution:   '&copy; OpenSeaMap contributors, CC BY-SA 2.0',
        minZoom:       9,
        maxNativeZoom: 18,

        // MOST TILES ARE EMPTY BY DESIGN, so a blank is the right answer
        // rather than a failure.  The no_data picture belongs to imagery,
        // where an absence is news; on an overlay it would cover the chart
        // in placeholders for tiles that are correctly empty.
        //
        // Nothing here has to arrange that.  These layers go straight at
        // somebody else's server rather than through the tile proxy, and
        // the proxy is what serves that picture - so an overlay could not
        // draw it even if it wanted to.
        //
        // FLOORED AT z9 rather than scaled down from it.  Seamark symbols
        // are drawn for a working scale, and stretched across an ocean view
        // they are illegible clutter over the only thing worth seeing.
    },
];


// DEFAULT OFF, AND REMEMBERED PER LAYER.  An overlay is something somebody
// reaches for, and a chart that has been written on without being asked is
// the wrong thing to open with.  Once asked for, it should still be there
// tomorrow, which is the same bargain the grid and autozoom switches make.

const OVERLAY_KEY_PREFIX = 'chartMaker.overlay.';

// Imagery is a plain tileLayer and takes Leaflet's default zIndex of 1, and
// it is REBUILT whenever the source changes -- so the overlays cannot simply
// be added after it and left to stacking order.  An explicit index above it
// survives every source swap.

const OVERLAY_Z_INDEX = 10;


function overlayRemembered(key) {
    try {
        return localStorage.getItem(OVERLAY_KEY_PREFIX + key) === 'on';
    } catch (e) {
        return false;   // private browsing, a policy -- not worth breaking over
    }
}

function overlayRemember(key, on) {
    try {
        localStorage.setItem(OVERLAY_KEY_PREFIX + key, on ? 'on' : 'off');
    } catch (e) {
        // As above.  The layer still works; it is simply not remembered.
    }
}


cmPaletteSeparator('sep_overlays');

for (const ov of CM_OVERLAYS) {
    const layer = L.tileLayer(ov.url, {
        attribution:   ov.attribution,
        maxZoom:       MAP_MAX_ZOOM,
        maxNativeZoom: ov.maxNativeZoom,
        minZoom:       ov.minZoom || 0,
        zIndex:        OVERLAY_Z_INDEX,
    });

    let on  = overlayRemembered(ov.key);
    let row = null;

    const setOverlay = want => {
        on = want;
        overlayRemember(ov.key, on);
        if (row) row.box.checked = on;
        if (on) layer.addTo(map); else map.removeLayer(layer);
    };

    row = cmPaletteRow(ov.key, ov.label, {
        checked:  on,
        onToggle: () => setOverlay(!on),
    });

    if (on) layer.addTo(map);
}
