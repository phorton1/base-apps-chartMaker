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

// LONGITUDE COMES OUT OF LEAFLET UNWRAPPED.  Pan east around the world and
// getCenter() reports 368.9 rather than 8.9 -- the same meridian, counted
// from where the user started rather than from Greenwich.  Every place a
// coordinate LEAVES the map has to wrap it, because everything downstream
// reasonably believes a longitude is a longitude: the application refused
// the out-of-range value and silently kept showing the last good one, the
// remembered view stored a number that grew every lap, and the readout
// showed a coordinate that is on no chart.

function wrapped(ll) { return ll.wrap(); }

function saveView() {
    try {
        const c = wrapped(map.getCenter());
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

        // NO errorTileUrl, DELIBERATELY, and this is the correction of a
        // real defect rather than a tidying.
        //
        // Nothing there still looks like something: the no_data picture is
        // served BY THE PROXY, as a 200, for an absence and for nothing
        // else - see em_server::applet_tile.  Every 'nothing here' still
        // looks the same whatever the service did to say it, because the
        // proxy resolves a refusal and a declared sentinel to the same
        // answer before this ever sees one.
        //
        // What errorTileUrl added on top of that was a LIE.  An <img> load
        // failure carries no status code, so it painted that same picture
        // for a 502 and for any request the browser aborted mid-flight -
        // which is what panning does, constantly.  Leaflet keeps a tile
        // once drawn, so a tile that failed because the user moved kept
        // saying 'no data' about ground the service holds.
        //
        // Now a failure loads no image, Leaflet leaves the tile alone, and
        // the next pan asks again.  That is the honest rendering of an
        // answer that never arrived, and it is self-healing.
    });
    imageryLayer.addTo(map);
    applyContextDim();
}

// THE IMAGERY BECOMES CONTEXT WHEN PREVIEW IS ON, and says so by going
// dim. Held as a flag rather than applied once, because switching sources
// builds a whole new layer - and a preview whose context quietly came back
// to full brightness would be telling the user that everything on screen is
// in their chartset.

let contextDim = false;

function applyContextDim() {
    if (!imageryLayer) return;
    const el = imageryLayer.getContainer();
    if (el) el.classList.toggle('cm-context-dim', contextDim);
}

function cmSetContextDim(on) {
    contextDim = !!on;
    applyContextDim();
}
window.cmSetContextDim = cmSetContextDim;

// What the preview's classifications are valid against. Anything that can
// move a tile moves this.
function cmModelKey() {
    return renderedVersion;
}
window.cmModelKey = cmModelKey;


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


// ============================================================================
// SHADING THE SELECTION, and being able to turn it off
// ============================================================================
// The selected object is filled as well as outlined, at a heavier opacity
// than anything else on the map. That was one signal too many: the white
// outline already outranks every other colour here, and the info panel names
// the object in words. What the fill adds is a wash over the imagery -
// which is the thing being judged, on the one object you are judging it on.
//
// It is worst exactly when it matters most: while drawing or editing, when
// you are looking hardest at the ground under the vertices.
//
// SO IT IS A SWITCH, not a smaller number. Anybody who wants the fill has it
// and it defaults on, which is what the map has always done; anybody who
// finds it in the way turns it off once. Tuning the opacity down would have
// annoyed one of those two people without satisfying the other.
//
// REMEMBERED IN THE BROWSER, like autozoom, and for the same reason: it is a
// property of how somebody looks at a map rather than anything about the
// document, and having to turn it off after every reload is the friction the
// switch exists to remove.

const SHADE_KEY = 'chartMaker.shadeSelection';
let shadeSelection = (localStorage.getItem(SHADE_KEY) !== 'off');   // defaults ON
let shadeRow = null;

function cmShadeSelection() { return shadeSelection; }
window.cmShadeSelection = cmShadeSelection;

// THE FILL IS DROPPED, THE OUTLINE IS NOT. What identifies the selection is
// the white line and its weight, and neither is in question.
function shadeStyle(style) {
    return shadeSelection ? style : Object.assign({}, style, { fill: false });
}

function drawShadeRow() {
    if (!shadeRow)
        shadeRow = paletteRow('shade', 'shade selection',
            { checked: shadeSelection, onToggle: toggleShade });
    shadeRow.box.checked = shadeSelection;
    shadeRow.row.title =
        'wash the selected object - the white outline says so either way';
}

function toggleShade() {
    shadeSelection = !shadeSelection;
    localStorage.setItem(SHADE_KEY, shadeSelection ? 'on' : 'off');
    drawShadeRow();

    // BOTH SURFACES, because the object under EDIT is the selected one and
    // cmEdit draws it from its own copy - leaving that half on would make
    // the switch do nothing on the one screen it was asked for.
    cmRedrawRegions();
    if (window.cmRedrawWork) window.cmRedrawWork();
}

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
                  reg.id === selectedId ? shadeStyle(SELECTED_STYLE) : style)
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
// The switches.  The readouts are in the info panel at the top right.
//
// A Leaflet control at topleft rather than a box positioned by hand: the
// zoom buttons are a control at the same corner, so the stack takes care of
// itself and stays put at any window size.
//
// Rows are added by whichever file owns the thing being switched, and they
// appear in the order named here rather than the order they were added.

// THE OVERLAYS SIT BELOW A RULE, and the rule is an entry in this list like
// anything else -- because order here is what decides where a thing lands,
// and a separator that floated would be worse than none.  Everything above
// the rule switches how the MODEL is drawn; everything below it turns on
// somebody else's map.  That is a real difference and it is worth a line.

const PALETTE_ROWS = ['grid', 'autozoom', 'shade', 'footprint', 'tilegrid',
                      'preview', 'sep_overlays', 'labels', 'seamarks'];

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

    insertPaletteEl(row, key);

    return { row: row, box: box, label: lab, value: val };
}
window.cmPaletteRow = paletteRow;


// Rows arrive from four files in whatever order those files load, so where
// something goes is decided by PALETTE_ROWS and never by when it was added.

function insertPaletteEl(el, key) {
    const want = PALETTE_ROWS.indexOf(key);
    let before = null;
    for (const c of paletteDiv.children) {
        if (PALETTE_ROWS.indexOf(c.dataset.key) > want) { before = c; break; }
    }
    paletteDiv.insertBefore(el, before);
}


// A separator is ordered exactly like a row, and carries a key for that
// reason alone -- an element with no key sorts as -1 and would jump to the
// top of the palette the moment anything was added after it.

function paletteSeparator(key) {
    const sep = document.createElement('div');
    sep.className = 'cm-pal-sep';
    sep.dataset.key = key;
    insertPaletteEl(sep, key);
    return sep;
}
window.cmPaletteSeparator = paletteSeparator;


// ============================================================================
// The info panel
// ============================================================================
// What the map has to say.  The set the work is in, the object selected, the
// zooms that object carries, and what the footprint counted.  Nothing here is
// operable.
//
// The selected object is drawn in bold blue because it is the one line that
// answers "what am I working on" -- everything around it is context.

const infoBox = L.control({ position: 'topright' });
let infoDiv    = null;
let infoState  = null;

// WHICH SOURCE THE MAP IS SHOWING, for anything that wants to act on the
// one the user is actually looking at.  The probe's right-click items use
// it: the source is the subject of a probe, and the displayed one is the
// source the user is pointing at when they ask.
function cmActiveSourceId() {
    return (infoState && infoState.active_source) || '';
}
window.cmActiveSourceId = cmActiveSourceId;
let infoCount  = '';
let infoGrid   = '';
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
        // TILE COUNTS ARE NOT INTERESTING AT SET LEVEL - what a whole build
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

    // BELOW THE FOOTPRINT, because it is the question underneath it: which
    // tiles get built, and then where that level's edges actually fall.

    if (infoGrid) {
        infoRow('tile grid', infoGrid);
        infoDiv.lastChild.title = 'the level drawn, and tiles across the view';
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

// WHILE PREVIEW IS ON THE LEVEL IS NOT A CHOICE.  Preview fills in the
// tiles the output holds at the zoom being looked at, so a footprint pinned
// to some other level would be outlining a different question's answer -
// and the two disagreeing on screen is exactly what made the halo
// unreadable. Following the map is what makes the outlines mean "these are
// the tiles you are looking at".

let footprintFollows = false;

function cmFootprintFollow(on) {
    footprintFollows = !!on;
    coverageSpin.disabled = footprintFollows;
    coverageSig = null;
    refreshCoverage();
}
window.cmFootprintFollow = cmFootprintFollow;

function cmFootprintIsOn() { return coverageOn; }
window.cmFootprintIsOn = cmFootprintIsOn;

function cmFootprintSet(on) {
    if (!!on !== coverageOn) toggleCoverage();
}
window.cmFootprintSet = cmFootprintSet;

async function refreshCoverage() {
    if (!coverageOn) return;
    const z = footprintFollows ? Math.round(map.getZoom()) :
              coverageZ === null ? Math.round(map.getZoom()) : coverageZ;
    if (footprintFollows) coverageSpin.value = z;
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

// ---- the palette rows ----
//
// AFTER the control is on the map, because paletteRow inserts into a div that
// paletteBox.onAdd creates.  The shade row is declared with the styles it
// controls, up beside SELECTED_STYLE, and only built here.

drawShadeRow();

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
// The bare tile grid
// ============================================================================
// WHERE A LEVEL'S TILE EDGES FALL, over the whole view and belonging to
// nobody.
//
// The footprint answers "which tiles would be BUILT", so it is clipped to
// the region set and its count is against that set.  This answers the
// question underneath it, and that question has to be answerable BEFORE a
// region exists - which is exactly when it is wanted.  A service's coverage
// boundary, a bay, a pass, a partly filled tile: none of them can be read
// against a lattice that only appears where somebody already drew a polygon.
//
// THE SAME RED AS THE FOOTPRINT, deliberately.  The footprint's rectangles
// ARE tiles on this lattice, so their edges lie exactly on these lines and
// the two read as one continuous grid rather than as two overlays
// disagreeing.  A second colour would invent a distinction that is not
// there.  It is drawn lighter only so that the built set still reads as the
// figure and the lattice as the ground.
//
// LINES, NOT RECTANGLES.  A view forty tiles across is seventy polylines or
// twelve hundred rectangles for a pixel-identical picture, and the sum
// rather than the product is what lets this be left switched on while
// zooming out.
//
// IT ASKS NOBODY.  Pure arithmetic against the viewport, no /coverage, no
// round trip - so unlike every other overlay here it is still right when the
// application is not answering, which is why the disconnect handler leaves
// it alone.

const tileGridLayer = L.layerGroup();
let tileGridOn  = false;
let tileGridZ   = null;     // chosen, never inherited from the view
let tileGridSig = null;

const TILEGRID_STYLE = {
    color: '#ff3b30', weight: 1, opacity: 0.45,
    fill: false, interactive: false,
};

// PAST THIS IT IS A WASH AND NOT A GRID.  A level fine enough to put a
// thousand lines across the view draws a solid red rectangle, says nothing,
// and costs real time to say it.  So it stops - and the panel says WHY,
// because a switch that silently draws nothing reads as a broken switch.

const TILEGRID_MAX_LINES = 400;

function tileYOf(lat, n) {
    const r = lat * Math.PI / 180;
    return Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI)
                      / 2 * n);
}

function refreshTileGrid() {
    if (!tileGridOn) return;

    const z = tileGridZ === null ? Math.round(map.getZoom()) : tileGridZ;
    const b = map.getBounds();

    // CLAMPED TO WHAT MERCATOR HOLDS.  A world view reports latitudes past
    // the projection's own limit, and the tile row of 90 degrees is an
    // infinity that becomes a NaN line a long way from anywhere.
    //
    // The LONGITUDES are deliberately not clamped.  Leaflet reports bounds
    // past 180 once the map has been panned across the meridian, and the
    // tile column arithmetic carries straight through - clamping them would
    // reintroduce the wrap the map layer already had to have fixed.

    const north = Math.min(b.getNorth(),  85.05112878);
    const south = Math.max(b.getSouth(), -85.05112878);
    const west  = b.getWest();
    const east  = b.getEast();

    const sig = [z, west, south, east, north].join(',');
    if (sig === tileGridSig) return;
    tileGridSig = sig;

    tileGridLayer.clearLayers();

    const n  = 1 << z;
    const x0 = Math.floor((west + 180) / 360 * n);
    const x1 = Math.floor((east + 180) / 360 * n);
    const y0 = tileYOf(north, n);
    const y1 = tileYOf(south, n);

    const across = x1 - x0 + 1;
    const down   = y1 - y0 + 1;

    if (across + down + 2 > TILEGRID_MAX_LINES) {
        infoGrid = 'z' + z + '   too fine to draw here';
        drawInfo();
        return;
    }

    // MERIDIANS THE FULL HEIGHT OF THE VIEW AND PARALLELS THE FULL WIDTH,
    // rather than closing each cell.  Same picture, and the object count is
    // the sum of the two rather than their product.

    for (let x = x0; x <= x1 + 1; x++) {
        const lon = x / n * 360 - 180;
        L.polyline([[south, lon], [north, lon]], TILEGRID_STYLE)
            .addTo(tileGridLayer);
    }
    for (let y = y0; y <= y1 + 1; y++) {
        const lat = tileLat(y, n);
        L.polyline([[lat, west], [lat, east]], TILEGRID_STYLE)
            .addTo(tileGridLayer);
    }

    infoGrid = 'z' + z + '   ' + across + ' x ' + down;
    drawInfo();
}

const tileGridRow = paletteRow('tilegrid', 'tile grid',
    { checked: false, onToggle: toggleTileGrid });

// THE PROTOCOL RANGE, NOT THE WORK RANGE, and that is the whole difference
// from the footprint's spinner beside it.  The footprint is bounded by what
// the regions hold because a level they do not reach would answer zero; this
// one is about the ground and is just as meaningful over water nobody has
// drawn anything on yet.

const tileGridSpin = document.createElement('input');
tileGridSpin.type      = 'number';
tileGridSpin.min       = 1;
tileGridSpin.max       = MAP_MAX_ZOOM;
tileGridSpin.className = 'cm-pal-spin';
tileGridSpin.value     = Math.round(map.getZoom());
tileGridRow.value.appendChild(tileGridSpin);

tileGridSpin.addEventListener('change', () => {
    const z = Math.max(+tileGridSpin.min,
              Math.min(+tileGridSpin.max, Math.round(+tileGridSpin.value)));
    tileGridSpin.value = z;
    tileGridZ   = z;
    tileGridSig = null;
    refreshTileGrid();
});

function toggleTileGrid() {
    tileGridOn = !tileGridOn;
    tileGridRow.box.checked = tileGridOn;

    if (!tileGridOn) {
        map.removeLayer(tileGridLayer);
        tileGridLayer.clearLayers();
        infoGrid = '';
        drawInfo();
        return;
    }

    // IT OPENS ON WHAT THE FOOTPRINT IS SHOWING when the footprint is on,
    // because the two are then answering one question at one level and a
    // lattice at some other level would only be in the way.  Otherwise the
    // level being looked at, which is the only other defensible guess.

    if (tileGridZ === null)
        tileGridZ = (coverageOn && coverageZ !== null) ? coverageZ :
                    Math.round(map.getZoom());

    tileGridSpin.value = tileGridZ;
    tileGridLayer.addTo(map);
    tileGridSig = null;
    refreshTileGrid();
}

map.on('moveend zoomend', refreshTileGrid);


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

// BEING SENT SOMEWHERE.  A place is the one thing the application's own
// windows cannot name, so 'view' is a console verb, and this is where it
// lands.  What is watched is the SEQUENCE and not the coordinates: asking
// twice for the same place has to move the map twice, and comparing
// coordinates would move it once.
//
// THE FIRST POLL ADOPTS THE SEQUENCE WITHOUT MOVING.  A request made before
// this page existed was not made of this page, and replaying it on every
// reload would take a reopened map away from wherever it was left.

let seenViewSeq = null;

function applyViewRequest(poll) {
    if (poll.view_seq === undefined) return;

    // SEQUENCE ZERO MEANS NONE HAS EVER BEEN MADE, and it is re-adopted
    // rather than acted on.  The counter lives in the application, so
    // restarting it sends the sequence BACKWARDS to zero while this page
    // goes on running with a higher number remembered -- and "it changed"
    // would then be true of a request that does not exist, whose
    // coordinates are the zeroes the variables were declared with.  That
    // put the map on 0,0 at z0 every time chartMaker was restarted.
    if (!poll.view_seq) { seenViewSeq = poll.view_seq; return; }

    if (seenViewSeq === null) { seenViewSeq = poll.view_seq; return; }
    if (poll.view_seq === seenViewSeq) return;
    seenViewSeq = poll.view_seq;

    // Counts as the user's own view from here on, so the fit-to-regions
    // that a session with nothing remembered still owes cannot pull the
    // map back off the place that was just asked for.
    viewIsFromStorage = true;

    map.setView([poll.view_lat, poll.view_lon], poll.view_z);
}

async function pollVersion() {
    try {
        // WHERE WE ARE LOOKING RIDES ON THE POLL.  The application has no
        // notion of "here" -- a centre and a zoom are things a leaflet map
        // has and a wx dialog does not -- and anything that asks a tile
        // service about somewhere needs one.  Sent on the poll rather than
        // through an endpoint of its own because the poll is already the
        // one message that says this map exists.
        const c = wrapped(map.getCenter());
        const q = '?lat=' + c.lat.toFixed(6) +
                  '&lon=' + c.lng.toFixed(6) +
                  '&z='   + map.getZoom();

        const poll = await fetchJson('/poll' + q, POLL_TIMEOUT_MS);
        polledVersion = poll.version;
        onConnected();

        // A RUNNING PROBE MOVES ITS OWN SEQUENCE AND NOTHING ELSE.  It
        // publishes a unit per source and level while the state document
        // is unchanged, so waiting for the state version to move meant the
        // palette froze at whatever it read when the map opened and the
        // marks never arrived.  Asked here because /poll is where "has
        // anything changed" is already answered.
        if (window.cmProbeOnPoll) cmProbeOnPoll(poll);
        applyViewRequest(poll);
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
        try {
            if (window.cmProbeOnState) cmProbeOnState(state);
        } catch (e) {
            console.error('chartMaker: cmProbe choked on the state', e);
        }
        drawInfo();
        refreshCounts(state);

        // The model changed, so any footprint on screen is now stale, and
        // so is every preview classification.
        coverageSig = null;
        refreshCoverage();
        if (window.cmPreviewInvalidate) cmPreviewInvalidate();
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

map.on('mousemove', e => { lastLatLng = wrapped(e.latlng); showCoords(); });
map.on('mouseout',  ()  => { lastLatLng = null;   showCoords(); });
map.on('zoomend',   showCoords);
showCoords();
