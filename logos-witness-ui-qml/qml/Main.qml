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

    // Live/Offline indicator for the Delivery feed. Refreshed every
    // `refreshTimer` tick (5s) plus on init via _probeDelivery. The core
    // exposes deliveryReady() as a sync invokable so the UI doesn't have
    // to track the lifecycle itself.
    property bool deliveryReady: false

    // Upload status — drives the banner above the timeline list.
    // `uploadState` is "" (idle) | "uploading" | "error". `pendingUpload`
    // is the {filePath, timestamp, geohash} payload kept around for two
    // purposes: (a) handed to `_runPendingUpload` after the dispatcher
    // timer fires; (b) retained on failure so the user can hit Retry
    // from the banner instead of re-picking the photo + pin + timestamp.
    // Cleared on successful upload or on explicit dismiss (✕).
    property string uploadState: ""
    property string uploadError: ""
    property var    pendingUpload: null

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
        onTriggered: { root._refreshFromCore(); root._probeDelivery() }
    }

    // One-shot dispatcher for the blocking submitPhoto call. SubmitDialog
    // emits uploadRequested → we stash the payload + flip uploadState to
    // "uploading" + start this timer with a tiny delay; when it fires the
    // dialog has already closed and the banner has painted, so the
    // QML-thread block during the synchronous logos.callModule is visible
    // to the user as "uploading…" rather than an unexplained freeze. 40 ms
    // is empirical: `Qt.callLater` and a 0-interval Timer both fire before
    // the dialog-close paint flushes under basecamp's Qt6 build, so the
    // banner doesn't render until *after* the block ends — defeating the
    // entire point. 40 ms is the smallest delay that reliably yields a
    // paint cycle here.
    Timer {
        id: uploadDispatcher
        interval: 40
        repeat: false
        onTriggered: root._runPendingUpload()
    }

    Component.onCompleted: {
        // Warm the Delivery subscriber so peer broadcasts are caught
        // from this instance's first moment. Idempotent on the core side
        // (see subscribeFeed); failure flips the Live/Offline badge via
        // _probeDelivery so the user can see the degraded state.
        try { logos.callModule("logos_witness_core", "subscribeFeed", []) }
        catch (e) { console.warn("subscribeFeed failed:", e) }
        root._refreshFromCore()
        root._probeDelivery()
    }

    // ---------------------------------------------------------------
    // Layout
    // ---------------------------------------------------------------

    MapView {
        id: mapView
        anchors.fill: parent
        pickable: false
        markers: root.markers
        cursorT0: root.winT0
        cursorT1: root.winT1
        cursorTm: root.winTm
        cursorW:  root.winW
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

            // Upload status banner — visible only while submitPhoto is
            // in flight or during the brief error-display window after a
            // failure. Sits above the list so it can't be scrolled off.
            Rectangle {
                Layout.fillWidth: true
                visible: root.uploadState !== ""
                color: root.uploadState === "error" ? "#fdecea" : "#eaf3fd"
                border.color: root.uploadState === "error" ? "#c0392b" : "#3498db"
                border.width: 1
                radius: 4
                implicitHeight: bannerRow.implicitHeight + 12
                RowLayout {
                    id: bannerRow
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8
                    BusyIndicator {
                        running: root.uploadState === "uploading"
                        visible: root.uploadState === "uploading"
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pixelSize: 11
                        color: root.uploadState === "error" ? "#c0392b" : "#1d4f7d"
                        text: root.uploadState === "uploading"
                              ? "Uploading photo to Logos Storage…"
                              : ("Upload failed: " + root.uploadError)
                    }
                    Button {
                        visible: root.uploadState === "error"
                                 && root.pendingUpload !== null
                        text: "Retry"
                        Layout.preferredHeight: 24
                        onClicked: {
                            root.uploadState = "uploading"
                            root.uploadError = ""
                            uploadDispatcher.start()
                        }
                    }
                    Button {
                        visible: root.uploadState === "error"
                        text: "✕"
                        flat: true
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        onClicked: {
                            root.pendingUpload = null
                            root.uploadState = ""
                            root.uploadError = ""
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: "Timeline"
                    font.bold: true
                    Layout.fillWidth: true
                }
                // Live/Offline pill. Live = delivery_module subscribed
                // and reachable; Offline = init/subscribe failed (peer
                // broadcasts won't land here). Bound to root.deliveryReady,
                // which _probeDelivery() refreshes every 5s.
                Rectangle {
                    Layout.preferredHeight: 16
                    implicitWidth: deliveryPill.implicitWidth + 12
                    radius: 8
                    color: root.deliveryReady ? "#e7f7ec" : "#fbeaea"
                    border.color: root.deliveryReady ? "#2ecc71" : "#c0392b"
                    border.width: 1
                    Label {
                        id: deliveryPill
                        anchors.centerIn: parent
                        text: root.deliveryReady ? "● Live" : "● Offline"
                        font.pixelSize: 10
                        color: root.deliveryReady ? "#1e7a3c" : "#a13226"
                    }
                }
                Label {
                    // "5 refs" when the cursor's window holds them all,
                    // "3 of 5 refs" when the window is narrower. With
                    // delegate-local visibility binding, `shown` is
                    // counted by scanning the store against the active
                    // window — the ListModel itself is unfiltered.
                    text: {
                        var total = root.entryCount
                        if (!isFinite(root.winT0) || !isFinite(root.winT1)) {
                            return total + " ref" + (total === 1 ? "" : "s")
                        }
                        var shown = TM.filterByRange(
                            root.store.entries, root.winT0, root.winT1).length
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
                    // Per-row visibility + opacity bound off the cursor
                    // state (SPEC §11.5). Computing here, not in
                    // _rebuildBindings, means dragging the cursor only
                    // re-evaluates these two bindings on each existing
                    // delegate — no list churn, no flicker.
                    readonly property bool _inWindow:
                        !isFinite(root.winT0) || !isFinite(root.winT1)
                        || (model.timestamp >= root.winT0
                            && model.timestamp <= root.winT1)
                    visible: _inWindow
                    height: _inWindow ? implicitHeight : 0
                    opacity: isFinite(root.winTm) && isFinite(root.winW)
                             ? TM.opacityFor(model.timestamp, root.winTm, root.winW)
                             : 1.0
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
                        Label {
                            visible: model.storage_cid && model.storage_cid !== ""
                            text: "cid " + TM.shortCid(model.storage_cid)
                            font.family: "monospace"
                            font.pixelSize: 10
                            color: "#777"
                        }
                    }
                    onClicked: root._showDetailFor(model.content_hash)
                }
            }

            Label {
                // Visible when the active cursor window is empty (or when
                // the store is). Cheap to recompute on every drag tick
                // (single store scan) — see also the counter label above.
                readonly property int _visibleCount: {
                    if (root.entryCount === 0) return 0
                    if (!isFinite(root.winT0) || !isFinite(root.winT1)) return root.entryCount
                    return TM.filterByRange(
                        root.store.entries, root.winT0, root.winT1).length
                }
                visible: _visibleCount === 0
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
            // Drag-friendly: only mutate window scalars here. The marker
            // + timeline backing models are stable; their delegates bind
            // opacity directly off winTm/winW so dragging just repaints
            // existing items rather than rebuilding the whole list.
            onWindowChanged: function (t0, t1) {
                root.winT0 = t0
                root.winT1 = t1
                root.winTm = (t0 + t1) / 2
                root.winW  = t1 - t0
            }
        }
    }

    SubmitDialog {
        id: submitDialog
        anchors.centerIn: parent
        onUploadRequested: function (filePath, timestamp, geohash) {
            root.uploadState   = "uploading"
            root.uploadError   = ""
            root.pendingUpload = {
                filePath:  filePath,
                timestamp: timestamp,
                geohash:   geohash
            }
            uploadDispatcher.start()
        }
    }

    // Marker / row detail popup. Phase 5: fetches the photo from Logos
    // Storage via core.fetchPhoto(cid) and renders it as a base64 data URL
    // (workaround for basecamp's sandboxed QNetworkAccessManager blocking
    // file:// URLs). Falls back to metadata-only when storage_cid is empty
    // (pre-Storage refs) or when the fetch fails.
    Dialog {
        id: detailDialog
        modal: true
        title: "Reference"
        standardButtons: Dialog.Close
        anchors.centerIn: parent
        width: 480
        height: 520

        property string photoDataUrl: ""
        property bool   photoLoading: false
        property string photoError: ""

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
                visible: root.selectedRef && root.selectedRef.storage_cid
                text: root.selectedRef && root.selectedRef.storage_cid
                      ? ("storage_cid:\n" + root.selectedRef.storage_cid)
                      : ""
                font.family: "monospace"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            // Photo preview from Storage.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 200
                visible: detailDialog.photoDataUrl !== "" || detailDialog.photoLoading

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    source: detailDialog.photoDataUrl
                    visible: detailDialog.photoDataUrl !== ""
                }

                BusyIndicator {
                    anchors.centerIn: parent
                    running: detailDialog.photoLoading
                    visible: detailDialog.photoLoading
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#c0392b"
                font.pixelSize: 11
                visible: detailDialog.photoError !== ""
                text: detailDialog.photoError
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#888"
                font.pixelSize: 11
                visible: detailDialog.photoDataUrl === ""
                        && !detailDialog.photoLoading
                        && detailDialog.photoError === ""
                text: root.selectedRef && root.selectedRef.storage_cid
                      ? "Photo unavailable."
                      : "No photo in storage (pre-Storage reference)."
            }
        }
    }

    // ---------------------------------------------------------------
    // Core wiring
    // ---------------------------------------------------------------

    // Runs the synchronous submitPhoto call deferred from
    // SubmitDialog.uploadRequested. Resolves to either uploadState === ""
    // (success — banner clears, timeline refreshes and now shows the new
    // entry with its CID) or "error" (banner stays until the user clicks
    // the Retry button, the ✕ dismiss button, or submits a fresh photo).
    // On failure `pendingUpload` is retained so Retry can re-fire without
    // making the user re-pick file + pin + timestamp.
    function _runPendingUpload() {
        var p = root.pendingUpload
        if (!p) { root.uploadState = ""; return }
        try {
            var result = logos.callModule(
                "logos_witness_core", "submitPhoto",
                [p.filePath, p.timestamp, p.geohash])
            var parsed = null
            try { parsed = (typeof result === "string")
                           ? JSON.parse(result) : result } catch (_) {}
            if (!parsed || parsed.ok !== true) {
                root.uploadError = parsed && parsed.error
                    ? String(parsed.error)
                    : ("Submit failed. Core returned: " + JSON.stringify(result))
                root.uploadState = "error"
                return
            }
            root.pendingUpload = null
            // SPEC §7 / no-silent-fallbacks: a successful upload that
            // didn't broadcast is reported as a soft warning. The ref
            // is durable locally; just no peers will see it until the
            // next time this instance has Delivery connectivity and
            // republishes. Treat as a self-clearing banner so the user
            // notices but isn't blocked.
            if (parsed.delivery_ok === false) {
                root.uploadError = "Saved locally — not broadcast: "
                    + (parsed.delivery_error
                       ? String(parsed.delivery_error) : "delivery offline")
                root.uploadState = "error"
            } else {
                root.uploadState = ""
                root.uploadError = ""
            }
            root._refreshFromCore()
            root._probeDelivery()
        } catch (e) {
            root.uploadError = e.toString()
            root.uploadState = "error"
        }
    }

    // Pull the full list from the core and merge it into the local
    // store. Cheap in v0 (stub keeps everything in process memory); when
    // Storage + Delivery are real this stays correct because dedupe-by-
    // content_hash keeps re-seeding idempotent.
    // Poll the core's deliveryReady() invokable and update the badge.
    // Cheap: sync invokable, just reads a bool. Called once on init
    // and on every refreshTimer tick so the badge tracks reconnects.
    function _probeDelivery() {
        try {
            var v = logos.callModule(
                "logos_witness_core", "deliveryReady", [])
            // Bridge may JSON-encode the bool as the string "true"/"false".
            var parsed = (typeof v === "string") ? JSON.parse(v) : v
            root.deliveryReady = (parsed === true)
        } catch (e) {
            root.deliveryReady = false
        }
    }

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

    // Rebuild marker + timeline backing models from `store`. Runs only
    // when the store contents change (seed/merge), NOT on every cursor
    // pan — that lets the MapItemView and ListView keep their delegate
    // identity across drag ticks. Per-row/per-marker opacity and
    // visibility are computed inside the delegates from `winTm`/`winW`,
    // so dragging mutates only those two scalars and the existing
    // delegates re-paint smoothly without being destroyed + recreated.
    function _rebuildBindings() {
        var range = TM.storeTimeRange(root.store)
        root.entryCount = root.store.entries.length
        root.storeMinTs = range ? range.min : NaN
        root.storeMaxTs = range ? range.max : NaN

        timelineEntries.clear()
        var newMarkers = []
        for (var i = 0; i < root.store.entries.length; i++) {
            var e = root.store.entries[i]
            var ts = Number(e.timestamp)
            timelineEntries.append({
                content_hash: String(e.content_hash),
                timestamp:    ts,
                geohash:      String(e.geohash),
                storage_cid:  String(e.storage_cid || "")
            })
            var centroid = _decodeGeohashCentroid(e.geohash)
            if (centroid) {
                newMarkers.push({
                    contentHash: String(e.content_hash),
                    timestamp:   ts,
                    geohash:     String(e.geohash),
                    latitude:    centroid.latitude,
                    longitude:   centroid.longitude
                })
            }
        }
        root.markers = newMarkers
    }

    // Geohash → centroid via the core's decodeGeohash invokable. Memoized
    // per geohash because the same geohash always decodes to the same
    // centroid (it's a static spatial encoding); without the cache,
    // `_rebuildBindings` would re-RPC every ref on every store refresh.
    property var _centroidCache: ({})
    function _decodeGeohashCentroid(geohash) {
        var cached = root._centroidCache[geohash]
        if (cached !== undefined) return cached
        try {
            var raw = logos.callModule(
                "logos_witness_core", "decodeGeohash", [geohash])
            var parsed = (typeof raw === "string") ? JSON.parse(raw) : raw
            if (!parsed || parsed.ok !== true) {
                root._centroidCache[geohash] = null
                return null
            }
            var c = { latitude: parsed.latitude, longitude: parsed.longitude }
            root._centroidCache[geohash] = c
            return c
        } catch (e) {
            console.warn("decodeGeohash failed for", geohash, ":", e)
            root._centroidCache[geohash] = null
            return null
        }
    }

    function _showDetailFor(contentHash) {
        for (var i = 0; i < root.store.entries.length; i++) {
            if (String(root.store.entries[i].content_hash) === String(contentHash)) {
                root.selectedRef = root.store.entries[i]
                detailDialog.photoDataUrl = ""
                detailDialog.photoError = ""
                detailDialog.photoLoading = false

                // Fetch photo from Storage if we have a CID.
                var cid = root.store.entries[i].storage_cid
                if (cid && cid !== "") {
                    detailDialog.photoLoading = true
                    _fetchPhoto(cid)
                }

                detailDialog.open()
                return
            }
        }
    }

    function _fetchPhoto(cid) {
        try {
            var raw = logos.callModule(
                "logos_witness_core", "fetchPhoto", [cid])
            var parsed = (typeof raw === "string") ? JSON.parse(raw) : raw
            if (parsed && parsed.ok === true && parsed.data_url) {
                detailDialog.photoDataUrl = parsed.data_url
            } else {
                detailDialog.photoError = parsed && parsed.error
                    ? parsed.error : "fetchPhoto returned an unexpected result"
            }
        } catch (e) {
            detailDialog.photoError = e.toString()
        } finally {
            detailDialog.photoLoading = false
        }
    }
}
