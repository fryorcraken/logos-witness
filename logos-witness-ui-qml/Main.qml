import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Phase 2 skeleton. The full submit dialog + map + timeline land in
// Phase 3. Today this verifies the lgx packages, basecamp loads it,
// and the JS bridge can reach logos_witness_core.

Item {
    id: root
    width: 480
    height: 360

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Logos Witness — Phase 2 skeleton"
            font.pixelSize: 18
            font.bold: true
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Submit dialog is Phase 3.1 (picker + preview only).\nGeohash (3.2), timestamp confirm + submit (3.3), map/timeline (3.4) follow.\nCore module is the in-memory stub until Phases 4–7."
            horizontalAlignment: Text.AlignHCenter
            color: "#666"
            font.pixelSize: 12
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 12

            Button {
                id: pingButton
                text: "Ping core (listInscriptions)"
                onClicked: pingCore()
            }

            Button {
                id: submitButton
                text: "Submit photo…"
                onClicked: submitDialog.open()
            }
        }

        SubmitDialog {
            id: submitDialog
            anchors.centerIn: parent
        }

        Frame {
            Layout.fillWidth: true
            Layout.fillHeight: true
            ScrollView {
                anchors.fill: parent
                clip: true
                TextArea {
                    id: statusArea
                    readOnly: true
                    wrapMode: TextArea.Wrap
                    font.family: "monospace"
                    font.pixelSize: 11
                    text: "(no calls yet)"
                }
            }
        }
    }

    // Wire calls to logos_witness_core through the host's logos bridge.
    // `logos.callModule` is injected by basecamp / logoscore at runtime.
    function pingCore() {
        try {
            var result = logos.callModule("logos_witness_core",
                                          "listInscriptions", [])
            statusArea.text = "listInscriptions →\n" + JSON.stringify(result, null, 2)
        } catch (e) {
            statusArea.text = "ERROR: " + e
        }
    }
}
