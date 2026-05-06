import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Dialogs

// Phase 3.1 + 3.2: file picker + preview, plus geohash drop-pin via
// MapView. Submit button is wired in Phase 3.3 — needs the timestamp
// confirm. Cancel-only here.

Dialog {
    id: submitDialog
    title: "Submit photo"
    modal: true
    width: 760
    height: 600
    standardButtons: Dialog.Cancel

    property url    selectedFile: ""
    property string pinGeohash: ""
    property real   pinLatitude: 0.0
    property real   pinLongitude: 0.0
    property bool   hasPin: false

    contentItem: ColumnLayout {
        spacing: 8

        TabBar {
            id: tabs
            Layout.fillWidth: true
            TabButton { text: "Photo" }
            TabButton {
                text: submitDialog.hasPin
                      ? "Location ✓"
                      : "Location"
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // Photo tab — picker + preview.
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
                        text: "Pick a JPEG to preview.\nLocation tab to drop a pin.\nSubmit wires up in Phase 3.3."
                        horizontalAlignment: Text.AlignHCenter
                        color: "#888"
                        font.pixelSize: 12
                    }
                }
            }

            // Location tab — OSM map (z=9 cap), click to drop pin.
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
        }
    }

    FileDialog {
        id: fileDialog
        title: "Pick a photo"
        nameFilters: ["JPEG images (*.jpg *.jpeg)", "All files (*)"]
        onAccepted: submitDialog.selectedFile = fileDialog.selectedFile
    }

    onClosed: {
        selectedFile = ""
        pinGeohash = ""
        hasPin = false
    }
}
