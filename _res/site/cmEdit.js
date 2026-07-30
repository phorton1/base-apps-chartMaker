// cmEdit.js -- chartMaker region and subregion editing.
//
// See docs/design/editing_leaflet.md for the interface this implements and
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
const MID_ICON = L.divIcon({ className: 'cm-mid', iconSize: [7,7],   iconAnchor: [3,3] });

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
async function refusalText(since) {
    try {
        const log = await fetchJson('/api/log?since=' + (since || 0), 4000);
        const bad = (log.lines || [])
            .map(l => (typeof l === 'string' ? l : (l.line || l.msg || '')))
            .filter(t => /ERROR|WARNING/.test(t));
        if (!bad.length) return 'refused';
        return bad[bad.length - 1].replace(/^.*?(ERROR|WARNING)[^-]*-?\s*/, '');
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
function hitChain(lng, lat) {
    const chain = [];
    const walk = (node, root) => {
        if (!hitsNode(node, lng, lat)) return;
        for (const s of (node.subregions || [])) walk(s, root);
        chain.push({ root: root, node: node });
    };
    for (const r of (cmState && cmState.regions || [])) walk(r, r);
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
    // otherwise be framed at a zoom no card ever holds imagery for.
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

    const foreign = (key !== sentSelKey);
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
        // Choosing an item ends the cycle: the next right-click here starts
        // at the innermost object again rather than stepping outward.
        b.onclick = () => { hideMenu(); resetHitCycle(); it.fn(); };
        menuDiv.appendChild(b);
    }
    menuDiv.style.left = x + 'px';
    menuDiv.style.top  = y + 'px';
    menuDiv.style.display = 'block';
}

function gridItem() {
    return { label: gridOn ? 'Snap to grid: on' : 'Snap to grid: off',
             fn: () => toggleGrid() };
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
        showMenu(ev2.clientX, ev2.clientY, [
            { label: 'Create Region...', fn: () => newRegionDialog(ev.latlng) },
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

function banner(text, isError) {
    const hint = barDiv.querySelector('.cm-bar-hint');
    if (hint) { hint.textContent = text; hint.style.color = isError ? '#ff6b60' : ''; }
    else console.warn('chartMaker: ' + text);
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
        const inp = document.createElement('input');
        inp.value = f.value;
        inp.size  = f.size || 18;
        if (f.numeric) { inp.type = 'number'; inp.min = 0; inp.max = 24; }
        const note = document.createElement('span');
        note.className = 'cm-dlg-note';
        row.appendChild(lab); row.appendChild(inp); row.appendChild(note);
        dlgDiv.appendChild(row);
        inputs[f.key] = inp;
        notes[f.key]  = note;
        inp.oninput = () => revalidate();
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
            // touched - the id is the file name and the card file stem.
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
        const pol = parentPolygons();
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
        const poly = L.polygon(pts, Object.assign({ interactive: false }, style,
            current ? { fill: true, fillOpacity: 0.08 } : {}));
        poly.addTo(workLayer);
    });

    const ring = working[target.poly] || [];
    ring.forEach((p, i) => {
        const m = L.marker([p[1], p[0]], { icon: VTX_ICON, draggable: true });
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
        m.on('dragend', e => insertVertex(i + 1, e.target.getLatLng()));
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
        banner('outside ' + (parentName() || 'the parent') + ', not moved', true);
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

function insertVertex(at, latlng) {
    const p = snap(latlng, false);
    if (outsideParent(p)) { banner('outside the parent, not inserted', true);
        redrawWork(); return; }
    working[target.poly].splice(at, 0, [p.lng, p.lat]);
    dirty = true;
    publishMode();
    redrawWork();
}

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
