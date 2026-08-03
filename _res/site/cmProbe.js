// cmProbe.js -- probe mode: is this SERVICE worth using here.
//
// THE SUBJECT IS A SOURCE, NOT A REGION. A region only says where to look.
// Once a region names its own source and levels the build answers coverage
// exactly within them; the hard question is which of twenty-five candidate
// services is worth specifying at all, and that has no region in it.
//
// SEVERAL SOURCES AT ONCE. The mode accumulates one result set per source
// probed, so Esri's marks and Google's marks sit on the same ground and the
// palette turns each on and off. Comparing them is the entire point.
//
// THE APPLICATION DECIDES AND COUNTS; THIS RENDERS. The map picks no sample
// points, fetches no tiles and counts nothing. If the browser decided any of
// it the marks would illustrate the analysis rather than be it, which is the
// same reason preview does not work out coverage for itself.
//
// Depends on globals from map.js: map, fetchJson, tileLat.

// THE MARK'S SIZE IS ITS LEVEL, larger for coarser, and it took two wrong
// versions to get here.
//
// TRUE FOOTPRINTS made size mean level exactly, and produced a quilt of
// opaque rectangles in which one z10 sample buried every finer sample inside
// it and hid the imagery being judged.
//
// A FIXED DOT fixed that by throwing the level away entirely, so a green
// mark and a red mark in the same place said nothing about WHICH DEPTH had
// failed - which is the one thing a spread of marks is read for. The table
// has the levels, but a table cannot say which of a hundred dots is which,
// and a legend cannot carry twelve sizes.
//
// So: scaled by level and well short of the footprint. Big enough that a
// coarse sample is visibly coarse, small enough that it never covers the
// chart or the finer marks drawn over it.
//
// FIXED AHEAD OF TIME, BY LEVEL. A size decided from "what has been probed so
// far" is not a scale, it is a running average - and because the probe
// publishes levels in ascending order, it made every dot on the map GROW as
// the run descended. A z11 mark drew at the minimum while z11 was the finest
// level known, and near the maximum once z22 arrived. Same mark, same tile,
// three sizes in one run.
//
// THE BAND IS z10 TO z21, and the levels outside it clamp. Below z10 is
// hundreds of kilometres of tile - browsing, not judging - and above z21 a
// tile is approaching the size of the boat. Anchoring the scale there spends
// the whole visible range on the levels somebody actually builds at.
//
// GEOMETRIC, NOT LINEAR, and that is what makes it readable. The eye judges
// size by RATIO - a just-noticeable difference is about 5-10% of diameter -
// so equal ratios per level give equal perceptual steps, while equal pixel
// steps give differences that are obvious at the small end and invisible at
// the large one. A linear 24-down-to-1 ramp separates z22 from z23 by 2:1 and
// z0 from z1 by 4%, which is exactly backwards from where the resolution is
// wanted.
//
// 11 down to 3 across those eleven steps is a ratio of about 1.125 a level:
// comfortably above the threshold, so every adjacent pair is separable, and
// nowhere near the 2:1 that a footprint would imply.

const CM_PROBE_Z_LO    = 10;    // the coarse anchor, largest dot
const CM_PROBE_Z_HI    = 21;    // the fine anchor, smallest dot
const CM_PROBE_R_LO    = 11;
const CM_PROBE_R_HI    = 3;
const CM_PROBE_R_FLOOR = 2.3;   // bounds on the LEVEL ramp alone
const CM_PROBE_R_CEIL  = 14;

const CM_PROBE_RATIO =
    Math.pow(CM_PROBE_R_HI / CM_PROBE_R_LO, 1 / (CM_PROBE_Z_HI - CM_PROBE_Z_LO));

// ============================================================================
// AND A SECOND, SEPARATE FACTOR FOR THE VIEW ZOOM
// ============================================================================
// TWO JOBS, TWO KNOBS, AND CONFLATING THEM IS WHAT WENT WRONG EVERY OTHER
// TIME. The ramp above answers "which level is this dot". The factor below
// answers "can I see it at all". They are not the same question and one
// number cannot carry both.
//
// WHY NOT TRUE PROPORTIONAL SCALING - a dot as a fixed fraction of its own
// tile on screen, which is the geometrically honest version. Because it
// doubles per level exactly, and the usable range for a dot is about 5px to
// 30px, which is six to one. Two-to-one per level burns that in TWO AND A
// HALF LEVELS. So at any view three levels would look right and the other
// ten would sit pinned at a floor or a ceiling. That is arithmetic, not a
// tuning problem, and it trades away the one thing the ramp does well.
//
// SO THE FACTOR IS UNIFORM: every dot on the map is multiplied by the same
// number, and the RATIOS BETWEEN LEVELS NEVER CHANGE. z20 stays as
// distinguishable from z21 at one zoom as at any other. What you gain is
// that zooming in to inspect makes the small ones big enough to read a
// colour off, which was the actual complaint - a 6px dot is not a colour,
// it is a smudge.
//
// It doubles every four levels, anchored so that map zoom 15 gives exactly
// the ramp's own sizes. The rate is the only real knob and four is a guess.

const CM_PROBE_ZOOM_REF = 15;   // the view at which the ramp is exact
const CM_PROBE_ZOOM_PER = 4;    // levels of zoom that double the dots

const CM_PROBE_R_MIN = 1.5;     // final bounds, after the factor
const CM_PROBE_R_MAX = 16;      // 32px across, and never a blob

let probeZMin = 0;              // the range present in the marks, for the key
let probeZMax = 0;

// The curve CONTINUES past the anchors rather than flattening at them, so a
// z22 vanity level is still distinguishable from z21, and only the hard
// floor and ceiling stop it. A clamp that starts at the anchor would make
// every level above z21 identical, which is the fixed-dot failure again in
// the one band where the dots are smallest and hardest to tell apart.
function cmProbeBaseRadius(z) {
    const r = CM_PROBE_R_LO * Math.pow(CM_PROBE_RATIO, z - CM_PROBE_Z_LO);
    return Math.max(CM_PROBE_R_FLOOR, Math.min(CM_PROBE_R_CEIL, r));
}

// READ ONCE PER DRAW, not once per mark. It is the same for every dot on the
// map by construction, and map.getZoom() inside a loop over ten thousand
// marks is ten thousand calls to answer one question.
function cmProbeZoomFactor() {
    if (!map) return 1;
    return Math.pow(2, (map.getZoom() - CM_PROBE_ZOOM_REF) / CM_PROBE_ZOOM_PER);
}

function cmProbeRadius(z, factor) {
    return Math.max(CM_PROBE_R_MIN,
           Math.min(CM_PROBE_R_MAX, cmProbeBaseRadius(z) * factor));
}

// Outcomes. Green found, red absent, and the cases in between where
// something came back and it is not imagery.
//
// ABSENT AND NO-DATA ARE TWO MARKS, NOT ONE. A 404 is a service saying it
// has nothing here; a 200 carrying its declared no-data body is a service
// declining to say so, which is a worse property and one nobody would know
// about at all if the .tsd did not name that body. Which of the two it is
// decides how far the ceiling can be trusted, so it gets its own colour.
//
// NO-DATA IS AMBER, AND WAS A DEEP PINK. Putting it "in the red family"
// because it is also an absence was reasoning about meaning rather than
// about eyes: at these sizes it was simply red, and a distinction nobody
// can see is not a distinction. Amber was free because -
//
// THERE IS NO 'no detail' MARK ANY MORE. It was a per-tile verdict from a
// threshold that fired on open water at z11, where a blow-up costs a handful
// of tiles and changes nothing, and did NOT fire on google z21/z22 over a
// property where the enlargement is plain to the eye. How much a LEVEL holds
// is not a property any one tile has. The number survives, per level, in the
// report's detail column; the dot does not. A tile that scored low is drawn
// as what it is, which is FOUND.
const CM_PROBE_COLOUR = {
    found:    '#37b24d',
    absent:   '#e03131',
    sentinel: '#f0a020',
    flat:     '#845ef7',
};

// One hue per source, in the PALETTE ONLY. It used to ring the dot as well,
// which is where it did damage - see the note on stroke in the draw. A row
// token, so a source can be found in a list of six; it says nothing about
// any mark on the map, and nothing on the map is coloured by source.
const CM_SOURCE_TINT = ['#4dabf7', '#ffd43b', '#ff8787', '#63e6be',
                        '#b197fc', '#ffa8a8'];

let probeRenderer  = null;
let probeLayers    = {};     // source id -> L.layerGroup
let probeHidden    = {};     // source id -> true when unchecked
let probeOn        = false;
let probeSeen      = -1;
let probeFetching  = false;
let probePanel     = null;
let probeCtl       = null;
let probeMarks     = [];
let probeSources   = [];

function cmProbeRenderer() {
    // Canvas, not SVG. A probe across thirteen levels is thousands of marks
    // and an SVG element apiece makes panning unusable.
    if (!probeRenderer) probeRenderer = L.canvas({ padding: 0.3 });
    return probeRenderer;
}

// ============================================================================
// the palette
// ============================================================================
// BOTTOM RIGHT, translucent grey. Patrick's preference, stated as such: the
// probe's furniture is modal and belongs to the probe. No scheme is being
// followed and none should be inferred.
//
// It replaces the old two-line overlay rather than sitting beside it. The wx
// window owns the columns of numbers; what the map still needs to say is
// which source these marks belong to and what the colours mean, which is what
// a palette is.

const CmProbePanel = L.Control.extend({
    options: { position: 'bottomright' },
    onAdd: function () {
        const div = L.DomUtil.create('div', 'cm-probe-overlay');
        L.DomEvent.disableClickPropagation(div);
        probePanel = div;
        return div;
    },
});

function cmProbeTint(i) { return CM_SOURCE_TINT[i % CM_SOURCE_TINT.length]; }

function cmProbeDrawPanel() {
    if (!probePanel) return;

    let html = '<div class="cm-probe-title">Probe</div>';

    if (!probeSources.length) {
        html += '<div class="cm-probe-empty">nothing probed yet</div>';
        probePanel.innerHTML = html;
        return;
    }

    probeSources.forEach((s, i) => {
        const on = !probeHidden[s.id];
        html += '<label class="cm-probe-row">' +
                '<input type="checkbox" data-src="' + cmProbeEsc(s.id) + '"' +
                (on ? ' checked' : '') + '>' +
                '<span class="cm-probe-swatch" style="background:' +
                cmProbeTint(i) + '"></span>' +
                '<span class="cm-probe-name">' + cmProbeEsc(s.id) + '</span>' +
                '</label>';
        if (s.status && s.status !== 'running')
            html += '<div class="cm-probe-stat">' + cmProbeEsc(s.status) + '</div>';
        else if (s.status === 'running')
            html += '<div class="cm-probe-stat"><i>running...</i></div>';
    });

    // TWO ACTS, NAMED FOR WHAT THEY DO TO THE RESULTS, and named the SAME
    // as the buttons in the application's own window - they are the same
    // two acts and had no business having two vocabularies.
    //
    //   Halt run   - the run stops, the marks STAY. They are the product,
    //                and they become useful when they stop changing.
    //   Clear all  - the results go and the mode ends.
    //
    // Halt is dead when nothing is running, so it cannot read as an offer
    // to undo a run that already finished.
    const running = probeSources.some(s => s.status === 'running');
    html += '<div class="cm-probe-btns">' +
            '<button data-act="stop"' + (running ? '' : ' disabled') +
            ' title="stop sampling, keep the marks">Halt run</button>' +
            '<button data-act="end"' +
            ' title="discard the results and leave probe mode">Clear all</button>' +
            '</div>';

    // The legend is four words and it is here rather than on the map,
    // because a colour on a three pixel dot is unreadable without one.
    html += '<div class="cm-probe-key">' +
            '<span style="color:' + CM_PROBE_COLOUR.found    + '">&#9679; found</span> ' +
            '<span style="color:' + CM_PROBE_COLOUR.absent   + '">&#9679; absent</span> ' +
            '<span style="color:' + CM_PROBE_COLOUR.sentinel + '">&#9679; no-data</span> ' +
            '<span style="color:' + CM_PROBE_COLOUR.flat     + '">&#9679; flat</span>' +
            '</div>';

    // THE SIZE RULE IN WORDS, because a legend cannot carry twelve sizes and
    // a size that means something nobody was told means nothing. One line,
    // and it names the range actually on the map rather than z0-24.
    if (probeZMax > probeZMin)
        html += '<div class="cm-probe-size">size = level, largest z' +
                probeZMin + ' to smallest z' + probeZMax + '</div>';

    probePanel.innerHTML = html;

    probePanel.querySelectorAll('input[type=checkbox]').forEach(box => {
        box.onchange = () => {
            probeHidden[box.dataset.src] = !box.checked;
            // Hiding a source can change the range of levels on the map, so
            // the line that names it is redrawn with them.
            cmProbeDraw();
            cmProbeDrawPanel();
        };
    });

    // Stop halts the run and leaves the marks, because they are the product
    // and they become useful when they stop changing. End leaves the mode
    // and takes them with it. Same two acts as the window's own buttons,
    // through the same vocabulary.
    probePanel.querySelectorAll('button[data-act]').forEach(b => {
        b.onclick = () => postEdit('sample', b.dataset.act);
    });
}

function cmProbeEsc(s) {
    return String(s).replace(/[&<>"]/g, c =>
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

// ============================================================================
// drawing
// ============================================================================

function cmProbeDraw() {
    Object.keys(probeLayers).forEach(id => {
        probeLayers[id].clearLayers();
        if (probeHidden[id]) map.removeLayer(probeLayers[id]);
        else if (!map.hasLayer(probeLayers[id])) probeLayers[id].addTo(map);
    });

    const order = {};
    probeSources.forEach((s, i) => { order[s.id] = i; });

    // PARSED ONCE, BEFORE ANYTHING IS DRAWN, because the size of a mark
    // depends on the range the whole set spans and no single mark knows it.
    const parsed = [];
    probeMarks.forEach(m => {
        // 'source z/x/y/outcome' -- one split for the source, one for the
        // rest. The flat encoding is what crosses the thread boundary, and
        // it is parsed here and nowhere else.
        const sp = m.indexOf(' ');
        if (sp < 0) return;
        const id = m.slice(0, sp);
        if (probeHidden[id]) return;

        // 'z/x/y/outcome/lat/lon'. The POSITION IS SUPPLIED rather than
        // derived from z/x/y: at a coarse level the sampled tile is far
        // bigger than the area asked about, so its own centre is somewhere
        // else entirely - a z0 sample of a property drew a dot in the
        // Atlantic. The application clips the tile to the area and sends
        // the centre of what is left.
        const bits = m.slice(sp + 1).split('/');
        if (bits.length < 6) return;
        const colour = CM_PROBE_COLOUR[bits[3]];
        if (!colour) return;
        const z = +bits[0];
        const lat = +bits[4], lon = +bits[5];
        if (!isFinite(lat) || !isFinite(lon) || !isFinite(z)) return;

        parsed.push({ id: id, z: z, lat: lat, lon: lon, colour: colour });
    });

    if (!parsed.length) return;

    probeZMin = parsed[0].z;
    probeZMax = parsed[0].z;
    parsed.forEach(p => {
        if (p.z < probeZMin) probeZMin = p.z;
        if (p.z > probeZMax) probeZMax = p.z;
    });

    // COARSEST FIRST, so the fine marks land ON TOP of the big ones rather
    // than under them. Sizing by level reintroduces exactly the burial the
    // footprints caused, at a hundredth of the scale, and the draw order is
    // what keeps it harmless: a small dot inside a large one is still
    // readable, the other way round it is gone.
    parsed.sort((a, b) => a.z - b.z);

    const factor = cmProbeZoomFactor();

    parsed.forEach(p => {
        let layer = probeLayers[p.id];
        if (!layer) {
            layer = probeLayers[p.id] = L.layerGroup([], { renderer: cmProbeRenderer() });
            layer.addTo(map);
        }

        // COARSE MARKS ARE MORE TRANSPARENT, because a big dot covers more
        // chart than a small one and is making a vaguer claim about where
        // it applies - a z10 sample is about a tile kilometres across.
        //
        // FROM THE LEVEL, NOT FROM THE FINAL RADIUS. Taking it from the drawn
        // size would make a dot fade as you zoomed in, which says the sample
        // got vaguer because you looked closer at it.
        const base = cmProbeBaseRadius(p.z);
        const r    = cmProbeRadius(p.z, factor);
        const fade = 0.95 - 0.3 * (base - CM_PROBE_R_FLOOR) /
                            (CM_PROBE_R_CEIL - CM_PROBE_R_FLOOR);

        // NO OUTLINE. The dot was ringed in a per-source tint so two
        // services could be told apart at a glance, and on a small dot that
        // ring is most of the dot - at radius 2 a 1px stroke is over half
        // the area. So the outcome colour, which is the whole point of the
        // mark, was being reported by a few pixels in the middle while the
        // source hue owned the edge. The fifth source's tint is a lavender
        // that read as the purple 'flat' outcome outright.
        //
        // A dot has ONE colour and it says what came back. Telling two
        // sources apart is what the palette's checkboxes are for.

        L.circleMarker([p.lat, p.lon], {
            renderer:    cmProbeRenderer(),
            radius:      r,
            stroke:      false,
            fillColor:   p.colour,
            fillOpacity: fade,
            opacity:     0.9,
            interactive: false,
        }).addTo(layer);
    });
}

// ============================================================================
// the poll
// ============================================================================

async function cmProbeRefresh() {
    if (probeFetching) return;
    probeFetching = true;
    try {
        const data = await fetchJson('/probe', 8000);
        probeSeen    = data.seq;
        probeMarks   = data.marks || [];
        probeSources = data.sources || [];

        // MARKS FIRST, THEN THE PANEL, because the panel says which levels
        // the sizes span and only drawing the marks works that out.
        cmProbeDraw();
        cmProbeDrawPanel();
    } catch (e) {
        // A failed poll is not a reason to throw away marks that are still
        // true. The next one repaints them.
        console.warn('chartMaker: /probe failed', e);
        probeSeen = -1;
    } finally {
        probeFetching = false;
    }
}

// THE ZOOM FACTOR MEANS THE MARKS MUST BE REDRAWN WHEN THE VIEW MOVES, and
// zoomend is the whole of it - panning changes no size. cmProbeDraw already
// rebuilds every mark from probeMarks on each poll, so this costs exactly one
// ordinary redraw and needs no per-marker bookkeeping.
//
// HOOKED ONCE, not per mode change. Leaflet would happily register the same
// handler a second time and then redraw twice per zoom, forever.
let probeZoomHooked = false;

function cmProbeHookZoom() {
    if (probeZoomHooked || !map) return;
    probeZoomHooked = true;
    map.on('zoomend', () => { if (probeOn) cmProbeDraw(); });
}

function cmProbeSetMode(on) {
    if (on === probeOn) return;
    probeOn = on;

    if (probeOn) {
        probeCtl = new CmProbePanel();
        probeCtl.addTo(map);
        cmProbeHookZoom();
        probeSeen = -1;                 // fetch whatever is already there
    } else {
        Object.keys(probeLayers).forEach(id => {
            probeLayers[id].clearLayers();
            map.removeLayer(probeLayers[id]);
        });
        probeLayers  = {};
        probeHidden  = {};
        probeMarks   = [];
        probeSources = [];
        probeZMin    = 0;
        probeZMax    = 0;
        if (probeCtl) {
            map.removeControl(probeCtl);
            probeCtl   = null;
            probePanel = null;
        }
        probeSeen = -1;
    }
}

// THE APPLICATION OWNS THE MODE, exactly as it owns the edit mode. This obeys
// what it is told rather than deciding for itself, so closing the probe window
// in the application clears the map on the next poll and there is no second
// place that has to be told.
//
// DRIVEN FROM /poll, NOT FROM /state. A running probe publishes a unit per
// source and level while the state document is unchanged, so anything waiting
// on the state version froze the palette at whatever it read when the map
// opened and never drew a mark. /poll is where "has anything changed" is
// already asked every cycle, and it now carries the probe's own sequence.

function cmProbeOnPoll(poll) {
    if (!poll) return;
    cmProbeSetMode(!!poll.probe_on);
    if (probeOn && poll.probe_seq !== probeSeen) cmProbeRefresh();
}
window.cmProbeOnPoll = cmProbeOnPoll;

// Still called on a full state render, so a map that opens into a mode
// already running paints immediately rather than on the next poll.
function cmProbeOnState(state) {
    const p = (state && state.probe) || { on: 0, seq: 0 };
    cmProbeSetMode(!!p.on);
    if (probeOn && p.seq !== probeSeen) cmProbeRefresh();
}
window.cmProbeOnState = cmProbeOnState;
