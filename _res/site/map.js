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

// Yellow says region, cyan says subregion - and WHITE SAYS SELECTED,
// outranking both.  What kind of object it is can be read off the tree or
// the info panel; which one is under discussion cannot be read anywhere
// else on the map, so it gets the colour that is not a category.

const REGION_STYLE    = { color: '#ffcc00', weight: 2, fillOpacity: 0.05 };
const SUBREGION_STYLE = { color: '#00e5ff', weight: 2, fillOpacity: 0.10 };
const SELECTED_STYLE  = { color: '#ffffff', weight: 3, fillOpacity: 0.12 };

let selectedId = '';

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
        L.polygon(poly.map(p => [p[1], p[0]]),
                  reg.id === selectedId ? SELECTED_STYLE : style)
            .bindTooltip(label, { sticky: true })
            .addTo(regionLayer);
    });
    (reg.subregions || []).forEach(sub => drawRegion(sub, SUBREGION_STYLE, rootId));
}

function setRegions(regions) {
    // The suppression state and the SELECTION are part of the signature,
    // because either one changes what should be drawn without the model
    // having changed at all - an object entering an edit, or becoming the
    // white one.
    const sig = JSON.stringify(regions) + '|' + suppressionSig() +
                '|' + selectedId;
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
// The palette
// ============================================================================
// EVERYTHING THE USER SETS IS ON THE LEFT; everything the map reports is on
// the right.  A control that also answers a question has to be read in one
// place and operated in another, and the two get in each other's way -- so
// the switches live here and the numbers live in the info panel.
//
// A Leaflet control at topleft rather than a box positioned by hand: the
// zoom buttons are a control at the same corner, so the stack takes care of
// itself and stays put at any window size.
//
// Rows are added by whichever file owns the thing being switched, and they
// appear in the order named here rather than the order they were added.

const PALETTE_ROWS = ['grid', 'autozoom', 'footprint'];

const paletteBox = L.control({ position: 'topleft' });
let paletteDiv = null;

paletteBox.onAdd = function () {
    paletteDiv = L.DomUtil.create('div', 'leaflet-bar cm-palette');
    L.DomEvent.disableClickPropagation(paletteDiv);
    L.DomEvent.disableScrollPropagation(paletteDiv);
    return paletteDiv;
};
paletteBox.addTo(map);

// Three columns: the checkbox, the label, and a value that is either text
// or a control of the row's own.  THE WHOLE ROW IS THE SWITCH, so it can be
// hit without aiming; the exception is a control in the value column, which
// has its own job and must not toggle the row on its way to doing it.
//
// The checkbox carries no handler.  A click on it bubbles to the row,
// toggles once, and the owner sets .box.checked from its own flag, so the
// flag stays the only state.

function paletteRow(key, label, opts) {
    opts = opts || {};
    const row = document.createElement('div');
    row.className = 'cm-pal-row';
    row.dataset.key = key;

    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'cm-pal-box';
    box.tabIndex = -1;
    box.checked = !!opts.checked;

    const lab = document.createElement('span');
    lab.className = 'cm-pal-label';
    lab.textContent = label;

    const val = document.createElement('span');
    val.className = 'cm-pal-value';

    row.appendChild(box);
    row.appendChild(lab);
    row.appendChild(val);

    row.onclick = ev => {
        const t = ev.target;
        if (t !== box && /^(INPUT|SELECT|BUTTON)$/.test(t.tagName)) return;
        if (opts.onToggle) opts.onToggle();
    };

    const want = PALETTE_ROWS.indexOf(key);
    let before = null;
    for (const el of paletteDiv.children) {
        if (PALETTE_ROWS.indexOf(el.dataset.key) > want) { before = el; break; }
    }
    paletteDiv.insertBefore(row, before);

    return { row: row, box: box, label: lab, value: val };
}
window.cmPaletteRow = paletteRow;


// ============================================================================
// The info panel
// ============================================================================
// The other half of the split: what the map has to SAY.  The set the work
// is in, the object selected, the zooms that object carries, and what the
// footprint counted.  Nothing here is operable.
//
// The selected object is drawn in bold blue because it is the one line that
// answers "what am I working on" -- everything around it is context.

const infoBox = L.control({ position: 'topright' });
let infoDiv    = null;
let infoState  = null;
let infoCount  = '';
let counts     = null;
let countsKey  = null;

// DECLARED HERE, WITH THE PANEL THAT READS IT, rather than beside the poll
// loop that sets it: drawInfo() runs once at load to put something on
// screen, and a `let` further down the file is not initialised yet when it
// does - which is a dead reference rather than a false.
let dark = false;

infoBox.onAdd = function () {
    infoDiv = L.DomUtil.create('div', 'cm-info');
    L.DomEvent.disableClickPropagation(infoDiv);
    return infoDiv;
};
infoBox.addTo(map);

function findNode(regions, id) {
    // The node with this id, and the region it belongs to.
    const dig = (node, root) => {
        if (node.id === id) return { root: root, node: node };
        for (const s of (node.subregions || [])) {
            const found = dig(s, root);
            if (found) return found;
        }
        return null;
    };
    for (const r of (regions || [])) {
        const found = dig(r, r);
        if (found) return found;
    }
    return null;
}

function infoRow(key, value, cls) {
    const row = document.createElement('div');
    row.className = 'cm-info-row' + (cls ? ' ' + cls : '');
    const k = document.createElement('span');
    k.className = 'cm-info-k';
    k.textContent = key;
    const v = document.createElement('span');
    v.className = 'cm-info-v';
    v.textContent = value;
    row.appendChild(k);
    row.appendChild(v);
    infoDiv.appendChild(row);
}

function prettyBytes(n) {
    if (!n) return '-';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i && n < 10 ? n.toFixed(1) : Math.round(n)) + ' ' + u[i];
}

// A LEVEL ROW IS TWO NUMBERS, and they are padded rather than given their
// own columns: the panel is monospace, so a pad IS a column, and one built
// out of flex boxes would only be the same thing with more parts.

function levelRow(label, tiles, bytes, cls) {
    infoRow(label,
        tiles.toLocaleString().padStart(8) + '  ' + prettyBytes(bytes).padStart(8),
        'cm-info-in' + (cls ? ' ' + cls + '-in' : ''));
}

function countBlock(block, cls) {
    if (!block) return;
    for (const lv of block.levels) levelRow('z' + lv.z, lv.tiles, lv.bytes, cls);
    levelRow('total', block.tiles, block.bytes, cls);
}

// The subregions between a region and one of its descendants, outermost
// first - the same path the counts arrive in, computed here so the panel
// can be drawn before they do.
function ancestry(reg, id) {
    if (reg.id === id) return [];
    for (const sub of (reg.subregions || [])) {
        if (sub.id === id) return [sub];
        const deeper = ancestry(sub, id);
        if (deeper.length) return [sub].concat(deeper);
    }
    return [];
}

// FOUR DEPTHS ARE COLOURED and anything deeper reuses the last.  A fourth
// level of nesting is already past z22, where no source has imagery and
// the map itself will not go - so running out of colours is not a case
// worth designing for, but running out of them SILENTLY would be.
const MAX_INFO_DEPTH = 3;

// THE PANEL NESTS THE WAY THE MODEL DOES.  The set is always the top line;
// the selected region is always named under it; and a selected subregion
// ADDS a block rather than replacing the region's - which is what makes it
// unnecessary to say whose subregion it is, the region being the line
// above.  Nothing is a summary of anything else: each block is the band
// only it supplies, so they read down the panel as addition.

function drawInfo() {
    if (!infoDiv) return;
    infoDiv.innerHTML = '';
    const s = infoState;
    const c = counts;

    // THE PANEL IS WHERE THE MAP SAYS WHAT IT KNOWS, so it is also where
    // it says that it knows nothing.  Three states, not two: connected
    // with a set, connected with none, and not connected at all.

    if (dark) {
        infoRow('chartMaker', 'not connected', 'cm-info-d0');
        return;
    }
    if (s && !s.active_set) {
        infoRow('set', 'none open', 'cm-info-d0');
        return;
    }
    if (s && s.active_set) {
        infoRow('set', s.active_set + (s.set_dirty ? ' *' : ''));
        // TILE COUNTS ARE NOT INTERESTING AT SET LEVEL - what a whole card
        // costs is, and that is one number.
        if (c && c.set) infoRow('size', prettyBytes(c.set.bytes), 'cm-info-in');
    }

    const sel = s && s.selection;
    const id  = sel && (sel.sub || sel.region);
    const hit = id ? findNode(s.regions, id) : null;

    if (!hit) {
        infoRow('nothing', 'selected', 'cm-info-d0');
    } else {
        // ONE BLOCK PER LEVEL, from the region down to what is selected,
        // each in the colour of its depth.  Nesting is what the colours
        // are for: at three deep the words 'subregion' are no longer
        // telling them apart, and the numbers under each one only mean
        // something against the level above.

        const chain = (c && c.chain) || [];
        const path  = [hit.root].concat(ancestry(hit.root, hit.node.id));

        path.forEach((node, depth) => {
            const cls = 'cm-info-d' + Math.min(depth, MAX_INFO_DEPTH);
            infoRow(depth ? 'subregion' : 'region',
                node.id + (depth ?
                    '   to z' + node.zmax :
                    '   z' + node.zmin + '-' + node.zmax + ' @' + node.zauthor),
                cls);

            const block = chain.find(b => b.id === node.id);
            if (block) countBlock(block, cls);
        });
    }

    if (infoCount) {
        infoRow('footprint', infoCount);
        infoDiv.lastChild.title = 'tiles in view / tiles in the whole set';
    }
}

// ASKED WHEN THE ANSWER COULD HAVE CHANGED, which is not every poll.  The
// counts depend on the geometry and on which object is selected, and on
// nothing else - so entering an edit, moving the map, or publishing a mode
// asks nothing.  Geometry only reaches the model on commit, which is what
// leaves the table still through an edit without a rule saying so.

async function refreshCounts(state) {
    const key = JSON.stringify(state.regions) + '|' + selectedId;
    if (key === countsKey) return;
    countsKey = key;

    try {
        counts = await fetchJson('/counts?id=' + encodeURIComponent(selectedId),
                                 STATE_TIMEOUT_MS);
    } catch (e) {
        console.warn('chartMaker: /counts failed', e);
        counts = null;
    }
    drawInfo();
}

drawInfo();     // says "nothing selected" until the first document arrives


// ============================================================================
// The coverage footprint
// ============================================================================
// The tiles that would actually be built, AT A LEVEL THE USER CHOOSES.  The
// question worth answering is how dense this region is at a given zoom, and
// tying that to the view made it unanswerable: the number changed every
// time the map moved, and comparing two levels meant zooming away from what
// was being looked at.  The level is a spinner in the palette instead.
//
// Only the viewport is asked for.  The full set at z16 is tens of thousands
// of tiles, and an answer about tiles nobody can see is of no use to
// anybody -- so the rectangles are clipped to the view while the COUNT is
// the whole set at that level.

const coverageLayer = L.layerGroup();
let coverageOn  = false;
let coverageZ   = null;     // chosen, never inherited from the view
let coverageSig = null;

const COVERAGE_STYLE = {
    color: '#ff3b30', weight: 1, opacity: 0.9,
    fill: true, fillOpacity: 0.06, interactive: false,
};

async function refreshCoverage() {
    if (!coverageOn) return;
    const z = coverageZ === null ? Math.round(map.getZoom()) : coverageZ;
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
    // IN VIEW OVER TOTAL, and no level in the text - the spinner beside the
    // checkbox already says which level this is, and a panel that repeats
    // what the palette just said grows wide enough to matter.
    infoCount = data.tiles.length.toLocaleString() + ' / ' +
                data.total.toLocaleString();
    drawInfo();
}

function tileLat(y, n) {
    const t = Math.PI - 2 * Math.PI * y / n;
    return 180 / Math.PI * Math.atan(0.5 * (Math.exp(t) - Math.exp(-t)));
}

// ---- the palette row ----

const coverageRow = paletteRow('footprint', 'tile footprint',
    { checked: false, onToggle: toggleCoverage });

const coverageSpin = document.createElement('input');
coverageSpin.type      = 'number';
coverageSpin.min       = 1;
coverageSpin.max       = MAP_MAX_ZOOM;
coverageSpin.className = 'cm-pal-spin';
coverageSpin.value     = Math.round(map.getZoom());   // until /state says better
coverageRow.value.appendChild(coverageSpin);

coverageSpin.addEventListener('change', () => {
    const z = clampZ(Math.round(+coverageSpin.value));
    coverageSpin.value = z;
    coverageZ   = z;
    coverageSig = null;
    refreshCoverage();
});

function clampZ(z) {
    return Math.max(+coverageSpin.min, Math.min(+coverageSpin.max, z));
}

// THE RANGE IS THE WORK, NOT THE PROTOCOL.  A level below the region's zmin
// or above the deepest subregion in it holds no tiles at all, so offering it
// would be offering an answer of zero and calling it information.  The floor
// is the region's zmin - the overview it starts at - and the ceiling is the
// deepest zmax anywhere inside it, which is a subregion's whenever one goes
// deeper than its parent.
//
// With nothing selected the same question is asked of every region at once,
// because the footprint is of everything on the map.

function footprintRange(state) {
    const regions = (state && state.regions) || [];
    const sel     = selectedId ? findNode(regions, selectedId) : null;
    const roots   = sel ? [sel.root] : regions;

    let lo = null, hi = null;
    const walk = node => {
        if (node.zmin !== undefined)
            lo = lo === null ? node.zmin : Math.min(lo, node.zmin);
        if (node.zmax !== undefined)
            hi = hi === null ? node.zmax : Math.max(hi, node.zmax);
        (node.subregions || []).forEach(walk);
    };
    roots.forEach(walk);

    return (lo === null || hi === null) ? null : { min: lo, max: hi };
}

// The selection moves the range, and a level that was legal under the last
// one may not be under this.  It is pulled to the nearest level that is,
// rather than reset to a default, because it is still the closest thing to
// what was being asked.

function updateFootprintRange(state) {
    const range = footprintRange(state);
    if (!range) return;

    coverageSpin.min = range.min;
    coverageSpin.max = range.max;

    if (coverageZ === null) {
        const first = (state.regions || [])[0];
        coverageZ = first && first.zauthor !== undefined ?
            first.zauthor : Math.round(map.getZoom());
    }
    const z = clampZ(coverageZ);
    if (z !== coverageZ) coverageSig = null;
    coverageZ = z;
    coverageSpin.value = z;
}

function toggleCoverage() {
    coverageOn = !coverageOn;
    coverageRow.box.checked = coverageOn;
    if (coverageOn) {
        coverageLayer.addTo(map);
        coverageSig = null;
        refreshCoverage();
    } else {
        map.removeLayer(coverageLayer);
        coverageLayer.clearLayers();
        infoCount = '';
        drawInfo();
    }
}

// The view still decides WHICH rectangles are worth drawing, so a pan is
// still a new question even though the level no longer moves with it.

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

// NOTHING BEHIND IT MEANS NOTHING ON IT.  A chartset drawn with no
// application behind it is a picture of something that may no longer be
// true - the set could have been closed, reverted, or replaced while the
// page went on showing it - so after a grace period the map stops showing
// a model it can no longer vouch for.
//
// AFTER A GRACE PERIOD, and not on the first failed poll: restarting the
// application takes a few seconds, and wiping the screen every time would
// make an ordinary restart look like a crash.
//
// The imagery layer is deliberately left alone.  Its tiles come through
// the application too, so it simply stops loading new ones; tearing it
// down would blank the whole map for nothing.

const DISCONNECT_MS = 5000;

let lastOkMs = Date.now();

function goDark() {
    if (dark) return;
    dark = true;
    console.warn('chartMaker: the application is not there - clearing');

    regionLayer.clearLayers();
    lastRegions = [];
    regionSig   = null;
    selectedId  = '';

    coverageLayer.clearLayers();
    infoCount = '';
    counts    = null;
    countsKey = null;
    infoState = null;

    if (window.cmEditDisconnected) cmEditDisconnected();
    drawInfo();
}

function onDisconnected(what, e) {
    if (connected) {
        connected = false;
        console.warn('chartMaker: lost the application (' + what + ')', e);
    }
    renderedVersion = -1;       // force a full resync when it comes back
    if (Date.now() - lastOkMs > DISCONNECT_MS) goDark();
}

function onConnected() {
    lastOkMs = Date.now();
    if (!connected) {
        connected = true;
        console.info('chartMaker: reconnected');
    }
    dark = false;
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

        // THE ZOOM CEILING IS A PREFERENCE OF THE APPLICATION, and this
        // page is a static file that cannot read one - so it arrives with
        // the state.  Applied only when it actually differs, because
        // setMaxZoom re-evaluates every layer.  MAP_MAX_ZOOM remains the
        // value the map is BUILT with, for the first paint before any
        // state has arrived.

        if (state.map_max_zoom && state.map_max_zoom !== map.getMaxZoom())
            map.setMaxZoom(state.map_max_zoom);

        // WHAT IS SELECTED IS PART OF THE DOCUMENT, so the map learns it on
        // the same poll as everything else and no surface can disagree.

        selectedId = (state.selection &&
            (state.selection.sub || state.selection.region)) || '';
        infoState = state;

        // The footprint opens on the level the work is authored at, which is
        // the only level anybody has expressed an opinion about, and is held
        // within the range the selection actually spans.

        updateFootprintRange(state);

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
        drawInfo();
        refreshCounts(state);

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
