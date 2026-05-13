import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "TimelineModel.js" as TM

// Phase 3.4 app shell: full-window display MapView + right-edge timeline +
// floating Submit button. References are seeded from `listInscriptions()`
// on init and refreshed after every successful local submit (single-
// instance demo). Cross-instance live feed lands in Phase 6 when Delivery
// is wired; until then the only producer of refs is local submission.
//
// Phase 3.5 (per SPEC §11): a centered-playhead TimeCursor along the
// bottom owns time navigation. It emits `windowChanged(t0, t1)`; this
// shell rebuilds marker + timeline visibility and applies an opacity
// ramp from `opacityFor(ts, tm, W)` to every visible item.

Item {
    id: root
    width: 960
    height: 640

    // In-memory timeline store. Backed by TimelineModel.js so the same
    // merge logic that ships in production is exercised by qmltest.
    property var store: TM.makeStore()

    // ListModel mirror of `store.entries` for the UI to bind against. QML
    // bindings can't depend on a plain-JS array changing in place, so we
    // copy through a ListModel and notify by reassigning a `markers` array
    // on the MapView (which uses a `var`-typed property).
    ListModel { id: timelineEntries }
    property var markers: []

    // Reactive mirrors of `store` for QML bindings. `store.entries` is a
    // plain JS array mutated in place by TimelineModel.js; bindings that
    // read it directly never re-evaluate. _rebuildBindings keeps these in
    // sync after every seed/merge so the time cursor, counters, and bounds
    // update when refs arrive.
    property int  entryCount: 0
    property real storeMinTs: NaN
    property real storeMaxTs: NaN

    // Phase 3.5 / SPEC §11: the visible time window, fed by TimeCursor's
    // `windowChanged` signal. Both NaN before the cursor commits its first
    // window (during initial layout); after that they are always finite.
    property real winT0: NaN
    property real winT1: NaN
    property real winTm: NaN
    property real winW:  NaN

    // Detail popup state. Set when the user clicks a marker or row.
    property var selectedRef: null

    // Stub-only: a single-instance refresh window. Polling cadence is
    // intentionally lazy — every 5 s — because in v0 the only producer
    // of new refs is local submitPhoto, and we already trigger a refresh
    // from the dialog's onAccepted hook. The timer is the safety net for
    // anything that bypasses the dialog (e.g. logoscore CLI calls running
    // in parallel) and goes away in Phase 6 when Delivery + a proper
    // signal subscribe replace polling.
    Timer {
        id: refreshTimer
        interval: 5000
        repeat: true
        running: true
        onTriggered: root._refreshFromCore()
    }

    Component.onCompleted: root._refreshFromCore()

    // ---------------------------------------------------------------
    // Layout
    // ---------------------------------------------------------------

    MapView {
        id: mapView
        anchors.fill: parent
        pickable: false
        markers: root.markers
        onMarkerClicked: function (contentHash) {
            root._showDetailFor(contentHash)
        }
    }

    // Timeline rail. Anchored to the right edge over the map.
    Frame {
        id: timelineFrame
        width: 280
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: 12
        padding: 8
        background: Rectangle {
            color: "#fafafa"
            border.color: "#ccc"
            radius: 4
            opacity: 0.95
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: "Timeline"
                    font.bold: true
                    Layout.fillWidth: true
                }
                Label {
                    // "5 refs" when the cursor's window holds them all,
                    // "3 of 5 refs" when the window is narrower.
                    text: {
                        var total = root.entryCount
                        var shown = timelineEntries.count
                        if (shown === total) {
                            return total + " ref" + (total === 1 ? "" : "s")
                        }
                        return shown + " of " + total + " refs"
                    }
                    color: "#666"
                    font.pixelSize: 11
                }
            }

            ListView {
                id: timelineList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                model: timelineEntries
                delegate: ItemDelegate {
                    width: timelineList.width
                    // Per-row opacity from SPEC §11.5. Precomputed in
                    // _rebuildBindings so the model already carries it;
                    // fall back to 1.0 before the cursor has committed.
                    opacity: model.opacity !== undefined ? model.opacity : 1.0
                    contentItem: ColumnLayout {
                        spacing: 2
                        Label {
                            text: TM.formatTimestamp(model.timestamp)
                            font.pixelSize: 11
                            font.bold: true
                        }
                        Label {
                            text: "geohash " + model.geohash
                                  + "  ·  hash " + TM.shortHash(model.content_hash)
                            font.family: "monospace"
                            font.pixelSize: 10
                            color: "#555"
                        }
                    }
                    onClicked: root._showDetailFor(model.content_hash)
                }
            }

            Label {
                visible: timelineEntries.count === 0
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: root.entryCount === 0
                      ? "No references yet. Click Submit photo… to add one."
                      : "No references in this window. Scroll or widen the scale."
                color: "#888"
                font.pixelSize: 11
            }
        }
    }

    // Floating Submit button. Bottom-left so it doesn't fight the
    // timeline rail.
    Button {
        id: submitButton
        text: "Submit photo…"
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 16
        highlighted: true
        onClicked: submitDialog.open()
    }

    // SPEC §11 time cursor. Centered-playhead window navigator; owns its
    // own `tm` and `scalePreset`, emits `windowChanged(t0, t1)` here.
    Frame {
        id: cursorFrame
        anchors.left: submitButton.right
        anchors.right: timelineFrame.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        anchors.bottomMargin: 16
        padding: 8
        background: Rectangle {
            color: "#fafafa"
            border.color: "#ccc"
            radius: 4
            opacity: 0.95
        }

        TimeCursor {
            id: timeCursor
            anchors.fill: parent
            refs: root.store.entries
            entryCount: root.entryCount
            storeMinTs: root.storeMinTs
            storeMaxTs: root.storeMaxTs
            onWindowChanged: function (t0, t1) {
                root.winT0 = t0
                root.winT1 = t1
                root.winTm = (t0 + t1) / 2
                root.winW  = t1 - t0
                root._rebuildBindings()
            }
        }
    }

    SubmitDialog {
        id: submitDialog
        anchors.centerIn: parent
        onAccepted: root._refreshFromCore()
    }

    // Marker / row detail popup. Stub-only for v0 — Phase 5 swaps in a
    // real Storage fetch + photo render.
    Dialog {
        id: detailDialog
        modal: true
        title: "Reference"
        standardButtons: Dialog.Close
        anchors.centerIn: parent
        width: 380

        contentItem: ColumnLayout {
            spacing: 8
            Label {
                text: root.selectedRef
                      ? TM.formatTimestamp(root.selectedRef.timestamp)
                      : ""
                font.bold: true
            }
            Label {
                text: root.selectedRef
                      ? ("geohash: " + root.selectedRef.geohash)
                      : ""
                font.family: "monospace"
                font.pixelSize: 11
            }
            Label {
                text: root.selectedRef
                      ? ("content_hash:\n" + root.selectedRef.content_hash)
                      : ""
                font.family: "monospace"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#888"
                font.pixelSize: 11
                text: "Photo preview lands in Phase 5 when stripped bytes flow through Logos Storage."
            }
        }
    }

    // ---------------------------------------------------------------
    // Core wiring
    // ---------------------------------------------------------------

    // Pull the full list from the core and merge it into the local
    // store. Cheap in v0 (stub keeps everything in process memory); when
    // Storage + Delivery are real this stays correct because dedupe-by-
    // content_hash keeps re-seeding idempotent.
    function _refreshFromCore() {
        try {
            var raw = logos.callModule(
                "logos_witness_core", "listInscriptions", [])
            // The host bridge JSON-encodes return values. Tolerate both
            // string and already-parsed shapes — SubmitDialog does the
            // same gymnastics.
            var refs = (typeof raw === "string") ? JSON.parse(raw) : raw
            if (!Array.isArray(refs)) return
            TM.seedFromList(root.store, refs)
            _rebuildBindings()
        } catch (e) {
            console.warn("listInscriptions failed:", e)
        }
    }

    // Recompute the ListModel + markers array from the JS store, applying
    // the time cursor's current window (root.winT0 / winT1) and per-item
    // opacity from SPEC §11.5. Two separate output shapes because:
    //   - ListView wants a ListModel for delegate binding
    //   - MapItemView (in MapView.qml) wants a plain JS array for `var`
    //     property assignment to trip a binding update
    //
    // Before the cursor has emitted its first window (winT0/winT1 NaN),
    // we show everything at full opacity so the initial paint isn't blank.
    function _rebuildBindings() {
        var range = TM.storeTimeRange(root.store)
        root.entryCount = root.store.entries.length
        root.storeMinTs = range ? range.min : NaN
        root.storeMaxTs = range ? range.max : NaN

        var haveWindow = isFinite(root.winT0) && isFinite(root.winT1)
        var visible = haveWindow
                      ? TM.filterByRange(root.store.entries,
                                         root.winT0, root.winT1)
                      : root.store.entries.slice()
        timelineEntries.clear()
        var newMarkers = []
        for (var i = 0; i < visible.length; i++) {
            var e = visible[i]
            var ts = Number(e.timestamp)
            var op = haveWindow
                     ? TM.opacityFor(ts, root.winTm, root.winW)
                     : 1.0
            timelineEntries.append({
                content_hash: String(e.content_hash),
                timestamp:    ts,
                geohash:      String(e.geohash),
                opacity:      op
            })
            var centroid = _decodeGeohashCentroid(e.geohash)
            if (centroid) {
                newMarkers.push({
                    contentHash: String(e.content_hash),
                    timestamp:   ts,
                    geohash:     String(e.geohash),
                    latitude:    centroid.latitude,
                    longitude:   centroid.longitude,
                    opacity:     op
                })
            }
        }
        root.markers = newMarkers
    }

    // Call into the core's decodeGeohash invokable. Returns
    // `{latitude, longitude}` or null on any failure. Geohash → centroid
    // could be implemented client-side (SubmitHelpers.js encodes the
    // inverse), but going through the core keeps wire-format knowledge
    // single-sourced per SPEC §2.
    function _decodeGeohashCentroid(geohash) {
        try {
            var raw = logos.callModule(
                "logos_witness_core", "decodeGeohash", [geohash])
            var parsed = (typeof raw === "string") ? JSON.parse(raw) : raw
            if (!parsed || parsed.ok !== true) return null
            return { latitude: parsed.latitude, longitude: parsed.longitude }
        } catch (e) {
            console.warn("decodeGeohash failed for", geohash, ":", e)
            return null
        }
    }

    function _showDetailFor(contentHash) {
        for (var i = 0; i < root.store.entries.length; i++) {
            if (String(root.store.entries[i].content_hash) === String(contentHash)) {
                root.selectedRef = root.store.entries[i]
                detailDialog.open()
                return
            }
        }
    }
}
