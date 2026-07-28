// map.js -- the chartMaker Leaflet applet.
//
// Scaffold only.  ONE hardwired tile source, no TSD machinery: this pass
// exists to prove the console / wx / Leaflet triumvirate comes up together.
//
// The source is NASA GIBS, which is a US government work (not copyrighted)
// and which publishes a bulk-download threshold rather than a prohibition.
// The layer is the Landsat WELD global annual true-colour composite -- the
// finest GLOBAL imagery GIBS carries, at 30 m, declared by its tile matrix
// set to reach z12 and no further.
//
// Note the REST path order: {z}/{y}/{x}, row before column.

const GIBS_ROOT  = 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best';
const GIBS_LAYER = 'Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual';
const GIBS_TIME  = '2000-12-01';        // the layer's own declared default
const GIBS_SET   = 'GoogleMapsCompatible_Level12';

const GIBS_ATTRIB =
    'Imagery courtesy of NASA/GSFC Earth Science Data and Information ' +
    'System (<a href="https://nasa-gibs.github.io/gibs-api-docs/">GIBS</a>)';

const imageryLayer = L.tileLayer(
    GIBS_ROOT + '/' + GIBS_LAYER + '/default/' + GIBS_TIME + '/' +
        GIBS_SET + '/{z}/{y}/{x}.jpeg',
    {
        attribution:   GIBS_ATTRIB,
        maxNativeZoom: 12,      // declared by the tile matrix set
        maxZoom:       16,      // overzoom past it, deliberately
        tileSize:      256,
    });

const map = L.map('map', {
    center: [9.33, -82.24],     // Bocas del Toro
    zoom:   10,
    layers: [imageryLayer],
});

L.control.scale({ imperial: true, metric: true }).addTo(map);


// ---- Cursor coordinates ----

function toDDM(dd, isLat) {
    const dir = isLat ? (dd >= 0 ? 'N' : 'S') : (dd >= 0 ? 'E' : 'W');
    const abs = Math.abs(dd);
    const deg = Math.floor(abs);
    const min = (abs - deg) * 60;
    return deg + '\u00B0' + min.toFixed(3) + "' " + dir;
}

const coordsDiv = document.getElementById('cm-coords');

map.on('mousemove', e => {
    const lat = e.latlng.lat, lng = e.latlng.lng;
    coordsDiv.textContent =
        toDDM(lat, true) + '  ' + toDDM(lng, false) + '\n' +
        lat.toFixed(5)   + '  ' + lng.toFixed(5)    + '\n' +
        'zoom ' + map.getZoom();
});

map.on('mouseout', () => {
    coordsDiv.textContent = '';
});
