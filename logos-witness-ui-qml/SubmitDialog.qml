import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Dialogs

// Phase 3.1 + 3.2 + 3.3: photo picker, geohash drop-pin via MapView,
// timestamp confirm, and submit wire-up to logos_witness_core.
// SPEC §7.2: user must click Submit explicitly — there's no auto-publish
// path. Submit stays disabled until file + pin + timestamp are all set.
//
// Default timestamp is "now" (the moment the user opened this dialog),
// not the file mtime. v0 cannot read mtime from a `file://` URL without
// adding a Q_INVOKABLE to logos_witness_core or a C++ helper to the UI
// module — both of those are real interface changes not justified for
// what is, in practice, "what time was the photo taken?". File mtime is
// usually download/transfer time anyway. Users adjust via the picker.

Dialog {
    id: submitDialog
    title: "Submit photo"
    modal: true
    width: 760
    height: 640

    property url    selectedFile: ""
    property string pinGeohash: ""
    property real   pinLatitude: 0.0
    property real   pinLongitude: 0.0
    property bool   hasPin: false
    property var    capturedAt: new Date()

    property string lastError: ""
    property bool   submitting: false

    // Mirror of SubmitHelpers.js — see that file for canonical impl + tests.
    // Inlined because the lgx UI builder only globs `*.qml` into the bundle.
    function _unixSecondsString(date) {
        return Math.floor(date.getTime() / 1000).toString()
    }
    function _filePathFromUrl(url) {
        var s = url.toString()
        if (s.indexOf("file://") === 0) return s.substring(7)
        return s
    }

    readonly property bool _canSubmit:
        selectedFile != "" && pinGeohash !== "" && capturedAt !== null
        && !submitting

    contentItem: ColumnLayout {
        spacing: 8

        TabBar {
            id: tabs
            Layout.fillWidth: true
            TabButton { text: submitDialog.selectedFile == "" ? "Photo" : "Photo ✓" }
            TabButton { text: submitDialog.hasPin               ? "Location ✓" : "Location" }
            TabButton { text: "When" }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // ---- Photo tab ----
            ColumnLayout {
                spacing: 8
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: "Choose photo…"
                        onClicked: fileDialog.open()
                    }
                    Label {
                        Layout.fillWidth: true
                        text: submitDialog.selectedFile == ""
                              ? "(no file selected)"
                              : submitDialog.selectedFile.toString()
                        elide: Text.ElideMiddle
                        color: "#444"
                        font.pixelSize: 11
                    }
                }
                Frame {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Image {
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false
                        source: submitDialog.selectedFile
                        visible: submitDialog.selectedFile != ""
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: submitDialog.selectedFile == ""
                        text: "Pick a JPEG to preview.\nLocation tab to drop a pin.\nWhen tab to set the time.\nThen click Submit."
                        horizontalAlignment: Text.AlignHCenter
                        color: "#888"
                        font.pixelSize: 12
                    }
                }
            }

            // ---- Location tab ----
            ColumnLayout {
                spacing: 4
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Click on the map to drop a pin. Zoom is capped at z=9 — "
                          + "geohash precision is fixed at 8 (~20 m) per SPEC §2; "
                          + "use the Copy buttons to paste lat/lon into another app."
                    wrapMode: Text.WordWrap
                    color: "#666"
                    font.pixelSize: 10
                }
                MapView {
                    id: pickerMap
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    onPinned: function (geohash, latitude, longitude) {
                        submitDialog.pinGeohash   = geohash
                        submitDialog.pinLatitude  = latitude
                        submitDialog.pinLongitude = longitude
                        submitDialog.hasPin       = true
                    }
                }
            }

            // ---- When tab ----
            ColumnLayout {
                spacing: 12
                Layout.alignment: Qt.AlignTop

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Defaults to now (the time you opened this dialog). "
                          + "Edit the values below to set a different capture time. "
                          + "v0 stores this as integer unix seconds; subseconds are dropped."
                    color: "#666"
                    font.pixelSize: 10
                }

                GridLayout {
                    columns: 2
                    columnSpacing: 8
                    rowSpacing: 6

                    Label { text: "Date (YYYY-MM-DD):" }
                    TextField {
                        id: dateField
                        Layout.preferredWidth: 140
                        text: Qt.formatDate(submitDialog.capturedAt, "yyyy-MM-dd")
                        validator: RegularExpressionValidator {
                            regularExpression: /^\d{4}-\d{2}-\d{2}$/
                        }
                        onEditingFinished: submitDialog._recomputeCapturedAt()
                    }

                    Label { text: "Time (HH:MM:SS, UTC):" }
                    TextField {
                        id: timeField
                        Layout.preferredWidth: 110
                        text: Qt.formatTime(
                            new Date(submitDialog.capturedAt.getTime()
                                     + submitDialog.capturedAt.getTimezoneOffset() * 60000),
                            "HH:mm:ss")
                        validator: RegularExpressionValidator {
                            regularExpression: /^\d{2}:\d{2}:\d{2}$/
                        }
                        onEditingFinished: submitDialog._recomputeCapturedAt()
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: "→ unix seconds: " + submitDialog._unixSecondsString(submitDialog.capturedAt)
                    font.family: "monospace"
                    color: "#444"
                    font.pixelSize: 11
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ---- Error / status row ----
        Label {
            Layout.fillWidth: true
            visible: submitDialog.lastError !== ""
            text: "Error: " + submitDialog.lastError
            wrapMode: Text.WordWrap
            color: "#c0392b"
            font.pixelSize: 11
        }

        // ---- Footer: Cancel + Submit. Replaces standardButtons so Submit
        //      can be disabled until all three inputs are present. SPEC §7.2:
        //      no auto-publish; user must click. ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Item { Layout.fillWidth: true }
            Button {
                text: "Cancel"
                onClicked: submitDialog.reject()
            }
            Button {
                text: submitDialog.submitting ? "Submitting…" : "Submit"
                enabled: submitDialog._canSubmit
                highlighted: true
                onClicked: submitDialog._submit()
            }
        }
    }

    FileDialog {
        id: fileDialog
        title: "Pick a photo"
        nameFilters: ["JPEG images (*.jpg *.jpeg)", "All files (*)"]
        onAccepted: submitDialog.selectedFile = fileDialog.selectedFile
    }

    function _recomputeCapturedAt() {
        var d = dateField.text
        var t = timeField.text
        if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || !/^\d{2}:\d{2}:\d{2}$/.test(t)) return
        var parts = d.split("-")
        var tparts = t.split(":")
        var iso = parts[0] + "-" + parts[1] + "-" + parts[2]
                  + "T" + tparts[0] + ":" + tparts[1] + ":" + tparts[2] + "Z"
        var parsed = new Date(iso)
        if (!isNaN(parsed.getTime())) capturedAt = parsed
    }

    function _submit() {
        lastError = ""
        submitting = true
        try {
            var path  = _filePathFromUrl(selectedFile)
            var stamp = _unixSecondsString(capturedAt)
            var result = logos.callModule(
                "logos_witness_core", "submitPhoto",
                [path, stamp, pinGeohash])
            // The submitPhoto contract returns { ok: true, content_hash } via
            // QVariantMap. In the JSON marshalling some hosts wrap that in
            // { result: {...}, status: "ok" } — accept both shapes.
            var ok = (result && result.ok === true)
                  || (result && result.result && result.result.ok === true)
            if (!ok) {
                lastError = "submitPhoto returned: " + JSON.stringify(result)
                submitting = false
                return
            }
            accept()  // closes the dialog with Accepted result
        } catch (e) {
            lastError = e.toString()
            submitting = false
        }
    }

    // capturedAt default needs to be "the moment the dialog opened", not
    // component-construction time — this Dialog is instantiated once in
    // Main.qml and reused, so without this hook a user who sat on an open
    // dialog for ten minutes would silently submit the app-launch time.
    onAboutToShow: capturedAt = new Date()

    onAccepted: _resetState()
    onRejected: _resetState()
    function _resetState() {
        selectedFile = ""
        pinGeohash = ""
        hasPin = false
        capturedAt = new Date()
        lastError = ""
        submitting = false
    }
}
