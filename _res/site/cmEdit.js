// cmEdit.js -- chartMaker region and subregion editing.
//
// See docs/design/editing_map.md for the interface this implements and
// docs/design/editing.md for the rules it obeys.
//
// Depends on globals from map.js: map, fetchJson, tileLat, and the two
// hooks it calls back into -- cmEditOnState() and cmEditSuppresses().
//
// EVERY MUTATION GOES THROUGH /edit, which dispatches the same em_command
// vocabulary the console uses.  There is no private path to the model, and
// the ok flag that comes back is load bearing: this file drops its own copy
// of a polygon when it commits, so a refusal reported as success would let
// the next poll restore the old geometry with no explanation.

const MODE_BROWSE = 'browse';
const MODE_DRAW   = 'draw';
const MODE_SHAPE  = 'shape';

let cmState   = null;      // the last /state document
let mode      = MODE_BROWSE;
let dirty     = false;

let target    = null;      // { region, sub, poly }  what draw/shape acts on
let working   = null;      // the polygon list being edited, browser-side
let drawPts   = null;      // vertices placed so far in DRAW

let vtxHandles = [];
let midHandles = [];
let workLayer  = L.layerGroup();
let drawLine   = null;

const VTX_ICON = L.divIcon({ className: 'cm-vtx', iconSize: [11,11], iconAnchor: [5,5] });

// THE MIDPOINT'S BOX IS THE GRAB AREA, NOT THE MARK.  The div is vertex
// sized and transparent; map.css draws a 7px dot in the middle of it.  So
// it is easier to hit than it looks and still reads as smaller than a
// vertex, which is the point - a vertex exists, a midpoint is an offer.
const MID_ICON = L.divIcon({ className: 'cm-mid', iconSize: [11,11], iconAnchor: [5,5] });

const WORK_STYLE = { color: '#ffffff', weight: 2, dashArray: '4,3', fill: false };
const BAD_STYLE  = { color: '#ff3b30', weight: 2, fill: false };


// ============================================================================
// Talking to the application
// ============================================================================

async function postEdit(verb, args, data) {
    const body = { verb: verb, args: args || '' };
    if (data !== undefined) body.data = data;
    try {
        const r = await fetch('/edit', {
            method:  'POST',
            headers: { 'content-type': 'application/json' },
            body:    JSON.stringify(body),
        });
        return await r.json();
    } catch (e) {
        console.error('chartMaker: /edit failed', e);
        return { ok: 0, since: 0 };
    }
}

// The application's own words for a refusal, rather than a guess made here.
//
// THE FIELD IS 'text'.  This read l.line and l.msg, neither of which
// /api/log has ever emitted - every entry is { seq, color, text } - so the
// map produced an array of empty strings, the filter found nothing, and
// every refusal in the applet came out as the bare word "refused".  It had
// a fallback for the case where there was genuinely nothing to report, and
// that fallback was the only branch that ever ran.
//
// The line arrives with the process, thread, source file and level prefixed
// by Pub::Utils, so what is wanted is the part after 'ERROR - '.
async function refusalText(since) {
    try {
        const log = await fetchJson('/api/log?since=' + (since || 0), 4000);
        const bad = (log.lines || [])
            .map(l => (typeof l === 'string' ? l : (l.text || '')))
            .filter(t => /ERROR|WARNING/.test(t));
        if (!bad.length) return 'refused';

        // The LAST one, because a refusal may report a cause and then the
        // consequence, and the consequence is the sentence about what the
        // user just tried to do.
        return bad[bad.length - 1].replace(/^.*?(?:ERROR|WARNING)\s*-?\s*/, '');
    } catch (e) {
        return 'refused';
    }
}

// Tell the application what this applet is doing, so the tree can refuse to
// delete what is under the hand.  Fire and forget -- it is a notification,
// and a lost one costs a stale grey-out rather than a lost edit.
// THE VERSION OUR OWN PUBLISH PRODUCED.  A /state older than that is a
// document that has not heard about this edit yet, and obeying it would
// mean abandoning an edit because of a report written before it started.
let publishedVersion = -1;

async function publishMode() {
    let args = mode;
    if (target) args += ' ' + (target.sub || target.region);
    if (dirty)  args += ' dirty';
    const r = await postEdit('edit', args);
    if (r && r.version) publishedVersion = r.version;
}


// ============================================================================
// The model, as the applet sees it
// ============================================================================

function regionById(id) {
    return (cmState && cmState.regions || []).find(r => r.id === id) || null;
}

function nodeById(id) {
    // A region or a subregion at any depth, plus its root.
    for (const r of (cmState && cmState.regions || [])) {
        if (r.id === id) return { root: r, node: r };
        const found = findSub(r, id);
        if (found) return { root: r, node: found };
    }
    return null;
}

function findSub(reg, id) {
    for (const s of (reg.subregions || [])) {
        if (s.id === id) return s;
        const deeper = findSub(s, id);
        if (deeper) return deeper;
    }
    return null;
}

function parentOf(reg, id) {
    for (const s of (reg.subregions || [])) {
        if (s.id === id) return reg;
        const deeper = parentOf(s, id);
        if (deeper) return deeper;
    }
    return null;
}

// The level an object's geometry quantises at: zauthor for a region, zmax
// for a subregion.  Falls back to the set's zauthor when nothing is chosen.
function snapLevelFor(node) {
    if (node && node.zauthor !== undefined) return node.zauthor;
    if (node && node.zmax !== undefined)    return node.zmax;
    const first = (cmState && cmState.regions || [])[0];
    return first && first.zauthor !== undefined ? first.zauthor : 15;
}


// ============================================================================
// Hit testing
// ============================================================================
// The target is the polygon whose FILLED AREA is under the pointer, innermost
// first.  Not the outline -- hitting a one-pixel line with a mouse is a game.

function pointInRing(lng, lat, ring) {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        const xi = ring[i][0], yi = ring[i][1];
        const xj = ring[j][0], yj = ring[j][1];
        if (((yi > lat) !== (yj > lat)) &&
            (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) inside = !inside;
    }
    return inside;
}

function hitsNode(node, lng, lat) {
    return (node.polygons || []).some(p => pointInRing(lng, lat, p));
}

// Deepest first, so a subregion wins over the parent that contains it.
// The PATH rides along because it is how every consumer in the application
// keys a node -- 'Bocas/Popa00/Dock'. An id is unique within a region but
// says nothing across regions, and the probe addresses a subregion by path.
// THE PARENT RIDES ALONG TOO, because a subregion's BAND is defined against
// it - a subregion carries only a zmax and its band starts where its parent's
// zmax leaves off - and a node cannot say that about itself. The walk already
// knows it; nothing else can work it out afterwards without re-walking.
function hitChain(lng, lat) {
    const chain = [];
    const walk = (node, root, path, parent) => {
        if (!hitsNode(node, lng, lat)) return;
        for (const s of (node.subregions || []))
            walk(s, root, path + '/' + s.id, node);
        chain.push({ root: root, node: node, path: path, parent: parent });
    };
    for (const r of (cmState && cmState.regions || [])) walk(r, r, r.id, null);
    return chain;
}

let lastHitKey  = '';
let lastHitIdx  = 0;
let lastHitTime = 0;

const CYCLE_MS = 2500;

// THE OUTWARD WALK IS A CONSECUTIVE-CLICK GESTURE, not a position the map
// remembers.  Left un-reset it advanced across separate interactions: open a
// subregion's menu, edit it, cancel, right-click the same spot again, and the
// second click stepped out to the PARENT - so the menu named one object and
// the edit landed on another whose vertices were off screen.
//
// It is reset by anything that means "I am done with that click": choosing a
// menu item, moving the map, or simply waiting.
function resetHitCycle() {
    lastHitKey  = '';
    lastHitIdx  = 0;
    lastHitTime = 0;
}

function hitAt(latlng) {
    const chain = hitChain(latlng.lng, latlng.lat);
    if (!chain.length) { resetHitCycle(); return null; }

    const key  = chain.map(c => c.node.id).join('/');
    const now  = Date.now();
    const same = (key === lastHitKey) && (now - lastHitTime < CYCLE_MS);

    lastHitIdx  = same ? (lastHitIdx + 1) % chain.length : 0;
    lastHitKey  = key;
    lastHitTime = now;
    return chain[lastHitIdx];
}


// ============================================================================
// Snap to grid
// ============================================================================

const GRID_KEY = 'chartMaker.grid';
let gridOn = (localStorage.getItem(GRID_KEY) === 'on');   // defaults OFF
let gridLevel = 15;
let gridShown = 15;

function lngToTileX(lng, z) { return (lng + 180) / 360 * Math.pow(2, z); }
function latToTileY(lat, z) {
    const r = lat * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * Math.pow(2, z);
}
function tileXToLng(x, z) { return x / Math.pow(2, z) * 360 - 180; }
function tileYToLat(y, z) {
    const t = Math.PI - 2 * Math.PI * y / Math.pow(2, z);
    return 180 / Math.PI * Math.atan(0.5 * (Math.exp(t) - Math.exp(-t)));
}

// SNAPPING IS IN TILE COORDINATES, NEVER IN PIXELS.  The answer depends only
// on an integer and a level, so it is identical at any map zoom, in any
// window, and in either of two regions -- which is what makes two vertices
// on the same intersection identical to the last bit rather than merely
// close.  Snap in screen space and a vertex drifts every time it is
// re-dragged at a different zoom.
// Held so that a DRAG can honour it too.  Leaflet's marker drag events do not
// carry the original mouse event, so the modifier has to be tracked rather
// than read off the event.
let altDown = false;
document.addEventListener('keydown', e => { if (e.key === 'Alt') altDown = true; });
document.addEventListener('keyup',   e => { if (e.key === 'Alt') altDown = false; });
window.addEventListener('blur', () => { altDown = false; });

function snap(latlng, suspend) {
    if (!gridOn || suspend || altDown) return latlng;
    const z = gridLevel;
    const x = Math.round(lngToTileX(latlng.lng, z));
    const y = Math.round(latToTileY(latlng.lat, z));
    return L.latLng(tileYToLat(y, z), tileXToLng(x, z));
}

// SPACING OF THE DOTS ON SCREEN, in pixels, for a grid level at a map zoom.
// A 256px tile at level L holds 2^(L-z) tiles' worth of intersections when the
// map is at zoom z.
function dotPitch(level, z) { return 256 * Math.pow(2, z - level); }

// 64px is the density that was judged right by eye: the z15 grid at map z13 and
// the z18 grid at map z16 are both exactly this, and both look right.  32px (z15
// at z12) is busy and 16px (z15 at z11) obscures the imagery.
const MIN_DOT_PITCH = 64;

const GridDots = L.GridLayer.extend({
    createTile: function (coords) {
        const tile = document.createElement('canvas');
        const size = this.getTileSize();
        tile.width = size.x; tile.height = size.y;
        const ctx = tile.getContext('2d');

        // Grid pitch in pixels for the level being shown.  Powers of two, so
        // showing every Nth dot of level L IS the grid of a coarser level --
        // every dot drawn is still a real level-L intersection.
        let step = size.x / Math.pow(2, gridShown - coords.z);
        if (!isFinite(step) || step < 2) return tile;

        ctx.fillStyle = '#9a9a9a';
        for (let px = 0; px < size.x + 0.5; px += step) {
            for (let py = 0; py < size.y + 0.5; py += step) {
                ctx.fillRect(Math.round(px), Math.round(py), 2, 2);
            }
        }
        return tile;
    },
});

let gridLayer = null;

function updateGrid() {
    const sel = selectedNode();
    gridLevel = snapLevelFor(sel ? sel.node : null);

    // Thin the DISPLAY, never the grid.  The pitch on SCREEN is what decides,
    // not the level: dots closer together than MIN_DOT_PITCH stop reading as a
    // reference and start reading as a haze over the imagery, so a coarser
    // level is drawn instead -- and because the levels are powers of two, every
    // dot still drawn is a real intersection of the snap level.
    const z = Math.round(map.getZoom());
    gridShown = gridLevel;
    while (gridShown > z && dotPitch(gridShown, z) < MIN_DOT_PITCH) gridShown--;

    if (gridLayer) { map.removeLayer(gridLayer); gridLayer = null; }
    if (gridOn && gridShown >= z - 8) {
        gridLayer = new GridDots({ pane: 'overlayPane' });
        gridLayer.addTo(map);
        gridLayer.bringToBack();
    }
    drawGridRow();
}

// The grid is a palette row: a checkbox, the word, and the level it snaps to
// in the value column.  It has to be reachable mid-edit - the grid is wanted
// for one vertex and in the way for the next - and the right-click menu that
// also offers it is not available then, the pointer being busy with the
// polygon.
//
// The level is the SNAP level, not the level being drawn.  Which dots were
// dropped to keep them readable is the display's own business, and every dot
// on screen is an intersection of the level named here either way.
//
// IT IS SHOWN WHETHER THE GRID IS ON OR OFF, and it goes on tracking the
// selection either way.  The level is a property of what is selected, not of
// the switch, and watching it move while the dots are off is how the two
// stop being confused for each other - the dots thin out with the view, this
// number does not.
let gridRow = null;

function drawGridRow() {
    if (!gridRow)
        gridRow = cmPaletteRow('grid', 'grid',
            { checked: gridOn, onToggle: toggleGrid });

    gridRow.box.checked = gridOn;
    gridRow.value.textContent = 'z' + gridLevel;
    gridRow.row.title = gridOn ?
        'snapping to z' + gridLevel :
        'snap to grid is off - z' + gridLevel + ' is the level it would use';
}

function toggleGrid() {
    gridOn = !gridOn;
    localStorage.setItem(GRID_KEY, gridOn ? 'on' : 'off');
    updateGrid();
}


// ============================================================================
// Selection
// ============================================================================

function selectedNode() {
    const sel = cmState && cmState.selection;
    if (!sel || !sel.region) return null;
    const id = sel.sub || sel.region;
    return nodeById(id);
}

// WHAT THIS APPLET ASKED FOR, so that what arrives back can be told apart
// from what somebody else asked for.  There is no field in /state saying
// where a selection came from, and there should not be - the model records
// what is selected, not who did it.  Remembering the one we sent is enough
// to answer the only question anybody has: was this mine?
let sentSelKey = '';

// WHAT WAS SELECTED WHEN THIS PAGE LAST HAD ONE, remembered beside the view
// it was looking at.  Without it, a page load cannot tell "the tree moved
// the selection while I was closed" from "this is the object I was already
// looking at", and it has to refuse to act on either - which quietly makes
// reopening the browser the one thing autozoom never sees.
//
// With it, opening a page is not a special case at all: the same
// foreign-change rule runs, against what this browser last knew.
//
// null means no memory - a fresh browser or cleared storage - and that is
// deliberately NOT treated as a change.  There is no view to preserve
// either, so fitRegionsIfUnset has already put the regions on screen.

const SEL_KEY = 'chartMaker.selection';

let seenSelKey = (function () {
    try {
        const v = localStorage.getItem(SEL_KEY);
        return v === null ? null : v;
    } catch (e) {
        return null;
    }
})();

function rememberSelKey(key) {
    seenSelKey = key;
    try {
        localStorage.setItem(SEL_KEY, key);
    } catch (e) {
        // Private browsing, a full quota, a policy - none of it is worth
        // breaking the map over.  The selection simply is not remembered.
    }
}

function selKey(region, sub) {
    return (region || '') + '/' + (sub || '');
}

async function selectId(id) {
    const hit = id ? nodeById(id) : null;
    sentSelKey = hit ?
        selKey(hit.root.id, hit.node === hit.root ? '' : hit.node.id) : '';

    const r = await postEdit('select', id || 'none');
    if (!r.ok) banner(await refusalText(r.since), true);
}


// ============================================================================
// Autozoom
// ============================================================================
// FRAMES WHAT WAS JUST SELECTED, and only when the selection came from
// somewhere else.  Zooming to an object the user just clicked on the map
// would move the ground out from under the click that chose it; arriving
// from the tree, where there is no map to lose your place on, it is the
// whole point - the object is put on screen without hunting for it.
//
// Foreign means "not the selection this applet sent", which also covers a
// select from the console or /api/command.  Those are somebody deliberately
// naming an object, so framing it is right there too.

const AUTOZOOM_KEY = 'chartMaker.autozoom';
let autoZoom = (localStorage.getItem(AUTOZOOM_KEY) !== 'off');   // defaults ON
let autoZoomRow = null;

function drawAutoZoomRow() {
    if (!autoZoomRow)
        autoZoomRow = cmPaletteRow('autozoom', 'autozoom',
            { checked: autoZoom, onToggle: toggleAutoZoom });
    autoZoomRow.box.checked = autoZoom;
    autoZoomRow.row.title =
        'frame a region or subregion when it is selected in the tree';
}

function toggleAutoZoom() {
    autoZoom = !autoZoom;
    localStorage.setItem(AUTOZOOM_KEY, autoZoom ? 'on' : 'off');
    drawAutoZoomRow();
}

function zoomToSelection() {
    const sel = selectedNode();
    if (!sel) return;

    // THE OBJECT'S OWN POLYGONS, not its subregions'.  A subregion lies
    // within its parent, so including them would change nothing except in
    // the one case where geometry has drifted outside - and framing a
    // containment error as if it were intended is not a favour.

    const pts = [];
    (sel.node.polygons || []).forEach(p => p.forEach(q => pts.push([q[1], q[0]])));
    if (!pts.length) return;

    // Never deeper than the object is built to.  A small subregion would
    // otherwise be framed at a zoom no build ever holds imagery for.
    map.fitBounds(L.latLngBounds(pts), {
        padding: [40, 40],
        maxZoom: sel.node.zmax !== undefined ? sel.node.zmax : undefined,
    });
}

function onSelectionChanged(state) {
    const key = selKey(state.selection && state.selection.region,
                       state.selection && state.selection.sub);

    // A browser with no memory of a selection has nothing to compare
    // against, so this is not a change - it is the first thing it ever saw.
    if (seenSelKey === null) { rememberSelKey(key); return; }
    if (key === seenSelKey) return;

    // ONE SHOT, CONSUMED HERE.  sentSelKey answers "did I ask for this?",
    // which is a question about the change that just arrived and about
    // nothing after it.  Left standing, it becomes a permanent claim on
    // that object: the applet selects a subregion once by clicking it,
    // and from then on choosing that same subregion in the tree looks
    // like the applet's own doing, so it is never framed again.  Every
    // other object still worked, which is what made it look like one
    // broken subregion rather than a rule with a leak in it.

    const foreign = (key !== sentSelKey);
    sentSelKey = '';
    rememberSelKey(key);
    if (foreign && autoZoom) zoomToSelection();
}


// ============================================================================
// The context menu
// ============================================================================

const menuDiv = document.createElement('div');
menuDiv.id = 'cm-ctx';
menuDiv.style.display = 'none';
document.body.appendChild(menuDiv);

function hideMenu() { menuDiv.style.display = 'none'; }

function showMenu(x, y, items, title) {
    menuDiv.innerHTML = '';
    if (title) {
        const h = document.createElement('div');
        h.className = 'cm-ctx-title';
        h.textContent = title;
        menuDiv.appendChild(h);
    }
    for (const it of items) {
        if (it === '-') {
            const s = document.createElement('div');
            s.className = 'cm-ctx-sep';
            menuDiv.appendChild(s);
            continue;
        }
        const b = document.createElement('button');
        b.textContent = it.label;
        b.disabled = !!it.disabled;

        // A GREYED ITEM SAYS WHY IT IS GREY.  An item that is simply dead
        // is the one state that explains nothing, and the note costs a
        // span - so anything switched off here has to hand one over.
        if (it.note) {
            const n = document.createElement('span');
            n.className = 'cm-ctx-note';
            n.textContent = it.note;
            b.appendChild(n);
        }

        // Choosing an item ends the cycle: the next right-click here starts
        // at the innermost object again rather than stepping outward.
        b.onclick = () => { hideMenu(); resetHitCycle(); it.fn(); };
        menuDiv.appendChild(b);
    }
    // IT IS MEASURED BEFORE IT IS PLACED.  The menu is shown at the origin,
    // measured, and then moved, all in one task, so the browser never paints
    // the uncorrected position and there is no jump to see.
    //
    // A menu that would run off the BOTTOM flips UP from the click, the way a
    // native menu does, rather than being slid up the screen away from the
    // cursor.  Clamping is the fallback for when flipping does not fit
    // either, and a menu taller than the window scrolls inside itself - the
    // css caps its height - rather than losing its last items off the edge.

    menuDiv.style.left = '0px';
    menuDiv.style.top  = '0px';
    menuDiv.style.display = 'block';

    const margin = 4;
    const vw = document.documentElement.clientWidth;
    const vh = document.documentElement.clientHeight;
    const mw = menuDiv.offsetWidth;
    const mh = menuDiv.offsetHeight;

    let mx = x;
    let my = y;
    if (my + mh > vh - margin)
        my = (y - mh >= margin) ? y - mh : Math.max(margin, vh - mh - margin);
    if (mx + mw > vw - margin)
        mx = (x - mw >= margin) ? x - mw : Math.max(margin, vw - mw - margin);

    menuDiv.style.left = mx + 'px';
    menuDiv.style.top  = my + 'px';
}

function gridItem() {
    return { label: gridOn ? 'Snap to grid: on' : 'Snap to grid: off',
             fn: () => toggleGrid() };
}

// PROBING THE AREA UNDER THE CURSOR, and it ASKS which source.
//
// The right-click says WHERE. It does not say what to probe, and using the
// source that happens to be displayed was wrong: the source is the SUBJECT of
// a probe, and the whole reason the feature exists is to compare services you
// are not currently looking at. Picking one for the user silently answered the
// only question that matters.
//
// So the item opens a dialog with the same two things the application's own
// dialog asks - a source, and a zoom range - and the polygon is the one thing
// it does not have to ask about, because that is what was pointed at.
//
// TWO ENTRIES OVER A SUBREGION, and they are not the same question. Probing
// the detail area alone is a far more intimate answer than probing the whole
// region around it, which is exactly the judgement somebody siting one is
// making. Over a plain region there is only the one.
//
// AVAILABLE WHILE A PROBE IS ALREADY SHOWING. The mode HOLDS results from
// several sources at once so they can be compared, so adding to what is on
// screen is the ordinary thing rather than a special case.

// NOT 'probeSources' - cmProbe.js holds a top-level `let probeSources` for
// the ones already probed, and a function and a let of the same name in two
// scripts sharing the global scope resolve to the let, which is an array and
// is not callable.
function probeSourceList() {
    return ((cmState && cmState.sources) || []).slice();
}

function probePrefZ(which, fallback) {
    const p = (cmState && cmState.probe) || {};
    const v = p[which];
    return (typeof v === 'number' && v >= 0 && v <= 24) ? v : fallback;
}

// WHAT THE LAST PROBE ACCEPTED, for as long as this page is open. Comparing
// several services over one area means opening this repeatedly, and
// re-picking from the top of the list each time is the friction that stops
// somebody running the third and fourth probe. Not persisted: it is about
// what you are doing now, not about what you meant last month.
//
// The application keeps its own, in w_probecfg. Two surfaces, two memories,
// deliberately - they are separate conversations and neither is the other's
// state to change.
let probeLastSource = '';
let probeLastZ      = null;

// THE NODE'S OWN BAND, which is the range about to be asked of a source.
//
// A region is its zmin..zmax. A subregion adds a band ABOVE its parent, so
// it starts at the parent's zmax + 1 and runs to its own zmax - that is the
// region model's own definition and the reason a subregion carries only a
// zmax. Everything below it is already painted by the thing it sits in.
//
// Falls back to the last accepted range, then to preferences, so a shape
// that has not said anything still opens on something sensible.
function probeBandFor(hit) {
    if (hit && hit.node && hit.root) {
        const lo = (hit.node === hit.root) ? hit.root.zmin
                                           : (hit.parent ? hit.parent.zmax + 1 : null);
        const hi = hit.node.zmax;
        if (typeof lo === 'number' && typeof hi === 'number' && lo <= hi)
            return { zmin: lo, zmax: hi, fromNode: true };
    }
    if (probeLastZ) return { zmin: probeLastZ.zmin, zmax: probeLastZ.zmax };
    return { zmin: probePrefZ('zmin', 10), zmax: probePrefZ('zmax', 22) };
}

function probeDialog(scope, label, hit) {
    const srcs = probeSourceList();
    if (!srcs.length) { banner('no sources are installed', true); return; }

    const byId = {};
    srcs.forEach(s => { byId[s.id] = s; });

    // THE ONE PROBED LAST, then the one being displayed. A rescan can drop a
    // source between two probes, so the remembered id is looked up rather
    // than trusted.
    const active = (window.cmActiveSourceId && cmActiveSourceId()) || srcs[0].id;
    const start  = byId[probeLastSource] || byId[active] || srcs[0];

    const band = probeBandFor(hit);

    buildDialog('Probe over ' + label, [
        { key: 'source', label: 'source', value: start.id,
          choices: srcs.map(s => ({ value: s.id,
              label: s.id + '  (z' + s.zoom_min + '-' + s.zoom_max + ')' })) },
        // FROM THE NODE, NOT FROM THE SOURCE. Opening at what the .tsd
        // declares is opening at the one number a probe exists not to
        // trust. Opening at the levels the node will be BUILT at is the
        // range the question is actually about.
        // WHERE THE RANGE CAME FROM, said out loud. A number that appeared
        // by itself is one nobody trusts or corrects; one that says it is
        // the node's own band is one you can agree with at a glance - and
        // it stops saying so the moment you change it.
        { key: 'zmin', label: 'from z', value: band.zmin,
          numeric: true, size: 4,
          check: v => (band.fromNode && +v.zmin === band.zmin &&
                       +v.zmax === band.zmax) ?
              'the levels ' + label + ' is built at' : '' },
        { key: 'zmax', label: 'to z', value: band.zmax,
          numeric: true, size: 4,
          // THE FILE'S RANGE IS NOT A CEILING. A .tsd can hide depth the
          // service actually has, and finding that out is half the reason
          // to probe at all - so a range past what it declares is asked
          // anyway, and the dialog says that is what will happen rather
          // than implying a limit that does not exist.
          check: v => {
              const s = byId[v.source];
              if (!s) return '';
              return (+v.zmin < s.zoom_min || +v.zmax > s.zoom_max) ?
                  'past the declared z' + s.zoom_min + '-' + s.zoom_max +
                  ' - asked anyway' : '';
          } },
    ], async v => {
        // REMEMBERED ON ACCEPT, not on every keystroke: what was accepted is
        // what was meant, and a cancelled dialog said nothing.
        probeLastSource = v.source;
        probeLastZ      = { zmin: +v.zmin, zmax: +v.zmax };

        const r = await postEdit('sample',
            v.source + ' ' + scope + ' ' + v.zmin + ' ' + v.zmax);
        if (!r.ok) banner(await refusalText(r.since), true);
    }, { okLabel: 'Probe' });
}

function probeItemsFor(hit) {
    const items = [];
    if (hit.node !== hit.root)
        items.push({ label: 'Probe ' + hit.node.id + '...',
                     fn: () => probeDialog(hit.path || hit.node.id, hit.node.id,
                                           hit) });

    // THE ROOT IS ITS OWN HIT for band purposes - probing the whole region
    // asks about the region's own zmin..zmax, not about the subregion that
    // happened to be under the cursor.
    items.push({ label: 'Probe ' + hit.root.id + '...',
                 fn: () => probeDialog(hit.root.id, hit.root.id,
                                       { node: hit.root, root: hit.root }) });
    return items;
}

map.on('contextmenu', ev => {
    // A MODE OWNS THE RIGHT BUTTON.  While drawing or shaping, the only
    // right-click that means anything is the one on a vertex handle, which
    // has its own handler - so the object menu stays out of the way rather
    // than offering to delete the thing under the user's hand.
    if (mode !== MODE_BROWSE) return;

    const ev2 = ev.originalEvent;
    const hit = hitAt(ev.latlng);

    if (!hit) {
        // A REGION HAS TO GO IN A REGION SET, and with none open there is
        // nowhere to put one.  The item stays in the menu and says so
        // rather than vanishing: a menu that is empty except for 'grid'
        // teaches nothing, and "open a set first" is the whole answer.
        //
        // WHICH IS A LEAFLET RULE AND NOT THE MENU BAR'S.  Fetch and Build
        // stay enabled in the application because what is wrong with them
        // is a list of regions and a greyed item cannot recite one.  Here
        // the reason is one sentence and there is nothing to enumerate.
        const haveSet = !!(cmState && cmState.active_set);
        showMenu(ev2.clientX, ev2.clientY, [
            { label: 'Create Region...',
              disabled: !haveSet,
              note: haveSet ? '' : 'no region set is open',
              fn: () => newRegionDialog(ev.latlng) },
            '-',
            gridItem(),
        ]);
        return;
    }

    const isSub = hit.node !== hit.root;
    const title = isSub ? hit.node.id + '  (sub of ' + hit.root.id + ')' : hit.node.id;

    // SELECTED WHEN AN ACTION IS CHOSEN, not on the right-click itself.
    // Selecting bumps the state, and a bump arriving between the menu
    // opening and an item being clicked replaced the model underneath the
    // hit that the item had already captured.

    showMenu(ev2.clientX, ev2.clientY, [
        { label: 'Edit Polygon',
          fn: () => { selectId(hit.node.id); startShape(hit, ev.latlng); } },
        { label: 'Add Polygon',
          fn: () => { selectId(hit.node.id); startDraw(hit, true); } },
        { label: 'Add Subregion...',
          fn: () => { selectId(hit.node.id); newSubDialog(hit); } },
        { label: 'Properties...',
          fn: () => { selectId(hit.node.id); propertiesDialog(hit); } },
        '-',
        { label: 'Delete Polygon',
          fn: () => deletePolygonAt(hit, ev.latlng) },
        { label: 'Delete ' + hit.node.id + '...',
          fn: () => deleteNode(hit) },
        '-',
        ...probeItemsFor(hit),
        '-',
        gridItem(),
    ], title);
});

map.on('click', hideMenu);
map.on('movestart', () => { hideMenu(); resetHitCycle(); });


// ============================================================================
// The bar
// ============================================================================

const barDiv = document.createElement('div');
barDiv.id = 'cm-bar';
barDiv.style.display = 'none';
document.body.appendChild(barDiv);

function hideBar() { barDiv.style.display = 'none'; }

function showBar(text, buttons) {
    barDiv.innerHTML = '';
    const hint = document.createElement('span');
    hint.className = 'cm-bar-hint';
    hint.textContent = text;
    barDiv.appendChild(hint);
    for (const b of buttons) {
        const el = document.createElement('button');
        el.textContent = b.label;
        el.disabled = !!b.disabled;
        if (b.cls) el.className = b.cls;
        el.onclick = b.fn;
        barDiv.appendChild(el);
    }
    barDiv.style.display = 'flex';
}

// THE APPLICATION'S ANSWER, PUT WHERE SOMEBODY WILL SEE IT.
//
// This wrote into the mode bar's hint and, finding none, wrote to the
// BROWSER CONSOLE - so every refusal raised from browse mode was invisible.
// Create Region with no region set open was the case that showed it: the
// model refused correctly, this asked for the reason correctly, and the
// reason went somewhere nobody has open.  Add Subregion, Properties and
// Delete all took the same silent path.
//
// So: inside a mode, it replaces that mode's hint, which is right - the bar
// is already the place that mode is talking from.  Outside one, it RAISES
// the bar with the message and an OK, because a refusal that dismisses
// itself is a refusal that can be missed.
function banner(text, isError) {
    const hint = barDiv.querySelector('.cm-bar-hint');
    if (hint && barDiv.style.display !== 'none') {
        hint.textContent = text;
        hint.style.color = isError ? '#ff6b60' : '';
        return;
    }
    showBar(text, [{ label: 'OK', fn: hideBar }]);
    const raised = barDiv.querySelector('.cm-bar-hint');
    if (raised) {
        raised.style.color = isError ? '#ff6b60' : '';
        // A refusal is a sentence, not a label.  The mode hint is one line
        // with an ellipsis, which would cut this off exactly where the
        // reason is.
        raised.style.whiteSpace = 'normal';
    }
}


// ============================================================================
// Dialogs
// ============================================================================

const dlgDiv = document.createElement('div');
dlgDiv.id = 'cm-dlg';
dlgDiv.style.display = 'none';
document.body.appendChild(dlgDiv);

function hideDialog() { dlgDiv.style.display = 'none'; }

function suggestId(name) {
    if (/^[A-Za-z0-9]+$/.test(name)) return name;
    return (name.match(/[A-Za-z0-9]+/g) || [])
        .map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join('');
}

function idTaken(id) {
    return !!nodeById(id);
}

function buildDialog(title, fields, onOk, opts) {
    opts = opts || {};
    dlgDiv.innerHTML = '';
    const h = document.createElement('div');
    h.className = 'cm-dlg-title';
    h.textContent = title;
    dlgDiv.appendChild(h);

    const inputs = {};
    const notes  = {};
    for (const f of fields) {
        const row = document.createElement('div');
        row.className = 'cm-dlg-row';
        const lab = document.createElement('label');
        lab.textContent = f.label;

        // A CHOICE IS A SELECT, and it is the same field otherwise: it has a
        // key, it has a value, and it revalidates.  Added for the probe,
        // which has to name a SOURCE and cannot ask anybody to type an id.
        let inp;
        if (f.choices) {
            inp = document.createElement('select');
            for (const c of f.choices) {
                const o = document.createElement('option');
                o.value = c.value; o.textContent = c.label;
                inp.appendChild(o);
            }
            inp.value = f.value;
        } else {
            inp = document.createElement('input');
            inp.value = f.value;
            inp.size  = f.size || 18;
            if (f.numeric) { inp.type = 'number'; inp.min = 0; inp.max = 24; }
        }
        const note = document.createElement('span');
        note.className = 'cm-dlg-note';
        row.appendChild(lab); row.appendChild(inp); row.appendChild(note);
        dlgDiv.appendChild(row);
        inputs[f.key] = inp;
        notes[f.key]  = note;
        inp.oninput  = () => revalidate();
        inp.onchange = () => revalidate();
    }

    const btns = document.createElement('div');
    btns.className = 'cm-dlg-btns';
    const cancel = document.createElement('button');
    cancel.textContent = 'Cancel';
    cancel.onclick = hideDialog;
    const okBtn = document.createElement('button');
    okBtn.textContent = opts.okLabel || 'Draw';
    okBtn.className = 'cm-btn-go';
    btns.appendChild(cancel); btns.appendChild(okBtn);
    dlgDiv.appendChild(btns);

    function values() {
        const v = {};
        for (const k in inputs) v[k] = inputs[k].value.trim();
        return v;
    }

    // Everything the validator would say, said as it is typed.  Not a rule
    // of its own -- the same rule, earlier.
    function revalidate() {
        const v = values();
        let bad = false;
        if (inputs.id) {
            // Only SUGGEST from the name while creating.  Editing an existing
            // object must never quietly rewrite its id because its name was
            // touched - the id is the file name and the output file stem.
            if (inputs.name && !inputs.id.dataset.touched && !opts.editing)
                inputs.id.value = suggestId(v.name);
            const id = inputs.id.value.trim();
            if (!/^[A-Za-z0-9]+$/.test(id)) {
                notes.id.textContent = 'letters and digits only'; bad = true;
            } else if (idTaken(id) && id !== opts.editing) {
                notes.id.textContent = 'already used in this set'; bad = true;
            } else {
                notes.id.textContent = 'ok';
            }
        }
        if (inputs.name && !v.name) bad = true;
        for (const f of fields) {
            if (!f.check) continue;
            const msg = f.check(v);
            notes[f.key].textContent = msg || '';
        }
        okBtn.disabled = bad;
        return !bad;
    }
    if (inputs.id) inputs.id.oninput = () => {
        inputs.id.dataset.touched = '1'; revalidate();
    };

    okBtn.onclick = () => { if (revalidate()) { hideDialog(); onOk(values()); } };
    revalidate();
    dlgDiv.style.display = 'block';
    if (inputs.name) inputs.name.focus();
}

function newRegionDialog(latlng) {
    const sib = (cmState && cmState.regions || [])[0];
    const za = sib && sib.zauthor !== undefined ? sib.zauthor : 15;
    const zn = sib && sib.zmin    !== undefined ? sib.zmin    : 10;
    const zx = sib && sib.zmax    !== undefined ? sib.zmax    : za + 1;

    buildDialog('New region', [
        { key: 'name',    label: 'name',    value: '' },
        { key: 'id',      label: 'id',      value: '', size: 12 },
        { key: 'zauthor', label: 'zauthor', value: za, numeric: true, size: 4,
          check: v => (sib && +v.zauthor !== za) ?
              'differs from this set (' + za + ')' : 'agrees with this set' },
        { key: 'zmin',    label: 'zmin',    value: zn, numeric: true, size: 4 },
        { key: 'zmax',    label: 'zmax',    value: zx, numeric: true, size: 4 },
    ], async v => {
        const r = await postEdit('region',
            'new ' + v.id + ' ' + v.zauthor + ' ' + v.zmin + ' ' + v.zmax +
            ' ' + v.name);
        if (!r.ok) { banner(await refusalText(r.since), true); return; }
        pendingDraw = v.id;
    });
}

function newSubDialog(hit) {
    const parentZmax = hit.node.zmax;
    buildDialog('New subregion of ' + hit.node.id, [
        { key: 'name', label: 'name', value: '' },
        { key: 'id',   label: 'id',   value: '', size: 12 },
        { key: 'zmax', label: 'zmax', value: parentZmax + 2, numeric: true, size: 4,
          check: v => (+v.zmax <= parentZmax) ?
              'at or below the parent - contributes nothing' :
              'band z' + (parentZmax + 1) + '-' + v.zmax },
    ], async v => {
        const r = await postEdit('subregion',
            'new ' + hit.node.id + ' ' + v.zmax + ' ' + v.name);
        if (!r.ok) { banner(await refusalText(r.since), true); return; }
        pendingDraw = v.id;
    });
}

// The object was just created; draw it as soon as the next /state shows it.
let pendingDraw = null;


// A REGION AND A SUBREGION GET DIFFERENT FIELDS, because a subregion has
// zmax and no authored level - it never cuts a reveal contour, so there is
// nothing else on it to set.
//
// Each field maps to its own verb, and they are sent in sequence stopping at
// the first refusal.  There is no compound 'update this object' verb, and
// inventing one for the applet's convenience would be a second way to write
// the model.
function propertiesDialog(hit) {
    const isSub = hit.node !== hit.root;
    const n     = hit.node;

    const fields = isSub ?
        [ { key: 'zmax', label: 'zmax', value: n.zmax, numeric: true, size: 4,
            check: v => {
                const p = parentOf(hit.root, n.id) || hit.root;
                return (+v.zmax <= p.zmax) ?
                    'at or below ' + p.id + ' - contributes nothing' :
                    'band z' + (p.zmax + 1) + '-' + v.zmax;
            } } ] :
        [ { key: 'name',    label: 'name',    value: n.name },
          { key: 'id',      label: 'id',      value: n.id, size: 12 },
          { key: 'zauthor', label: 'zauthor', value: n.zauthor, numeric: true, size: 4 },
          { key: 'zmin',    label: 'zmin',    value: n.zmin,    numeric: true, size: 4 },
          { key: 'zmax',    label: 'zmax',    value: n.zmax,    numeric: true, size: 4 } ];

    buildDialog(isSub ? n.id + '  (subregion of ' + hit.root.id + ')' : n.id,
        fields,
        async v => {
            const steps = [];
            if (isSub) {
                if (+v.zmax !== n.zmax)
                    steps.push(['region', 'zmax ' + hit.root.id + ' ' + v.zmax +
                                ' ' + n.id]);
            } else {
                if (v.name !== n.name)
                    steps.push(['region', 'rename ' + n.id + ' ' + v.name]);
                if (+v.zauthor !== n.zauthor)
                    steps.push(['region', 'zauthor ' + n.id + ' ' + v.zauthor]);
                if (+v.zmin !== n.zmin)
                    steps.push(['region', 'zmin ' + n.id + ' ' + v.zmin]);
                if (+v.zmax !== n.zmax)
                    steps.push(['region', 'zmax ' + n.id + ' ' + v.zmax]);

                // The id LAST, because every verb above names the object by
                // the id it still has.
                if (v.id !== n.id)
                    steps.push(['region', 'id ' + n.id + ' ' + v.id]);
            }
            for (const s of steps) {
                const r = await postEdit(s[0], s[1]);
                if (!r.ok) { banner(await refusalText(r.since), true); return; }
            }
        },
        { okLabel: 'Save', editing: isSub ? null : n.id });
}


// ============================================================================
// DRAW
// ============================================================================

function startDraw(hit, append) {
    target  = { region: hit.root.id, sub: hit.node === hit.root ? '' : hit.node.id };
    working = append ? (hit.node.polygons || []).map(p => p.map(q => [q[0], q[1]])) : [];
    drawPts = [];
    mode    = MODE_DRAW;
    dirty   = false;
    publishMode();
    redrawWork();
    drawBar();
    cmRedrawRegions();
}

function drawBar() {
    const n = drawPts ? drawPts.length : 0;
    showBar('drawing ' + (target.sub || target.region) + ' - ' + n +
            (n === 1 ? ' vertex' : ' vertices') + ' placed', [
        { label: 'Undo vertex', disabled: n === 0, fn: () => {
            drawPts.pop(); redrawWork(); drawBar(); } },
        { label: 'Close', disabled: n < 3, cls: 'cm-btn-go', fn: closeRing },
        { label: 'Cancel', fn: abandon },
    ]);
}

// A subregion's parent is a WALL.  A click outside places nothing, and the
// vertex is refused rather than moved -- relocating it would override where
// the pointer was, which is the one thing snapping never does.
function parentPolygons() {
    if (!target || !target.sub) return null;
    const root = regionById(target.region);
    if (!root) return null;
    const p = parentOf(root, target.sub);
    return p ? (p.polygons || []) : null;
}

function outsideParent(latlng) {
    const polys = parentPolygons();
    if (!polys || !polys.length) return false;
    return !polys.some(ring => pointInRing(latlng.lng, latlng.lat, ring));
}

map.on('click', ev => {
    // A CLICK IN BROWSE SELECTS WHAT IS UNDER IT - the innermost object,
    // the same answer the right-click menu gives, and nothing where there
    // is nothing.  Selection is not an edit: it costs nothing, commits
    // nothing, and the next click undoes it, which is why clicking open
    // water is allowed to clear it rather than being ignored.
    //
    // No hit cycling here.  Stepping outward is a gesture for choosing what
    // a MENU will act on; a click that quietly selects the parent because
    // it was the second one in the same spot would be a click that lies.
    if (mode === MODE_BROWSE) {
        const chain = hitChain(ev.latlng.lng, ev.latlng.lat);
        selectId(chain.length ? chain[0].node.id : '');
        return;
    }

    if (mode !== MODE_DRAW) return;
    const p = snap(ev.latlng, ev.originalEvent && ev.originalEvent.altKey);
    if (outsideParent(p)) {

        // A CLICK IS THE ONE CASE THAT STILL NEEDS WORDS.  Nothing appears
        // and nothing moves, so silence here would be indistinguishable
        // from a click the applet never received - unlike a drag, where the
        // outline stopping at the wall says it without any.
        //
        // AND HERE 'not placed' IS THE TRUE THING TO SAY, which it was not
        // on a drag: a click really did place nothing, whereas a dragged
        // vertex moved as far as it could and then stopped.  One message
        // was covering two different events.

        banner('outside ' + (parentName() || 'the parent') + ', not placed', true);
        return;
    }
    drawPts.push([p.lng, p.lat]);
    dirty = true;
    redrawWork();
    drawBar();
});

function parentName() {
    const root = regionById(target && target.region);
    if (!root || !target.sub) return '';
    const p = parentOf(root, target.sub);
    return p ? p.id : '';
}

map.on('dblclick', ev => { if (mode === MODE_DRAW && drawPts.length >= 3) closeRing(); });

function closeRing() {
    if (drawPts.length < 3) return;
    working.push(drawPts.slice());
    drawPts = null;
    mode    = MODE_SHAPE;
    target.poly = working.length - 1;
    dirty   = true;
    publishMode();
    redrawWork();
    shapeBar();
}


// ============================================================================
// SHAPE
// ============================================================================

function startShape(hit, latlng) {
    target  = { region: hit.root.id, sub: hit.node === hit.root ? '' : hit.node.id };
    working = (hit.node.polygons || []).map(p => p.map(q => [q[0], q[1]]));
    if (!working.length) { startDraw(hit, false); return; }

    // The polygon under the pointer, or the first one.
    target.poly = 0;
    for (let i = 0; i < working.length; i++) {
        if (pointInRing(latlng.lng, latlng.lat, working[i])) { target.poly = i; break; }
    }
    mode  = MODE_SHAPE;
    dirty = false;
    publishMode();
    redrawWork();
    shapeBar();
    cmRedrawRegions();
}

function shapeBar() {
    showBar((target.sub || target.region) +
        ' - drag a vertex, drag a midpoint to insert, right-click a vertex to delete', [
        { label: 'Delete Polygon', fn: deleteCurrentPolygon },
        { label: 'Confirm', cls: 'cm-btn-go', fn: commit },
        { label: 'Cancel', fn: abandon },
    ]);
}

function clearHandles() {
    for (const h of vtxHandles) map.removeLayer(h);
    for (const h of midHandles) map.removeLayer(h);
    vtxHandles = []; midHandles = [];
}

// Exposed so the shade switch can repaint an edit in flight - see map.js.
// It is safe with nothing being edited: the layer is simply cleared.
window.cmRedrawWork = redrawWork;

function redrawWork() {
    clearHandles();
    workLayer.clearLayers();
    if (!workLayer._map) workLayer.addTo(map);

    if (mode === MODE_DRAW) {
        const pts = drawPts.map(p => [p[1], p[0]]);
        if (pts.length > 1) L.polyline(pts, WORK_STYLE).addTo(workLayer);
        for (const p of pts) L.circleMarker(p, {
            radius: 4, color: '#fff', weight: 2, fillOpacity: 1 }).addTo(workLayer);
        return;
    }
    if (mode !== MODE_SHAPE || !working) return;

    working.forEach((ring, i) => {
        const pts = ring.map(p => [p[1], p[0]]);
        const current = (i === target.poly);
        const style = current ? WORK_STYLE :
            { color: '#ffffff', weight: 1, opacity: 0.4, fill: false };

        // FILLED, but only the current one, purely so it reads as the one being
        // worked on.  NOT interactive: the polygon must never eat a mouse press,
        // because a press on the map is a PAN, and panning to reach another part
        // of a large region is the commonest thing done during an edit.
        //
        // UNDER THE SAME SWITCH as the selection's own wash, because it is the
        // same wash on the same object - the thing being edited IS the thing
        // selected. Honouring the switch on one surface and not the other
        // would turn it off everywhere except where it is most in the way,
        // which is here, with somebody looking hard at the ground under a
        // vertex.
        const shade = !window.cmShadeSelection || window.cmShadeSelection();
        const poly = L.polygon(pts, Object.assign({ interactive: false }, style,
            (current && shade) ? { fill: true, fillOpacity: 0.08 } : {}));
        poly.addTo(workLayer);
    });

    const ring = working[target.poly] || [];
    // VERTICES SIT ABOVE MIDPOINTS.  On a short edge the two are close
    // enough that their boxes touch, and a press in the overlap has to go
    // to the vertex: moving one is far commoner than inserting one, and
    // an insert that should have been a move is a nuisance to undo.
    ring.forEach((p, i) => {
        const m = L.marker([p[1], p[0]],
            { icon: VTX_ICON, draggable: true, zIndexOffset: 1000 });
        m.on('drag',    e => moveVertex(i, e.target.getLatLng(), false));
        m.on('dragend', e => moveVertex(i, e.target.getLatLng(), true));
        m.on('contextmenu', e => { L.DomEvent.stop(e); deleteVertex(i); });
        m.addTo(map);
        vtxHandles.push(m);
    });
    ring.forEach((p, i) => {
        const q = ring[(i + 1) % ring.length];
        const mid = [ (p[1] + q[1]) / 2, (p[0] + q[0]) / 2 ];
        const m = L.marker(mid, { icon: MID_ICON, draggable: true });

        // THE VERTEX EXISTS THE MOMENT THE CIRCLE IS GRABBED, which is what
        // somebody watching the screen already believes.  Inserting it on
        // dragstart makes the rest of the gesture an ordinary vertex drag,
        // so the outline follows the cursor, the grid snap applies, and a
        // position outside the parent stops the outline at the last legal
        // place - none of which a midpoint used to do until the button came
        // up.  Until then the only thing that moved was Leaflet's own 11px
        // marker, so a grab that missed the circle looked exactly like a
        // grab that took.
        //
        // It is also LESS code than a preview would be: moveVertex already
        // does the snap, the parent test, the dirty flag, the live outline
        // and the full rebuild on the final event.
        //
        // mid is [lat,lng] for Leaflet; a ring holds [lng,lat].
        //
        // Every LATER midpoint's captured i is stale from the splice until
        // the dragend rebuilds them, which is why that rebuild has to stay
        // on the final event and not be optimised into the drag.

        m.on('dragstart', () => {
            working[target.poly].splice(i + 1, 0, [mid[1], mid[0]]);
            dirty = true;
        });
        m.on('drag',    e => moveVertex(i + 1, e.target.getLatLng(), false));
        m.on('dragend', e => moveVertex(i + 1, e.target.getLatLng(), true));
        m.addTo(map);
        midHandles.push(m);
    });
}

// A POLYGON IS NEVER MOVED AS A WHOLE - only its vertices are.  A polygon marks
// a place on the earth; translating it wholesale is not an edit anyone wants, and
// the gesture it would need (press inside the shape and drag) is the same gesture
// that pans the map, which is needed constantly while working across a region too
// large to see at once.  The pan wins.


function moveVertex(i, latlng, final) {
    const p = snap(latlng, false);
    if (outsideParent(p)) {

        // NO MESSAGE, BECAUSE THE OUTLINE ALREADY SAID IT.  The refused
        // position is never written, so the ring keeps its last legal
        // vertex and the shape simply stops at the boundary while the
        // cursor goes on - which reads as a wall, correctly, without
        // words.  It also said the wrong thing: "not moved" describes the
        // ring, and what a person sees is a vertex that moved as far as it
        // could.
        //
        // And banner() overwrites the mode hint in place without restoring
        // it, so one excursion outside used to replace "drag a vertex,
        // drag a midpoint to insert" with a red error for the rest of the
        // edit.

        if (final) redrawWork();
        return;
    }
    working[target.poly][i] = [p.lng, p.lat];
    dirty = true;
    if (final) { publishMode(); redrawWork(); shapeBar(); }
    else {
        workLayer.clearLayers();
        const pts = working[target.poly].map(q => [q[1], q[0]]);
        L.polygon(pts, WORK_STYLE).addTo(workLayer);
    }
}

// insertVertex is gone: a midpoint drag inserts on dragstart and is a
// vertex drag from there, so moveVertex is the only path that writes a
// vertex position.  See the midpoint handles in redrawWork.

function deleteVertex(i) {
    const ring = working[target.poly];
    if (ring.length <= 3) { banner('a polygon needs at least three vertices', true);
        return; }
    ring.splice(i, 1);
    dirty = true;
    publishMode();
    redrawWork();
}

function deleteCurrentPolygon() {
    working.splice(target.poly, 1);
    target.poly = 0;
    dirty = true;
    if (!working.length) { commit(); return; }
    publishMode();
    redrawWork();
    shapeBar();
}


// ============================================================================
// Commit and abandon
// ============================================================================

async function commit() {
    const args = 'geometry ' + target.region + (target.sub ? ' ' + target.sub : '');
    const r = await postEdit('region', args, working);
    if (!r.ok) {
        banner(await refusalText(r.since), true);
        return;                     // the local copy is kept, so nothing is lost
    }
    finishEdit();
}

function abandon() {
    finishEdit();
}

function finishEdit(quiet) {
    mode    = MODE_BROWSE;
    dirty   = false;
    target  = null;
    working = null;
    drawPts = null;
    clearHandles();
    workLayer.clearLayers();
    hideBar();

    // QUIET IS FOR AN EDIT THE APPLICATION ENDED.  It already knows -
    // either it published browse, or it is not there to be told - and
    // reporting a mode back to a document that just dictated it would be
    // an echo at best and a request to a dead server at worst.
    if (!quiet) publishMode();
    cmRedrawRegions();
}

document.addEventListener('keydown', ev => {
    if (ev.key === 'Escape') {
        if (menuDiv.style.display !== 'none') { hideMenu(); return; }
        if (dlgDiv.style.display  !== 'none') { hideDialog(); return; }
        if (mode !== MODE_BROWSE) abandon();
    } else if (ev.key === 'Enter') {
        if (mode === MODE_DRAW && drawPts.length >= 3) closeRing();
        else if (mode === MODE_SHAPE && dirty) commit();
    }
});


// ============================================================================
// Structural actions
// ============================================================================

async function deleteNode(hit) {
    const isSub = hit.node !== hit.root;
    const what  = isSub ? 'subregion ' + hit.node.id : 'region ' + hit.node.id;
    if (!confirm('Delete ' + what + '?')) return;
    const r = isSub ?
        await postEdit('subregion', 'delete ' + hit.root.id + ' ' + hit.node.id) :
        await postEdit('region',    'delete ' + hit.node.id);
    if (!r.ok) banner(await refusalText(r.since), true);
}

async function deletePolygonAt(hit, latlng) {
    const polys = (hit.node.polygons || []).map(p => p.map(q => [q[0], q[1]]));
    if (polys.length < 2) {
        if (!confirm('Delete the only polygon of ' + hit.node.id + '?')) return;
    }
    let idx = polys.findIndex(r => pointInRing(latlng.lng, latlng.lat, r));
    if (idx < 0) return;
    polys.splice(idx, 1);
    const args = 'geometry ' + hit.root.id +
        (hit.node === hit.root ? '' : ' ' + hit.node.id);
    const r = await postEdit('region', args, polys);
    if (!r.ok) banner(await refusalText(r.since), true);
}


// ============================================================================
// Hooks called from map.js
// ============================================================================

// An object being drawn or edited is drawn from THIS file's copy, so the poll
// must not draw it from the model as well.
function cmEditSuppresses(rootId, nodeId) {
    if (mode === MODE_BROWSE || !target) return false;
    if (target.region !== rootId) return false;
    return target.sub ? (target.sub === nodeId) : (rootId === nodeId);
}

// What map.js puts in its render signature.  Derived from the LIVE target
// rather than from the region list, so it changes the instant a mode is
// entered or left and can never agree with the previous value by accident.
function cmEditTargetKey() {
    if (mode === MODE_BROWSE || !target) return '';
    return mode + ':' + target.region + '/' + (target.sub || '') +
        '/' + (target.poly === undefined ? '' : target.poly);
}

// AN OBJECT WITH NO GEOMETRY IS NOWHERE ON THE MAP, so selecting it has to
// produce something to act on or it is stranded - which is exactly what
// happens when a new object is created and its first drawing abandoned.
let bannerDismissed = '';

function updateIdleBanner() {
    if (mode !== MODE_BROWSE) return;       // a mode owns the bar

    const sel = selectedNode();
    const empty = sel && !(sel.node.polygons || []).length;
    if (!empty || bannerDismissed === sel.node.id) { hideBar(); return; }

    const isSub = sel.node !== sel.root;
    showBar(sel.node.id + ' has no geometry yet', [
        { label: 'Draw', cls: 'cm-btn-go', fn: () => {
            bannerDismissed = '';
            startDraw({ root: sel.root, node: sel.node }, false);
        } },
        { label: 'x', fn: () => { bannerDismissed = sel.node.id; hideBar(); } },
    ]);
}

// THE APPLICATION OWNS THE MODE, and this is where that stops being a
// claim.  The applet publishes what it is doing and, from here, obeys what
// comes back: a document saying browse, or one in which the object under
// the hand no longer exists, ends the edit.
//
// That is what makes Close, Open and Revert safe without disabling
// anything - they publish browse and the map lets go on its next poll -
// and it is the same path a disconnect takes, because a document that
// cannot be reached says nothing at all.
//
// It waits for its own publish to be reflected first.  A /state built
// before the edit was announced would otherwise arrive a moment after it
// began and cancel it.

function obeyPublishedMode(state) {
    if (mode === MODE_BROWSE || !target) return;
    if (!(state.version > publishedVersion)) return;

    const said = state.edit || {};
    const mine = target.region + '/' + (target.sub || '');
    const says = (said.region || '') + '/' + (said.sub || '');

    const ended  = (said.mode || 'browse') === 'browse' || says !== mine;
    const vanished = !nodeById(target.sub || target.region);

    if (!ended && !vanished) return;

    banner(vanished ?
        'the object being edited is no longer in the set' :
        'the edit was ended by the application', true);
    finishEdit(1);
}


function cmEditOnState(state) {
    cmState = state;
    updateGrid();
    obeyPublishedMode(state);
    onSelectionChanged(state);

    // A just-created object appears in this document for the first time; it
    // has no geometry, so drawing it is the next thing anybody wants.
    if (pendingDraw) {
        const hit = nodeById(pendingDraw);
        if (hit) {
            const id = pendingDraw;
            pendingDraw = null;
            bannerDismissed = '';
            selectId(id);
            startDraw(hit, false);
            return;
        }
    }
    updateIdleBanner();
}

map.on('zoomend', updateGrid);
updateGrid();
drawAutoZoomRow();

// THE APPLICATION IS GONE, so there is no mode: an edit is a thing the
// document authorises, and there is no document to authorise it.  Held
// geometry goes with it, which is the honest end - it could not be
// committed, and holding it would only put off losing it until the
// application came back in browse and ended it anyway.
function cmEditDisconnected() {
    if (mode !== MODE_BROWSE) finishEdit(1);
    cmState = null;
    publishedVersion = -1;

    // The remembered selection is deliberately kept.  Losing the
    // application is the same kind of gap as closing the page, and what
    // was selected across it is exactly the comparison that decides
    // whether the map should frame something when it comes back.
}

window.cmEditSuppresses   = cmEditSuppresses;
window.cmEditTargetKey    = cmEditTargetKey;
window.cmEditOnState      = cmEditOnState;
window.cmEditDisconnected = cmEditDisconnected;
