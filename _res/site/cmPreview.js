// cmPreview.js -- what the chartset will actually look like.
//
// The editor and the preview are ONE component in two modes: the same map,
// the same proxy, the same regions. Preview adds a clip and a cap, and it
// answers the one question the footprint cannot -- not "which tiles are in
// the card" but "what will the plotter DRAW", which at any zoom past a
// region's depth is a different picture entirely.
//
// THE APPLICATION DECIDES COVERAGE, NOT THIS FILE.  /preview answers, per
// tile, which tile the chartset would draw there: this one when the card
// carries it, its deepest carried ANCESTOR when it does not, and nothing at
// all outside coverage. If the applet worked that out for itself, preview
// would be an illustration of the build rather than a test of it, and the
// two would disagree exactly at the seams -- where disagreement is most
// expensive and least visible.
//
// What this file does own is the RENDERING of that answer, and the ancestor
// case is why it is a hand-written GridLayer rather than an L.tileLayer.
// Magnifying a parent tile means showing one quadrant of it, scaled: which
// quadrant depends on how far past the built depth you are, and Leaflet's
// own overzoom (maxNativeZoom) cannot express it because the depth is not
// one number -- it varies from region to region across the same map.
//
// THE GRID IS 256, always. chartMaker works with Web Mercator sources at
// 256 pixels and says so; the coverage model counts tiles on that grid, so
// a preview drawn on any other would be counting different things.

const CM_TILE_PX = 256;

// Orange for a hole, and deliberately not a bright one: it has to be
// unmistakable against dark water without reading as a warning light, since
// on a new region there may be a great many of them at once. The pale
// outline is what makes it legible over land as well -- fill alone
// disappears into brown coastline at low zoom.

const CM_ABSENT_FILL   = 'rgba(198, 118, 38, 0.62)';
const CM_ABSENT_STROKE = 'rgba(226, 226, 226, 0.85)';

let previewOn    = false;
let previewLayer = null;
let previewRow   = null;

// Every classification learned so far, keyed 'z/x/y'. Kept across viewport
// queries because Leaflet asks for tiles beyond the edge of the view and
// then keeps them while you pan back and forth; throwing the answer away
// with each query would make a pan re-ask for tiles it already knew about.
// Cleared whole when the model changes, which is the only thing that can
// make an entry wrong.

const previewCache = new Map();
let   previewKey   = null;
let   previewWait  = null;

function previewQuery() {
    // Padded, because Leaflet loads a margin of tiles outside the view and
    // an unclassified tile is indistinguishable from one outside coverage.
    // Asking for a slightly bigger rectangle is far cheaper than being
    // wrong at the edge of the screen.
    const b = map.getBounds().pad(0.5);
    return '/preview?z=' + Math.round(map.getZoom()) +
        '&w=' + b.getWest()  + '&s=' + b.getSouth() +
        '&e=' + b.getEast()  + '&n=' + b.getNorth();
}

function ensurePreviewData() {
    const q   = previewQuery();
    const key = q + '|' + cmModelKey();
    if (key === previewKey) return previewWait || Promise.resolve();
    previewKey = key;

    previewWait = fetchJson(q, STATE_TIMEOUT_MS).then(data => {
        const z = data.zoom;
        for (const k in data.tiles) {
            const [x, y] = k.split('_');
            previewCache.set(z + '/' + x + '/' + y, data.tiles[k]);
        }
        // A tile the answer did NOT mention is outside coverage, and that
        // is a real answer rather than a missing one -- recorded as null so
        // it is not asked about again on every pan.
        cmMarkOutside(data, z);
    }).catch(e => {
        console.warn('chartMaker: /preview failed', e);
        previewKey = null;          // ask again rather than render a lie
    });

    return previewWait;
}

function cmMarkOutside(data, z) {
    // Only the tiles Leaflet is actually going to ask for matter, and it
    // asks for whole tiles across the padded view -- so the rectangle is
    // recomputed here from the same bounds the query used.
    const b = map.getBounds().pad(0.5);
    const n = 1 << z;
    const lo = cmLonLatToTile(b.getWest(), b.getNorth(), n);
    const hi = cmLonLatToTile(b.getEast(), b.getSouth(), n);
    for (let x = lo.x; x <= hi.x; x++) {
        for (let y = lo.y; y <= hi.y; y++) {
            const key = z + '/' + x + '/' + y;
            if (!previewCache.has(key)) previewCache.set(key, null);
        }
    }
}

function cmLonLatToTile(lon, lat, n) {
    const rad = lat * Math.PI / 180;
    let x = Math.floor((lon + 180) / 360 * n);
    let y = Math.floor((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) /
                        Math.PI) / 2 * n);
    x = Math.max(0, Math.min(n - 1, x));
    y = Math.max(0, Math.min(n - 1, y));
    return { x: x, y: y };
}


// ============================================================================
// The layer
// ============================================================================

const CmPreviewLayer = L.GridLayer.extend({

    createTile: function (coords, done) {
        const tile = document.createElement('div');
        tile.className = 'cm-prev-tile';

        // ASYNC ON PURPOSE.  Leaflet creates tiles the moment it needs
        // them, which is routinely before the viewport's classification has
        // come back. Returning the element now and filling it in when the
        // answer arrives is what keeps a pan smooth instead of stalling the
        // whole grid on one request.

        ensurePreviewData().then(() => {
            const src = previewCache.get(
                coords.z + '/' + coords.x + '/' + coords.y);

            // Null means the card does not hold this tile at this zoom;
            // undefined means the answer never covered it, which happens
            // only at the very edge of a fast pan. Both are left blank, and
            // the greyed base map shows through -- which for the first is
            // the whole point and for the second is the honest answer for a
            // tile nobody has classified.

            if (!src) {
                done(null, tile);
                return;
            }
            this._paint(tile, src, coords, done);
        }).catch(e => done(e, tile));

        return tile;
    },

    _paint: function (tile, src, coords, done) {
        // The card's own tile at this very zoom, drawn exactly as the card
        // will hold it. There is no other case: a tile the card does not
        // carry at this level is not drawn at all, and the greyed base map
        // shows through instead.

        const url = '/tile/' + src + '/' +
                    coords.z + '/' + coords.x + '/' + coords.y;
        const img = new Image();

        img.onload = () => {
            tile.style.backgroundImage = 'url(' + url + ')';
            tile.style.backgroundSize  = CM_TILE_PX + 'px ' + CM_TILE_PX + 'px';
            done(null, tile);
        };

        // A TILE THE SOURCE DOES NOT HAVE IS A HOLE IN THE CARD, and the
        // whole point of preview is that a hole reads AS a hole. The proxy
        // answers an absence with a failure rather than an image, so this
        // is the classification arriving through the image element.

        img.onerror = () => {
            tile.classList.add('cm-prev-absent');
            done(null, tile);
        };

        img.src = url;
    },
});


// ============================================================================
// The palette row
// ============================================================================
// PREVIEW IS A MODE, not an overlay, so turning it on changes what the
// whole map means: the imagery under it stops being the thing you are
// looking at and becomes context. It is dimmed to say so -- 'colour means
// it is in the card' is a rule learned once and never misread, and a user
// who sees bright imagery and assumes it is in their chartset is preview
// failing at its only job.

// THE OUTLINES COME WITH IT.  Filled tiles alone do not say where a tile
// ends, and the edge of the built area is exactly what preview is for -- so
// turning preview on turns the footprint on and pins it to the map's zoom.
// Whatever the footprint was doing beforehand is put back afterwards, so
// this borrows the control rather than taking it over.

let footprintWasOn = false;

function togglePreview() {
    previewOn = !previewOn;
    previewRow.box.checked = previewOn;

    if (previewOn) {
        previewLayer = new CmPreviewLayer({
            tileSize: CM_TILE_PX,
            pane:     'tilePane',
            zIndex:   300,          // above the context imagery
            updateWhenZooming: false,
        });
        previewLayer.addTo(map);
        cmSetContextDim(true);

        footprintWasOn = cmFootprintIsOn();
        cmFootprintSet(true);
        cmFootprintFollow(true);

        previewRow.value.textContent = 'on';
    } else {
        if (previewLayer) {
            map.removeLayer(previewLayer);
            previewLayer = null;
        }
        cmSetContextDim(false);

        cmFootprintFollow(false);
        cmFootprintSet(footprintWasOn);

        previewRow.value.textContent = '';
    }
}

// The tiles drawn are the tiles the card holds AT THIS ZOOM, so a zoom
// change is a different answer rather than the same one rescaled.

map.on('zoomend', () => { if (previewOn) cmPreviewInvalidate(); });

// The model changed, so every classification held is suspect -- a region
// reshaped, a zmax raised, a source repointed all move which tile the card
// would draw where. Thrown away whole rather than reconciled.

function cmPreviewInvalidate() {
    previewCache.clear();
    previewKey  = null;
    previewWait = null;
    if (previewOn && previewLayer) previewLayer.redraw();
}
window.cmPreviewInvalidate = cmPreviewInvalidate;

previewRow = cmPaletteRow('preview', 'preview',
    { checked: false, onToggle: togglePreview });
