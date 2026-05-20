import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "TimelineModel.js" as TM

// App shell. Routes every core call through the UI plugin's C++
// backend (`logos.module("logos_witness_ui_qml")`) so the QML render
// thread never invokes `logos.callModule` directly — basecamp's bridge
// is sync-only and a single sync call freezes the UI for the duration
// of the upstream RPC. The backend exposes auto-syncing PROPs for the
// refs list and the delivery-ready badge, plus fire-and-forget SLOTs
// + completion SIGNALs for submit + fetchPhoto.
//
// See SPEC §11 for the time-cursor windowing contract and SPEC §7.4
// for the delivery-feed surface. CLAUDE.md "Never block the QML
// thread on logos.callModule" documents the why behind the backend
// routing.

Item {
    id: root
    width: 960
    height: 640

    // ---------------------------------------------------------------
    // Backend
    // ---------------------------------------------------------------

    // Typed replica of the C++ backend running in ui-host. Exposes
    // auto-syncing PROPs (refs, deliveryReady, backendStatus) and
    // SLOTs (submitPhotoAsync, fetchPhotoAsync, decodeGeohash) +
    // matching completion SIGNALs.
    readonly property var backend: logos.module("logos_witness_ui_qml")

    // Tristate: "" idle | "uploading" | "error". On Submit, we
    // immediately stash the request in `pendingUploads` (optimistic
    // row in the timeline) and clear the banner. The banner only
    // appears for error / retry surfaces, NOT during a normal upload —
    // the per-row pending pill is sufficient feedback.
    property string uploadState: ""
    property string uploadError: ""
    // {localId, filePath, timestamp, geohash} for Retry. Keyed so the
    // retry doesn't make the user re-pick file + pin + timestamp.
    property var pendingUpload: null

    // ---------------------------------------------------------------
    // Local optimistic state
    // ---------------------------------------------------------------

    // Refs the backend doesn't yet know about — i.e. submitPhotoAsync
    // calls in flight. Each entry is {localId, content_hash:"",
    // timestamp, geohash, storage_cid:"", pending:true, error?:""}.
    // The pending row is removed when `backend.refs` reports a row
    // with the same content_hash (success), or when a submitDone
    // signal carries the matching localId with ok=false (error).
    property var pendingRefs: []

    // Effective timeline = backend.refs ∪ pendingRefs (deduped by
    // content_hash where the real ref wins, otherwise keyed by
    // localId). Recomputed by _rebuildBindings whenever either side
    // changes. Plain JS array; QML bindings see updates because we
    // re-assign the property after each rebuild.
    property var effectiveRefs: []

    // ListModel mirror driven from effectiveRefs.
    ListModel { id: timelineEntries }
    property var markers: []

    property int  entryCount: 0
    property real storeMinTs: NaN
    property real storeMaxTs: NaN

    // SPEC §11.5: cursor window propagation via direct property
    // bindings (not signal args — settle order matters for the three
    // surfaces to stay consistent across a store mutation).
    readonly property real winT0: isFinite(timeCursor.t0) ? timeCursor.t0 : NaN
    readonly property real winT1: isFinite(timeCursor.t1) ? timeCursor.t1 : NaN
    readonly property real winTm: isFinite(timeCursor.tm) ? timeCursor.tm : NaN
    readonly property real winW:  isFinite(timeCursor.windowW) ? timeCursor.windowW : NaN

    // Detail popup state.
    property var selectedRef: null

    // Live/Offline indicator — bound straight to the backend PROP.
    readonly property bool deliveryReady: backend ? backend.deliveryReady : false

    // ---------------------------------------------------------------
    // Backend signal wiring
    // ---------------------------------------------------------------

    Connections {
        target: root.backend
        // Auto-syncing refs PROP — rebuild the effective list each
        // time the backend pushes an update.
        function onRefsChanged() { root._rebuildEffectiveRefs() }
        // Submit completion. Match on localId; clear the matching
        // pending row (success) or mark it failed (banner).
        function onSubmitDone(localId, contentHash, storageCid,
                              ok, deliveryOk, error) {
            root._onSubmitDone(localId, contentHash, storageCid,
                               ok, deliveryOk, error)
        }
        function onPhotoReady(cid, bytes) {
            // Phase 1: we do not yet display bytes — upstream basecamp
            // issue #189 tracks the bytes-to-Image channel. Stash so
            // we can wire the display side in Phase 2 without
            // re-plumbing the fetch flow.
            detailDialog._onPhotoReady(cid, bytes)
        }
        function onPhotoFailed(cid, errorStr) {
            detailDialog._onPhotoFailed(cid, errorStr)
        }
    }

    // ---------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------

    Component.onCompleted: {
        // No sync work here — backend.initLogos() handles
        // subscribeFeed + initial refresh off-thread. The auto-syncing
        // refs PROP will populate as soon as the backend replica
        // reaches Valid state.
        _rebuildEffectiveRefs()
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

            // Upload-error banner. Visible only on error; normal
            // upload progress lives on the per-row pending pill so
            // the user can keep working while it's in flight.
            Rectangle {
                Layout.fillWidth: true
                visible: root.uploadState === "error"
                color: "#fdecea"
                border.color: "#c0392b"
                border.width: 1
                radius: 4
                implicitHeight: bannerRow.implicitHeight + 12
                RowLayout {
                    id: bannerRow
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pixelSize: 11
                        color: "#c0392b"
                        text: "Upload failed: " + root.uploadError
                    }
                    Button {
                        visible: root.pendingUpload !== null
                        text: "Retry"
                        Layout.preferredHeight: 24
                        onClicked: root._retryPendingUpload()
                    }
                    Button {
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
                // Live/Offline pill — backend.deliveryReady PROP.
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
                    text: {
                        var total = root.entryCount
                        if (!isFinite(root.winT0) || !isFinite(root.winT1)) {
                            return total + " ref" + (total === 1 ? "" : "s")
                        }
                        var shown = TM.filterByRange(
                            root.effectiveRefs, root.winT0, root.winT1).length
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
                    readonly property bool _inWindow:
                        !isFinite(root.winT0) || !isFinite(root.winT1)
                        || (model.timestamp >= root.winT0
                            && model.timestamp <= root.winT1)
                    visible: _inWindow
                    height: _inWindow ? implicitHeight : 0
                    opacity: isFinite(root.winTm) && isFinite(root.winW)
                             ? TM.opacityFor(model.timestamp, root.winTm, root.winW)
                             : 1.0
                    enabled: !model.pending
                    contentItem: ColumnLayout {
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Label {
                                text: TM.formatTimestamp(model.timestamp)
                                font.pixelSize: 11
                                font.bold: true
                                Layout.fillWidth: true
                            }
                            // Per-row pending pill. Set by the optimistic
                            // insert in _onUploadRequested; cleared when
                            // the matching ref appears in backend.refs.
                            Rectangle {
                                visible: model.pending === true
                                color: "#fff7e0"
                                border.color: "#d39e00"
                                border.width: 1
                                radius: 6
                                implicitWidth: pendingPill.implicitWidth + 10
                                implicitHeight: 14
                                Label {
                                    id: pendingPill
                                    anchors.centerIn: parent
                                    text: "uploading…"
                                    font.pixelSize: 9
                                    color: "#7a5800"
                                }
                            }
                        }
                        Label {
                            text: "geohash " + model.geohash
                                  + (model.content_hash
                                     ? "  ·  hash " + TM.shortHash(model.content_hash)
                                     : "")
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
                    onClicked: {
                        if (model.pending) return
                        root._showDetailFor(model.content_hash)
                    }
                }
            }

            Label {
                readonly property int _visibleCount: {
                    if (root.entryCount === 0) return 0
                    if (!isFinite(root.winT0) || !isFinite(root.winT1)) return root.entryCount
                    return TM.filterByRange(
                        root.effectiveRefs, root.winT0, root.winT1).length
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

    Button {
        id: submitButton
        text: "Submit photo…"
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 16
        highlighted: true
        onClicked: submitDialog.open()
    }

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
            refs: root.effectiveRefs
            entryCount: root.entryCount
            storeMinTs: root.storeMinTs
            storeMaxTs: root.storeMaxTs
        }
    }

    SubmitDialog {
        id: submitDialog
        anchors.centerIn: parent
        backend: root.backend
        onUploadRequested: function (filePath, timestamp, geohash) {
            root._onUploadRequested(filePath, timestamp, geohash)
        }
    }

    // Detail dialog. Phase 1 keeps the metadata view; photo bytes
    // arrive via backend.photoReady but rendering them is Phase 2 —
    // see upstream basecamp issue #189 (bytes-to-Image channel).
    Dialog {
        id: detailDialog
        modal: true
        title: "Reference"
        standardButtons: Dialog.Close
        anchors.centerIn: parent
        width: 480
        height: 520

        property string photoCid: ""
        property bool   photoLoading: false
        property string photoError: ""
        // Phase 2: rendering. For now we just count bytes so the dev
        // loop can confirm the fetch worked end-to-end.
        property int    photoByteCount: 0

        function _onPhotoReady(cid, bytes) {
            if (cid !== detailDialog.photoCid) return
            detailDialog.photoLoading = false
            detailDialog.photoError = ""
            detailDialog.photoByteCount = bytes.length
        }
        function _onPhotoFailed(cid, errorStr) {
            if (cid !== detailDialog.photoCid) return
            detailDialog.photoLoading = false
            detailDialog.photoError = errorStr
        }

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

            // Photo preview area. Phase 1 surfaces fetch progress +
            // raw byte count only; rendering lands in Phase 2 once
            // the bytes-to-Image channel is settled (upstream #189).
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 200
                visible: detailDialog.photoLoading
                         || detailDialog.photoByteCount > 0

                BusyIndicator {
                    anchors.centerIn: parent
                    running: detailDialog.photoLoading
                    visible: detailDialog.photoLoading
                }

                Label {
                    anchors.centerIn: parent
                    visible: !detailDialog.photoLoading
                             && detailDialog.photoByteCount > 0
                    text: "Photo fetched: "
                          + detailDialog.photoByteCount + " bytes"
                          + "\n(rendering pending upstream #189)"
                    color: "#555"
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: detailDialog.photoError !== ""
                spacing: 6
                TextEdit {
                    Layout.fillWidth: true
                    readOnly: true
                    selectByMouse: true
                    selectByKeyboard: true
                    wrapMode: TextEdit.Wrap
                    color: "#c0392b"
                    font.pixelSize: 11
                    text: detailDialog.photoError
                }
                Button {
                    text: "Copy"
                    flat: true
                    onClicked: {
                        clipboardHelper.text = detailDialog.photoError
                        clipboardHelper.selectAll()
                        clipboardHelper.copy()
                    }
                }
                TextEdit {
                    id: clipboardHelper
                    visible: false
                    width: 0
                    height: 0
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#888"
                font.pixelSize: 11
                visible: !detailDialog.photoLoading
                         && detailDialog.photoByteCount === 0
                         && detailDialog.photoError === ""
                text: root.selectedRef && root.selectedRef.storage_cid
                      ? "Photo unavailable."
                      : "No photo in storage (pre-Storage reference)."
            }
        }
    }

    // ---------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------

    // Optimistic submit. Insert a pending row immediately so the user
    // sees their click reflected on the timeline, fire the backend
    // SLOT, then resolve on submitDone.
    function _onUploadRequested(filePath, timestamp, geohash) {
        if (!backend) {
            root.uploadError = "Backend not ready"
            root.uploadState = "error"
            return
        }
        var localId = "u_" + Date.now() + "_" + Math.floor(Math.random() * 1e6)
        var pending = {
            localId:      localId,
            content_hash: "",
            timestamp:    Number(timestamp),
            geohash:      String(geohash),
            storage_cid:  "",
            pending:      true,
            filePath:     filePath
        }
        var copy = root.pendingRefs.slice()
        copy.push(pending)
        root.pendingRefs = copy
        root.pendingUpload = {
            localId:   localId,
            filePath:  filePath,
            timestamp: String(timestamp),
            geohash:   String(geohash)
        }
        root.uploadState = ""
        root.uploadError = ""
        _rebuildEffectiveRefs()
        backend.submitPhotoAsync(
            localId, filePath, String(timestamp), String(geohash))
    }

    function _retryPendingUpload() {
        var p = root.pendingUpload
        if (!p || !backend) return
        // Clear error pill; pending row is still in pendingRefs.
        root.uploadState = ""
        root.uploadError = ""
        backend.submitPhotoAsync(
            p.localId, p.filePath, p.timestamp, p.geohash)
    }

    function _onSubmitDone(localId, contentHash, storageCid,
                           ok, deliveryOk, error) {
        // Drop matching pending row (always — success and error both
        // remove the row; on error the user can Retry via the banner
        // using the cached pendingUpload, which lands a fresh
        // pending row).
        var kept = []
        for (var i = 0; i < root.pendingRefs.length; i++) {
            if (root.pendingRefs[i].localId !== localId) {
                kept.push(root.pendingRefs[i])
            }
        }
        root.pendingRefs = kept
        _rebuildEffectiveRefs()

        if (!ok) {
            root.uploadError = error && error !== ""
                ? error : "submitPhoto failed (no error message)"
            root.uploadState = "error"
            return
        }
        // Upload OK but broadcast failed → surface as a banner
        // warning, keep pendingUpload to allow a Retry that
        // republishes.
        if (!deliveryOk) {
            root.uploadError = "Saved locally — not broadcast: "
                + (error && error !== "" ? error : "delivery offline")
            root.uploadState = "error"
            return
        }
        // Full success — clear retry payload + banner.
        root.pendingUpload = null
        root.uploadState = ""
        root.uploadError = ""
    }

    // Merge backend.refs (truth) with pendingRefs (optimistic).
    // Dedup by content_hash; a real ref always wins over a pending
    // row, but pending rows without a content_hash yet are kept.
    function _rebuildEffectiveRefs() {
        var truth = backend && backend.refs ? backend.refs : []
        var seenHashes = {}
        var merged = []
        for (var i = 0; i < truth.length; i++) {
            var r = truth[i]
            merged.push(r)
            if (r && r.content_hash) seenHashes[String(r.content_hash)] = true
        }
        for (var j = 0; j < root.pendingRefs.length; j++) {
            var p = root.pendingRefs[j]
            if (p.content_hash && seenHashes[String(p.content_hash)]) continue
            merged.push(p)
        }
        root.effectiveRefs = merged
        _rebuildBindings()
    }

    function _rebuildBindings() {
        var range = TM.storeTimeRange({ entries: root.effectiveRefs })
        root.entryCount = root.effectiveRefs.length
        root.storeMinTs = range ? range.min : NaN
        root.storeMaxTs = range ? range.max : NaN

        timelineEntries.clear()
        var newMarkers = []
        for (var i = 0; i < root.effectiveRefs.length; i++) {
            var e = root.effectiveRefs[i]
            var ts = Number(e.timestamp)
            timelineEntries.append({
                content_hash: String(e.content_hash || ""),
                timestamp:    ts,
                geohash:      String(e.geohash),
                storage_cid:  String(e.storage_cid || ""),
                pending:      e.pending === true
            })
            var centroid = _decodeGeohashCentroid(e.geohash)
            if (centroid) {
                newMarkers.push({
                    contentHash: String(e.content_hash || ""),
                    timestamp:   ts,
                    geohash:     String(e.geohash),
                    latitude:    centroid.latitude,
                    longitude:   centroid.longitude
                })
            }
        }
        root.markers = newMarkers
    }

    // Per-geohash centroid cache. Same geohash always decodes to the
    // same centroid, so we cache aggressively — but the backend.
    // decodeGeohash call is async over QtRO (no sync path from QML),
    // so cache misses arrive on a callback and we trigger a fresh
    // _rebuildBindings tick to re-walk the refs with the new entry
    // populated. `undefined` = not yet asked; `null` = asked and the
    // decode failed; object = asked and succeeded.
    property var _centroidCache: ({})

    function _decodeGeohashCentroid(geohash) {
        if (!geohash) return null
        var cached = root._centroidCache[geohash]
        if (cached !== undefined) return cached
        if (!backend) return null
        // Mark as "in flight" so we don't fire concurrent watches for
        // the same geohash. JS lookup will see this as a truthy
        // object and skip the rebuild path on the next walk; once
        // the watch resolves we overwrite with the real result.
        root._centroidCache[geohash] = { _pending: true }
        var pending = backend.decodeGeohash(geohash)
        logos.watch(pending,
            function (raw) {
                if (!raw || raw.ok !== true) {
                    root._centroidCache[geohash] = null
                } else {
                    root._centroidCache[geohash] =
                        { latitude: raw.latitude, longitude: raw.longitude }
                }
                root._rebuildBindings()
            },
            function (err) {
                console.warn("decodeGeohash failed for", geohash, ":", err)
                root._centroidCache[geohash] = null
                root._rebuildBindings()
            })
        return null  // initial walk: marker will appear after the
                    // async resolve + rebuild
    }

    function _showDetailFor(contentHash) {
        for (var i = 0; i < root.effectiveRefs.length; i++) {
            if (String(root.effectiveRefs[i].content_hash) === String(contentHash)) {
                root.selectedRef = root.effectiveRefs[i]
                detailDialog.photoCid = ""
                detailDialog.photoError = ""
                detailDialog.photoLoading = false
                detailDialog.photoByteCount = 0

                var cid = root.effectiveRefs[i].storage_cid
                if (cid && cid !== "" && backend) {
                    detailDialog.photoLoading = true
                    detailDialog.photoCid = cid
                    backend.fetchPhotoAsync(cid)
                }
                detailDialog.open()
                return
            }
        }
    }
}
