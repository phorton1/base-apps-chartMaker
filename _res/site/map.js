// map.js -- the chartMaker Leaflet applet.
//
// THE BROWSER NEVER CONTACTS A TILE SERVER.  Every tile comes from the
// application's own proxy at /tile/<source>/{z}/{x}/{y}, which is what
// keeps credentials out of this page and its network log, and what makes
// displaying and building share one cache.  This file does not know, and
// must not be told, where any imagery actually lives.
//
// Which sources exist and which one is active comes from /state.

// The map's zoom range is FIXED and belongs to the map, not to whatever
// layer happens to be attached.  Leave map.maxZoom undefined and Leaflet
// derives it from the current layer, so switching sources silently moves
// the map's own range underneath it -- which is how a source swap turns
// into a runaway inside Leaflet's tile pruning.  A source declares only
// how deep it goes natively; how far the map may zoom is not its call.

const MAP_MAX_ZOOM = 22;

// WHEEL ZOOM IS DELIBERATELY SLOW.  Leaflet's default asks for 60 pixels of
// scroll per zoom level, which on a chart means one flick of the wheel jumps
// several levels and loses the place you were looking at.  Tripling it makes
// the wheel a way to creep in and out rather than to teleport.
//
// Zoom is still snapped to whole levels.  A fractional zoom would put the
// tile grid on fractional pixels and make the snap-to-grid dots blurry for
// no gain.

const WHEEL_PX_PER_ZOOM = 180;

const map = L.map('map', {
    maxZoom: MAP_MAX_ZOOM,
    wheelPxPerZoomLevel: WHEEL_PX_PER_ZOOM,
});

L.control.scale({ imperial: true, metric: true }).addTo(map);


// ============================================================================
// Where the map is looking
// ============================================================================
// THE VIEW IS THE BROWSER'S STATE, and it is kept here rather than sent to
// the application.  The application cannot ask a closed browser where it
// was looking, and a round trip on every pan would buy nothing, because
// nothing but this page ever reads the answer.
//
// moveend and zoomend fire when the pan, the inertia or the zoom animation
// has SETTLED -- not per frame during a drag -- so saving on them directly
// is already the debounce it looks like it needs.
//
// NO PLACE IS HARDCODED.  This applet shipped centred on Bocas del Toro,
// which was the only location-specific content in the tree.  The fallbacks
// are, in order: where you last were, the regions currently on the map,
// and finally the whole world -- which is the honest answer for somebody
// who has not drawn anything yet.

const VIEW_KEY   = 'chartMaker.view';
const WORLD_VIEW = { lat: 0, lon: 0, zoom: 2 };

function saveView() {
    try {
        const c = map.getCenter();
        localStorage.setItem(VIEW_KEY, JSON.stringify({
            lat: c.lat, lon: c.lng, zoom: map.getZoom(),
        }));
    } catch (e) {
        // Private browsing, a full quota, a policy -- none of it is worth
        // breaking the map over.  The view simply is not remembered.
    }
}

function savedView() {
    try {
        const v = JSON.parse(localStorage.getItem(VIEW_KEY) || 'null');
        if (v && isFinite(v.lat) && isFinite(v.lon) && isFinite(v.zoom)) return v;
    } catch (e) { /* corrupt or unavailable -- fall through */ }
    return null;
}

// Set immediately so the map is never without a view, then refined once
// /state arrives IF nothing was remembered -- see fitRegionsIfUnset().

const startView = savedView() || WORLD_VIEW;
map.setView([startView.lat, startView.lon], startView.zoom);

let viewIsFromStorage = savedView() !== null;

function fitRegionsIfUnset(regions) {
    // Only ever fires on the first /state of a session that had nothing
    // remembered.  After that the user's own view wins, and it must not be
    // yanked away from them by a poll.
    if (viewIsFromStorage) return;

    const pts = [];
    const walk = reg => {
        (reg.polygons || []).forEach(poly =>
            poly.forEach(p => pts.push([p[1], p[0]])));
        (reg.subregions || []).forEach(walk);
    };
    (regions || []).forEach(walk);

    // NOTHING TO FIT IS NOT AN ANSWER.  The world view stands and the
    // flag is deliberately left unset, so that importing a region into an
    // empty set still lands the map on it rather than leaving somebody
    // staring at the Atlantic wondering where their KML went.

    if (!pts.length) return;

    viewIsFromStorage = true;
    map.fitBounds(L.latLngBounds(pts), { padding: [24, 24] });
}

map.on('moveend zoomend', saveView);

let imageryLayer = null;
let imagerySig   = null;    // what the current layer was built from

function setImagerySource(src) {
    // Rebuilding a tile layer throws away every tile it has drawn, so it
    // happens only when something about the source actually changed.
    const sig = src ? JSON.stringify(src) : null;
    if (sig === imagerySig) return;
    imagerySig = sig;

    if (imageryLayer) {
        map.removeLayer(imageryLayer);
        imageryLayer = null;
    }
    if (!src) return;

    imageryLayer = L.tileLayer('/tile/' + src.id + '/{z}/{x}/{y}', {
        attribution:   src.attribution,
        maxNativeZoom: src.zoom_max,
        maxZoom:       MAP_MAX_ZOOM,
        tileSize:      src.tile_size,
    });
    imageryLayer.addTo(map);
}


// ============================================================================
// Regions
// ============================================================================
// Drawn read-only.  The application owns the model; this is a view of it.
// Editing arrives later, and with it the rule that an object under the
// user's hand leaves this layer until the edit commits.

const regionLayer = L.layerGroup().addTo(map);
let regionSig = null;

const REGION_STYLE    = { color: '#ffcc00', weight: 2, fillOpacity: 0.05 };
const SUBREGION_STYLE = { color: '#00e5ff', weight: 2, fillOpacity: 0.10 };

function drawRegion(reg, style, rootId) {
    // AN OBJECT UNDER EDIT LEAVES THIS LAYER.  cmEdit draws it from its own
    // copy while the user's hand is on it; drawing it from the model as well
    // would hand the old geometry back mid-drag.
    if (window.cmEditSuppresses && window.cmEditSuppresses(rootId, reg.id)) {
        (reg.subregions || []).forEach(sub =>
            drawRegion(sub, SUBREGION_STYLE, rootId));
        return;
    }

    // The model stores [lon,lat]; Leaflet wants [lat,lng].
    reg.polygons.forEach(poly => {
        // A region labels its AUTHORED level; a subregion has none and
        // labels the depth it reaches instead.
        const label = reg.zauthor === undefined
            ? reg.name + '  (to z' + reg.zmax + ')'
            : reg.name + '  (z' + reg.zauthor + '-' + reg.zmax + ')';
        L.polygon(poly.map(p => [p[1], p[0]]), style)
            .bindTooltip(label, { sticky: true })
            .addTo(regionLayer);
    });
    (reg.subregions || []).forEach(sub => drawRegion(sub, SUBREGION_STYLE, rootId));
}

function setRegions(regions) {
    // The suppression state is part of the signature, because an object
    // entering or leaving an edit changes what should be drawn without the
    // model having changed at all.
    const sig = JSON.stringify(regions) + '|' + suppressionSig();
    if (sig === regionSig) return;
    regionSig = sig;

    lastRegions = regions || [];
    regionLayer.clearLayers();
    lastRegions.forEach(reg => drawRegion(reg, REGION_STYLE, reg.id));
    fitRegionsIfUnset(regions);
}

let lastRegions = [];

function suppressionSig() {
    // ASKED OF cmEdit DIRECTLY, never derived by walking the region list.
    // Deriving it needed lastRegions, which is stale on exactly the call
    // that matters -- entering an edit -- so the signature could match the
    // previous one and setRegions would skip the redraw that was supposed
    // to hide the object being edited.  The result was an edit whose
    // handles sat on top of a polygon still drawn from the model.
    return window.cmEditTargetKey ? window.cmEditTargetKey() : '';
}

// cmEdit calls this when it starts or finishes holding an object, so the
// poll-rendered layer picks the change up without waiting for the model.
function cmRedrawRegions() {
    regionSig = null;
    setRegions(lastRegions);
}
window.cmRedrawRegions = cmRedrawRegions;


// ============================================================================
// The coverage footprint
// ============================================================================
// The tiles that would actually be built, drawn AT THE ZOOM BEING VIEWED.
// That is what keeps it both legible and honest: a tile is about 256
// pixels on the screen at any zoom, and the outline really is the
// coverage at the zoom being looked at.  Zoom in and the staircase along
// the boundary refines.
//
// Only the viewport is asked for.  The full set at z16 is tens of
// thousands of tiles, and an answer about tiles nobody can see is of no
// use to anybody.

const coverageLayer = L.layerGroup();
let coverageOn  = false;
let coverageSig = null;

const COVERAGE_STYLE = {
    color: '#ff3b30', weight: 1, opacity: 0.9,
    fill: true, fillOpacity: 0.06, interactive: false,
};

async function refreshCoverage() {
    if (!coverageOn) return;
    const z = Math.round(map.getZoom());
    const b = map.getBounds();
    const q = '/coverage?z=' + z +
        '&w=' + b.getWest()  + '&s=' + b.getSouth() +
        '&e=' + b.getEast()  + '&n=' + b.getNorth();

    // The view has not moved enough to change the answer.
    const sig = q + '|' + renderedVersion;
    if (sig === coverageSig) return;
    coverageSig = sig;

    let data;
    try {
        data = await fetchJson(q, STATE_TIMEOUT_MS);
    } catch (e) {
        console.warn('chartMaker: /coverage failed', e);
        return;
    }
    if (!coverageOn) return;               // toggled off while in flight

    coverageLayer.clearLayers();
    const n = 1 << data.zoom;
    data.tiles.forEach(t => {
        const [x, y] = t;
        const w = x / n * 360 - 180;
        const e = (x + 1) / n * 360 - 180;
        L.rectangle([[tileLat(y + 1, n), w], [tileLat(y, n), e]],
                    COVERAGE_STYLE).addTo(coverageLayer);
    });
    coverageCount.textContent =
        data.tiles.length + ' of ' + data.total + ' tiles at z' + data.zoom;
}

function tileLat(y, n) {
    const t = Math.PI - 2 * Math.PI * y / n;
    return 180 / Math.PI * Math.atan(0.5 * (Math.exp(t) - Math.exp(-t)));
}

// ---- the control ----

const coverageBox = L.control({ position: 'topright' });
let coverageCount;

coverageBox.onAdd = function () {
    const div = L.DomUtil.create('div', 'leaflet-bar cm-coverage');
    div.style.background = 'rgba(255,255,255,0.85)';
    div.style.padding    = '4px 8px';
    div.style.font       = '12px sans-serif';
    div.style.cursor     = 'default';

    const label = document.createElement('label');
    label.style.cursor = 'pointer';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    label.appendChild(cb);
    label.appendChild(document.createTextNode(' tile footprint'));
    div.appendChild(label);

    coverageCount = document.createElement('div');
    coverageCount.style.color = '#555';
    coverageCount.style.marginTop = '2px';
    div.appendChild(coverageCount);

    L.DomEvent.disableClickPropagation(div);
    cb.addEventListener('change', () => {
        coverageOn = cb.checked;
        if (coverageOn) {
            coverageLayer.addTo(map);
            coverageSig = null;
            refreshCoverage();
        } else {
            map.removeLayer(coverageLayer);
            coverageLayer.clearLayers();
            coverageCount.textContent = '';
        }
    });
    return div;
};
coverageBox.addTo(map);

map.on('moveend zoomend', refreshCoverage);


// ============================================================================
// The poll loop
// ============================================================================
// The application holds the truth.  /poll returns a cheap version number;
// when it differs from what we last rendered, the WHOLE of /state is
// refetched.  There is no delta protocol and no second channel -- every
// later addition arrives in the same document behind the same counter.
//
// The server has no notion of a connected browser.  It answers questions.
// That is what makes closing and reopening this page a non-event, and it
// is why reconnect is entirely the client's business: on any failure we
// forget what we rendered, so the next successful poll sees a mismatch
// and resynchronises everything.
//
// The two timers are separate on purpose.  Polling has to stay on its own
// cadence even while a render is in progress, because the moment it does
// not, a slow render silently becomes a dropped connection.

const POLL_INTERVAL_MS   = 1000;
const RENDER_INTERVAL_MS = 250;
const POLL_TIMEOUT_MS    = 2000;    // short - detect a dead server quickly
const STATE_TIMEOUT_MS   = 10000;   // longer - the payload can be large

let polledVersion   = -1;
let renderedVersion = -1;
let fetching        = false;
let connected       = true;

async function fetchJson(path, timeoutMs) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
        const res = await fetch(path, { signal: ctl.signal });
        if (!res.ok) throw new Error(path + ' returned ' + res.status);
        return await res.json();
    } finally {
        clearTimeout(timer);
    }
}

function onDisconnected(what, e) {
    if (connected) {
        connected = false;
        console.warn('chartMaker: lost the application (' + what + ')', e);
    }
    renderedVersion = -1;       // force a full resync when it comes back
}

function onConnected() {
    if (!connected) {
        connected = true;
        console.info('chartMaker: reconnected');
    }
}

async function pollVersion() {
    try {
        const poll = await fetchJson('/poll', POLL_TIMEOUT_MS);
        polledVersion = poll.version;
        onConnected();
    } catch (e) {
        onDisconnected('poll', e);
    }
}

async function applyState() {
    if (fetching || polledVersion === renderedVersion) return;
    fetching = true;
    const wanted = polledVersion;
    try {
        const state = await fetchJson('/state', STATE_TIMEOUT_MS);
        onConnected();

        // Mark it rendered BEFORE touching Leaflet.  A failure while
        // building the layer must not leave us retrying every 250ms --
        // each retry would add another layer, and enough of them make
        // the tile pruner unable to finish.  A broken layer is a bug to
        // read in the console, not a thing to attempt forever.

        renderedVersion = wanted;

        const src = (state.sources || [])
            .find(s => s.id === state.active_source) || null;
        if (!src) {
            console.warn('chartMaker: /state names no active source');
        }
        try {
            setImagerySource(src);
        } catch (e) {
            console.error('chartMaker: could not build the imagery layer', e);
        }
        try {
            if (window.cmEditOnState) cmEditOnState(state);
        } catch (e) {
            console.error('chartMaker: cmEdit choked on the state', e);
        }
        try {
            setRegions(state.regions);
        } catch (e) {
            console.error('chartMaker: could not draw the regions', e);
        }
        // The model changed, so any footprint on screen is now stale.
        coverageSig = null;
        refreshCoverage();
    } catch (e) {
        onDisconnected('state', e);
    } finally {
        fetching = false;
    }
}

setInterval(pollVersion, POLL_INTERVAL_MS);
setInterval(applyState,  RENDER_INTERVAL_MS);
pollVersion();


// ---- Cursor coordinates ----

function toDDM(dd, isLat) {
    const dir = isLat ? (dd >= 0 ? 'N' : 'S') : (dd >= 0 ? 'E' : 'W');
    const abs = Math.abs(dd);
    const deg = Math.floor(abs);
    const min = (abs - deg) * 60;
    return deg + '\u00B0' + min.toFixed(3) + "' " + dir;
}

const coordsDiv = document.getElementById('cm-coords');
let lastLatLng = null;

function showCoords() {
    // The zoom is redrawn on its own event as well as on mousemove.
    // Reading it only when the pointer moves leaves a stale number on
    // screen after a zoom, which is worse than showing none.
    if (!lastLatLng) {
        coordsDiv.textContent = 'zoom ' + map.getZoom();
        return;
    }
    const lat = lastLatLng.lat, lng = lastLatLng.lng;
    coordsDiv.textContent =
        toDDM(lat, true) + '  ' + toDDM(lng, false) + '\n' +
        lat.toFixed(5)   + '  ' + lng.toFixed(5)    + '\n' +
        'zoom ' + map.getZoom();
}

map.on('mousemove', e => { lastLatLng = e.latlng; showCoords(); });
map.on('mouseout',  ()  => { lastLatLng = null;   showCoords(); });
map.on('zoomend',   showCoords);
showCoords();
