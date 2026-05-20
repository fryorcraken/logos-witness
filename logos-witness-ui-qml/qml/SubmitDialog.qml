import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Dialogs
import "SubmitHelpers.js" as SH

// Phases 3.1 + 3.2 + 3.3: photo picker, geohash drop-pin via MapView,
// timestamp confirm, and submit wire-up to logos_witness_core.
// SPEC §7.2: user must click Submit explicitly — there's no auto-publish
// path. Submit stays disabled until file + pin + timestamp are all set.
//
// No inline photo preview: basecamp installs a DenyAll
// QNetworkAccessManager on every UI plugin's QML engine, so
// `Image.source = file:///…` is rejected for any local file. Filename
// only on the Photo tab; core module reads the bytes on submit.
//
// Default timestamp is "now" (the moment the user opened this dialog),
// not the file mtime. v0 doesn't read EXIF DateTimeOriginal — that's a
// future enhancement noted in the Photo + When tab labels.

Dialog {
    id: submitDialog
    title: "Submit photo"
    modal: true
    width: 760
    height: 640

    // C++ backend (the UI plugin's hybrid side). Used here only to
    // materialise a local preview URL — basecamp's
    // RestrictedUrlInterceptor blocks every URL scheme except qrc and
    // file-under-pluginPath, so the backend has to copy the picked
    // file into its own runtime install dir and hand QML a file://
    // URL rooted there. Owner injects this; left null in tests.
    property var backend: null

    property url    selectedFile: ""
    property string pinGeohash: ""
    property real   pinLatitude: 0.0
    property real   pinLongitude: 0.0
    property bool   hasPin: false
    property var    capturedAt: new Date()

    // Preview state. Set by the file-pick handler via the backend;
    // `previewError` populates whenever the backend can't materialise
    // a file:// URL (file missing, unreadable, cache-write fail, …).
    // The error text is selectable + copyable per the no-silent-
    // fallback rule — when storage is offline the user needs the
    // literal error to paste into bug reports.
    property string previewUrl: ""
    property string previewError: ""

    // When-tab validation. `dateTimeError` is non-empty iff the date or
    // time field's *current* text doesn't parse cleanly. Visible on the
    // When tab and gates Submit. Without this, regex-validators silently
    // rejected partial input (e.g. `2026-05-7`) and `capturedAt` fell
    // back to the dialog-open default — uploads succeeded with a stale
    // timestamp the user thought they'd overridden.
    property string dateTimeError: ""

    property string lastError: ""
    property bool   submitting: false

    // Emitted just before the dialog closes on Submit. Main.qml owns the
    // actual blocking submitPhoto call so it can render an "uploading"
    // banner while the call is in flight (the call holds the QML thread
    // up to 60s waiting on storageUploadDone).
    signal uploadRequested(string filePath, string timestamp, string geohash)

    readonly property bool _canSubmit:
        selectedFile != "" && pinGeohash !== "" && capturedAt !== null
        && dateTimeError === "" && !submitting

    contentItem: ColumnLayout {
        spacing: 8

        TabBar {
            id: tabs
            Layout.fillWidth: true
            TabButton { text: submitDialog.selectedFile == "" ? "Photo" : "Photo ✓" }
            TabButton { text: submitDialog.hasPin               ? "Location ✓" : "Location" }
            // When defaults to "now" on dialog open, so capturedAt is set as
            // soon as the dialog is visible. Mirror the canSubmit clause
            // (`capturedAt !== null`) so users see the same "ready" signal
            // they get for Photo / Location.
            // When-tab marker: ⚠ when a field doesn't parse, ✓ when it
            // does, plain "When" before the user has touched either field.
            TabButton {
                text: submitDialog.dateTimeError !== ""
                      ? "When ⚠"
                      : (submitDialog.capturedAt !== null ? "When ✓" : "When")
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // ---- Photo tab ----
            // Inline preview is wired through the hybrid backend's
            // loadLocalPhotoUrl SLOT: the backend reads the picked
            // file and materialises a copy under its own runtime
            // install dir (the only `file://` root basecamp's
            // RestrictedUrlInterceptor allows for UI-plugin QML),
            // then hands back a file:// URL we can bind directly.
            // Errors come back via the `error:` prefix and surface
            // in a selectable + copyable TextEdit so users can paste
            // them into bug reports without retyping.
            ColumnLayout {
                spacing: 12
                Layout.alignment: Qt.AlignTop

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Pick a JPEG to attach. "
                          + "Then set a location and a time on the next tabs."
                    color: "#666"
                    font.pixelSize: 10
                }

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

                // Preview area. Frame so the photo has a visible
                // bound even before bytes arrive; min-height so a
                // tall portrait JPEG doesn't push the rest of the
                // dialog off-screen.
                Frame {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 240
                    padding: 4
                    background: Rectangle {
                        color: "#f4f4f4"
                        border.color: "#ddd"
                        border.width: 1
                        radius: 4
                    }

                    Item {
                        anchors.fill: parent

                        Image {
                            anchors.fill: parent
                            anchors.margins: 4
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: false
                            source: submitDialog.previewUrl
                            visible: submitDialog.previewUrl !== ""
                                     && submitDialog.previewError === ""
                        }

                        Label {
                            anchors.centerIn: parent
                            visible: submitDialog.selectedFile == ""
                                     && submitDialog.previewError === ""
                            text: "Preview will appear here once you pick a photo."
                            color: "#888"
                            font.pixelSize: 11
                        }
                    }
                }

                // Error surface. Same selectable + copyable pattern
                // used by the detail dialog (fetchPhoto errors).
                RowLayout {
                    Layout.fillWidth: true
                    visible: submitDialog.previewError !== ""
                    spacing: 6
                    TextEdit {
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        selectByKeyboard: true
                        wrapMode: TextEdit.Wrap
                        color: "#c0392b"
                        font.pixelSize: 11
                        text: "Preview error: " + submitDialog.previewError
                    }
                    Button {
                        text: "Copy"
                        flat: true
                        onClicked: {
                            previewClipboardHelper.text =
                                "Preview error: " + submitDialog.previewError
                            previewClipboardHelper.selectAll()
                            previewClipboardHelper.copy()
                        }
                    }
                    TextEdit {
                        id: previewClipboardHelper
                        visible: false
                        width: 0
                        height: 0
                    }
                }
            }

            // ---- Location tab ----
            ColumnLayout {
                spacing: 4
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Click on the map to select where the photo was taken. "
                          + "Future versions will read GPS from the photo automatically."
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
                    text: "Defaults to now. Edit the date and time to backdate. "
                          + "Future versions will read the capture time from "
                          + "the photo automatically — and replace these fields "
                          + "with a proper date/time picker."
                    color: "#666"
                    font.pixelSize: 10
                }

                GridLayout {
                    columns: 2
                    columnSpacing: 8
                    rowSpacing: 6

                    // No `validator:` on these fields — we validate via
                    // SubmitHelpers.validateDateTime on text change, then
                    // either accept the typed value into `capturedAt` or
                    // surface a visible error. The previous RegularExpression
                    // validator silently rejected partial input like
                    // `2026-05-7`, leaving capturedAt stuck at the dialog-
                    // open default while the user thought they'd overridden
                    // it. Silent fallback is now impossible — Submit is
                    // gated by `dateTimeError === ""`.
                    // The TextField `text` is NOT bound to capturedAt —
                    // _revalidateDateTime writes capturedAt back, which
                    // would loop through the binding and re-format the
                    // field mid-edit (e.g. typing "1" for the day → field
                    // becomes "01" → next keystroke "2" appends to →
                    // "012"). Initial value is seeded on dialog open via
                    // onAboutToShow / _resetState; thereafter the field
                    // is whatever the user typed.
                    Label { text: "Date (YYYY-MM-DD):" }
                    TextField {
                        id: dateField
                        Layout.preferredWidth: 140
                        onTextChanged: submitDialog._revalidateDateTime()
                    }

                    Label { text: "Time (HH:MM[:SS]):" }
                    TextField {
                        id: timeField
                        Layout.preferredWidth: 110
                        onTextChanged: submitDialog._revalidateDateTime()
                    }
                }

                // Inline validation feedback. Visible only when the parser
                // rejects the current pair; clears as soon as the user
                // types something valid.
                Label {
                    Layout.fillWidth: true
                    visible: submitDialog.dateTimeError !== ""
                    text: "⚠ " + submitDialog.dateTimeError
                    color: "#c0392b"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
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
        onAccepted: {
            submitDialog.selectedFile = fileDialog.selectedFile
            submitDialog._refreshPreview()
        }
    }

    // Ask the backend to materialise a renderable URL for the picked
    // file. The SLOT returns synchronously (local file copy, no
    // network) so we don't need logos.watch. Failures arrive with
    // an `error:` prefix; QML splits the channel into previewUrl vs
    // previewError so the UI can show one OR the other, never both.
    function _refreshPreview() {
        submitDialog.previewUrl = ""
        submitDialog.previewError = ""
        if (!submitDialog.backend) {
            submitDialog.previewError =
                "Backend not ready — cannot render preview"
            return
        }
        if (submitDialog.selectedFile == "") return
        var raw = submitDialog.backend.loadLocalPhotoUrl(
            submitDialog.selectedFile.toString())
        if (typeof raw === "string" && raw.indexOf("error:") === 0) {
            submitDialog.previewError = raw.substring("error:".length)
        } else if (typeof raw === "string" && raw !== "") {
            submitDialog.previewUrl = raw
        } else {
            submitDialog.previewError =
                "Backend returned no URL (got: " + JSON.stringify(raw) + ")"
        }
    }

    // Parse the When-tab fields. On success: capturedAt is updated and
    // dateTimeError is cleared. On failure: capturedAt is left as-is (so
    // a previously-valid value isn't clobbered while the user is mid-
    // edit) and dateTimeError is set so the inline message + the
    // disabled Submit button signal the problem.
    function _revalidateDateTime() {
        var r = SH.validateDateTime(dateField.text, timeField.text)
        if (r.ok) {
            capturedAt = r.value
            dateTimeError = ""
        } else {
            dateTimeError = r.error
        }
    }

    function _submit() {
        lastError = ""
        var path  = SH.filePathFromUrl(selectedFile)
        var stamp = SH.unixSecondsString(capturedAt)
        // Hand off to Main.qml — it owns the banner state and the
        // blocking submitPhoto call (so the dialog-close paint can flush
        // before the QML thread blocks for the upload).
        uploadRequested(path, stamp, pinGeohash)
        accept()
    }

    // capturedAt default needs to be "the moment the dialog opened", not
    // component-construction time — this Dialog is instantiated once in
    // Main.qml and reused, so without this hook a user who sat on an open
    // dialog for ten minutes would silently submit the app-launch time.
    onAboutToShow: {
        var now = new Date()
        capturedAt = now
        _seedDateTimeFields(now)
    }

    onAccepted: _resetState()
    onRejected: _resetState()
    function _resetState() {
        selectedFile = ""
        pinGeohash = ""
        hasPin = false
        var now = new Date()
        capturedAt = now
        lastError = ""
        dateTimeError = ""
        submitting = false
        previewUrl = ""
        previewError = ""
        _seedDateTimeFields(now)
    }

    // One-shot seed of the date/time fields. Called on dialog open and
    // reset — never reactively, so user typing isn't overwritten mid-
    // edit. Takes the date as an explicit argument so the caller doesn't
    // race the (asynchronous) capturedAt property update; an EXIF auto-
    // fill path in v1 should also call this directly after writing
    // capturedAt to keep the fields in sync.
    function _seedDateTimeFields(d) {
        dateField.text = Qt.formatDate(d, "yyyy-MM-dd")
        var local = new Date(d.getTime() + d.getTimezoneOffset() * 60000)
        timeField.text = Qt.formatTime(local, "HH:mm:ss")
    }
}
