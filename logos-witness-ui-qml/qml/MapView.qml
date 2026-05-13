import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtLocation 6.5
import QtPositioning 6.5

// Phase 3.2: OSM tile map, capped at z=9 (regional, no street detail).
// SPEC §7.10: OSM is the sole permitted external data source for v0;
// migrates to Logos-Storage-distributed tiles in a separate prototype.
//
// Two modes share this component (Phase 3.4):
//   - pickable: true  → click drops a pin and emits `pinned(...)`. Used by
//     SubmitDialog to choose where a photo is anchored.
//   - pickable: false → click does nothing; the floating geohash readout
//     hides. Used by Main.qml's app-shell map showing received markers.
// Both modes render the `markers` model below (empty in pick mode).

Item {
    id: root

    // Hard caps. z=9 keeps street names off the standard OSM Mapnik style.
    readonly property int minZoomLevel: 2
    readonly property int maxZoomLevel: 9

    // Mode switch. Default preserves the 3.2 pick-mode caller (SubmitDialog).
    property bool pickable: true

    // Pin (pick-mode) state. Untouched when pickable is false.
    property string pinGeohash: ""
    property real   pinLatitude: 0.0
    property real   pinLongitude: 0.0
    property bool   hasPin: false

    // Display-mode markers. Each entry is `{latitude, longitude, contentHash,
    // geohash, timestamp}`. Populated by Main.qml from listInscriptions +
    // referenceObserved.
    property var markers: []

    signal pinned(string geohash, real latitude, real longitude)
    signal markerClicked(string contentHash)

    // Niemeyer-2008 geohash, mirrored from SubmitHelpers.js::encodeGeohash.
    // SPEC §2 fixes precision at 8. Inlined to keep the component
    // self-contained without a top-of-file import; keep it in lockstep with
    // SubmitHelpers.js. tst_submit_helpers.qml pins the canonical output
    // via Wikipedia reference vectors.
    readonly property string _geohashAlphabet: "0123456789bcdefghjkmnpqrstuvwxyz"
    function _encodeGeohash(lat, lon, precision) {
        var latLo = -90.0, latHi = 90.0
        var lonLo = -180.0, lonHi = 180.0
        var bits = []
        var even = true
        while (bits.length < precision * 5) {
            if (even) {
                var lonMid = (lonLo + lonHi) / 2
                if (lon >= lonMid) { bits.push(1); lonLo = lonMid }
                else               { bits.push(0); lonHi = lonMid }
            } else {
                var latMid = (latLo + latHi) / 2
                if (lat >= latMid) { bits.push(1); latLo = latMid }
                else               { bits.push(0); latHi = latMid }
            }
            even = !even
        }
        var out = ""
        for (var i = 0; i < bits.length; i += 5) {
            var idx = bits[i]*16 + bits[i+1]*8 + bits[i+2]*4 + bits[i+3]*2 + bits[i+4]
            out += root._geohashAlphabet.charAt(idx)
        }
        return out
    }

    Plugin {
        id: osmPlugin
        name: "osm"
        // OSMF tile usage policy asks for an identifying User-Agent and forbids
        // the default Nominatim/tile endpoints for production traffic. Pre-alpha
        // demo traffic only; v0.x migrates off OSM (SPEC §7.10).
        PluginParameter { name: "osm.useragent"; value: "logos-witness/0.1.0" }
    }

    Map {
        id: map
        anchors.fill: parent
        plugin: osmPlugin
        center: QtPositioning.coordinate(20.0, 0.0)
        zoomLevel: 3
        minimumZoomLevel: root.minZoomLevel
        maximumZoomLevel: root.maxZoomLevel
        copyrightsVisible: true

        MapQuickItem {
            id: pinMarker
            visible: root.pickable && root.hasPin
            anchorPoint.x: pinIcon.width / 2
            anchorPoint.y: pinIcon.height
            coordinate: QtPositioning.coordinate(root.pinLatitude, root.pinLongitude)
            sourceItem: Rectangle {
                id: pinIcon
                width: 14
                height: 14
                radius: 7
                color: "#d62828"
                border.color: "white"
                border.width: 2
            }
        }

        // Display markers. MapItemView is the idiomatic QtLocation
        // marker repeater; rebinding `markers` re-renders.
        // Per-marker opacity is SPEC §11.5: 1.0 at the cursor midpoint,
        // 0.15 at the window edges. Defaults to 1.0 when callers omit it.
        MapItemView {
            model: root.markers
            delegate: MapQuickItem {
                anchorPoint.x: markerDot.width / 2
                anchorPoint.y: markerDot.height / 2
                coordinate: QtPositioning.coordinate(
                    modelData.latitude, modelData.longitude)
                opacity: modelData.opacity !== undefined ? modelData.opacity : 1.0
                sourceItem: Rectangle {
                    id: markerDot
                    width: 12
                    height: 12
                    radius: 6
                    color: "#1d4ed8"
                    border.color: "white"
                    border.width: 2
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.markerClicked(modelData.contentHash)
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.pickable
            acceptedButtons: Qt.LeftButton
            onClicked: function (mouse) {
                var coord = map.toCoordinate(Qt.point(mouse.x, mouse.y))
                if (!coord.isValid) return
                root.pinLatitude  = coord.latitude
                root.pinLongitude = coord.longitude
                root.pinGeohash   = root._encodeGeohash(coord.latitude, coord.longitude, 8)
                root.hasPin       = true
                root.pinned(root.pinGeohash, coord.latitude, coord.longitude)
            }
        }
    }

    // Pin readout: geohash + lat/lon with copy-to-clipboard, so users can
    // paste into another app to verify. Fixed precision per SPEC §2.
    // Pick-mode only — display mode shows marker popups via Main.qml.
    Frame {
        visible: root.pickable && root.hasPin
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 8
        padding: 8
        background: Rectangle {
            color: "#f6f6f6"
            border.color: "#ccc"
            radius: 4
            opacity: 0.95
        }

        ColumnLayout {
            spacing: 4

            RowLayout {
                spacing: 8
                Label {
                    text: "geohash-8: " + root.pinGeohash
                    font.family: "monospace"
                    font.pixelSize: 11
                }
                Button {
                    text: "Copy"
                    font.pixelSize: 10
                    padding: 2
                    onClicked: copyHelper.copyText(root.pinGeohash)
                }
            }

            RowLayout {
                spacing: 8
                Label {
                    text: "lat,lon: " + root.pinLatitude.toFixed(6)
                          + ", " + root.pinLongitude.toFixed(6)
                    font.family: "monospace"
                    font.pixelSize: 11
                }
                Button {
                    text: "Copy"
                    font.pixelSize: 10
                    padding: 2
                    onClicked: copyHelper.copyText(
                        root.pinLatitude.toFixed(6) + "," + root.pinLongitude.toFixed(6))
                }
            }
        }
    }

    // QML's clipboard story is fragmented across versions — TextEdit's
    // selectAll + built-in copy() is the portable trick that doesn't need
    // a C++ shim. The wrapper has a different name to avoid shadowing.
    //
    // TODO: once the basecamp host pins Qt ≥ 6.7, switch to the proper API.
    // Two candidates depending on what ships in the host's Qt build:
    //   - `Qt.application.clipboard.text = s`  (Qt Quick, Qt 6.x where
    //     QGuiApplication::clipboard() is exposed to QML)
    //   - `import Qt.labs.platform; Clipboard.setText(s)`
    // Either removes the hidden TextEdit + selectAll dance below.
    TextEdit {
        id: copyHelper
        visible: false
        function copyText(s) {
            text = s
            selectAll()
            copy()  // TextEdit.copy() — the built-in.
            deselect()
        }
    }
}
