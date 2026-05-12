import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Main UI entry point. Phases 3.1–3.3 ship the submit dialog (photo
// picker + map-driven geohash + capture time + submit-against-stub-core);
// the post-submit map+timeline of received references is Phase 3.4.

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
            text: "Logos Witness"
            font.pixelSize: 18
            font.bold: true
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Submit a place- and time-anchored photo, or ping the core to see what's been recorded so far.\nMap+timeline of received references lands in Phase 3.4; strip/Storage/Delivery/on-chain in 4–7."
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
