import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "TimelineModel.js" as TM

// SPEC §11 time cursor. Centered-playhead window navigator: the user picks a
// scale (Day/Week/Month/Year) and pans a midpoint `tm`; the visible window
// `[t0, t1]` is symmetric around `tm` and drives every other view (map
// markers, timeline rail, density curve above the cursor line).
//
// Owns its own `tm` and `scalePreset`. Emits `windowChanged(t0, t1)` after
// every commit so the host's `_rebuildBindings` re-derives visibility and
// opacity. Reads only `timestamp` from `refs`; the rest is opaque.

Item {
    id: root

    // ---- Public API -----------------------------------------------------

    // Array of `{timestamp, ...}` objects. The cursor histograms only the
    // timestamps. Driven by the same store Main.qml feeds the map+timeline.
    property var refs: []

    // Reactive mirrors of the underlying store. SPEC §11 + 3.5 reactivity
    // fix: plain-JS array reads don't re-evaluate bindings, so the host
    // surfaces the relevant scalars and the cursor re-bins when they tick.
    property int  entryCount: 0
    property real storeMinTs: NaN
    property real storeMaxTs: NaN

    // Midpoint and scale. `tm` defaults to "now" lazily on first valid
    // render; `scalePreset` defaults to "year" per SPEC §11.3.
    property real  tm: NaN
    property string scalePreset: "year"

    // Derived window. Re-evaluates whenever tm or scalePreset changes.
    // Year-width fallback (31536000) when the window can't be derived yet
    // (tm NaN during initial layout); keeps the curve's Canvas sizing
    // expressions well-defined.
    readonly property var _window: TM.windowFromMidpoint(tm, scalePreset)
    readonly property real windowW: _window ? _window.W : 31536000
    readonly property real t0: _window ? _window.t0 : NaN
    readonly property real t1: _window ? _window.t1 : NaN

    // Density-curve bin model. ~one bar per 4 px, clamped to [16, 256].
    readonly property int binCount: {
        var n = Math.floor(cursorStrip.width / 4)
        if (n < 16) n = 16
        if (n > 256) n = 256
        return n
    }
    readonly property var bins: TM.binCounts(refs, t0, t1, binCount)

    // Reference point for `formatRelative` on the three tick labels.
    // Refreshed on every _commitWindow so labels update when the user
    // scrolls/scales but don't tick wall-clock-style mid-drag.
    property real _labelNow: NaN

    signal windowChanged(real t0, real t1)

    implicitHeight: 130

    // ---- Internals ------------------------------------------------------

    // First-run / store-change anchor for `tm`. We can't set `tm = now` as a
    // property default because `now` is only knowable at runtime; do it on
    // completion and clamp on subsequent store changes so the cursor stays
    // inside the §11.6 bounds.
    Component.onCompleted: {
        // Anchor the initial window to the right edge of "now" — same
        // principle as the Today button (§11.1): the future is empty,
        // so don't waste half the strip on it. The user can drag back
        // to recenter the playhead on a past moment.
        if (!isFinite(root.tm)) {
            root.tm = root._now() - root.windowW / 2
        }
        root._commitWindow()
    }

    onTmChanged: _commitWindow()
    onScalePresetChanged: _commitWindow()
    // When the store grows/shrinks, the past-side bound may have moved.
    onEntryCountChanged: _commitWindow()

    function _now() { return Date.now() / 1000 }

    function _commitWindow() {
        if (!isFinite(root.tm)) return
        var nowS = root._now()
        var clamped = TM.clampMidpoint(
            root.tm,
            root.windowW,
            isFinite(root.storeMinTs) ? root.storeMinTs : NaN,
            nowS)
        if (clamped !== root.tm) {
            // Re-entry guard: setting tm fires this slot again, but the
            // second pass is a no-op because the clamp is idempotent.
            root.tm = clamped
            return
        }
        root._labelNow = nowS
        root.windowChanged(root.t0, root.t1)
    }

    function _setScale(preset) {
        if (preset === root.scalePreset) return
        root.scalePreset = preset
        // Window width changed; re-clamp + re-emit.
        _commitWindow()
    }

    function _stepBy(deltaSeconds) {
        root.tm = root.tm + deltaSeconds
    }

    // SPEC §11.1 (amended): Today anchors the right edge to now. tm is
    // shifted so t1 = now (no empty future half); the playhead therefore
    // sits at the strip center over `now - W/2`. Drag/step still operate
    // on tm directly — Today is the convenient default, not a hard bound.
    function _today() {
        root.tm = root._now() - root.windowW / 2
    }

    // Repaint the density curve whenever the underlying bin counts change.
    onBinsChanged: densityCanvas.requestPaint()

    // ---- Layout ---------------------------------------------------------

    ColumnLayout {
        anchors.fill: parent
        spacing: 4

        // Cursor strip: density curve above, axis with two-line tick
        // labels below. Height accounts for: 44 px curve canvas (top),
        // ~46 px axis row with playhead + two-line labels (bottom).
        Item {
            id: cursorStrip
            Layout.fillWidth: true
            Layout.preferredHeight: 90

            // Density-curve area chart. Auto-Y-scaled to the max bin in the
            // current window. Empty window → blank.
            Canvas {
                id: densityCanvas
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 44
                antialiasing: true
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var b = root.bins
                    if (!b || b.length === 0) return
                    var max = 0
                    for (var i = 0; i < b.length; i++) {
                        if (b[i] > max) max = b[i]
                    }
                    if (max === 0) return
                    var n = b.length
                    var stepX = width / n
                    ctx.beginPath()
                    ctx.moveTo(0, height)
                    for (var j = 0; j < n; j++) {
                        var x = (j + 0.5) * stepX
                        var h = (b[j] / max) * (height - 2)
                        ctx.lineTo(x, height - h)
                    }
                    ctx.lineTo(width, height)
                    ctx.closePath()
                    ctx.fillStyle = "#1d4ed8"
                    ctx.globalAlpha = 0.35
                    ctx.fill()
                    ctx.globalAlpha = 1.0
                    ctx.strokeStyle = "#1d4ed8"
                    ctx.lineWidth = 1
                    ctx.stroke()
                }
            }

            // Axis line + endpoint labels + centered playhead. Height
            // sized for two-line labels (ISO + relative phrase) below the
            // axis line; the axis line itself sits at the top of the row
            // so both label lines fit beneath it.
            Item {
                id: axisRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 46

                Rectangle {
                    id: axisLine
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: 8
                    height: 1
                    color: "#888"
                }

                // Left endpoint dot
                Rectangle {
                    width: 5; height: 5; radius: 2.5
                    color: "#444"
                    anchors.left: parent.left
                    anchors.verticalCenter: axisLine.verticalCenter
                }
                // Right endpoint dot
                Rectangle {
                    width: 5; height: 5; radius: 2.5
                    color: "#444"
                    anchors.right: parent.right
                    anchors.verticalCenter: axisLine.verticalCenter
                }

                // Centered playhead (triangle pointing up at the axis).
                Canvas {
                    id: playhead
                    width: 14; height: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: axisLine.top
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.fillStyle = "#d62828"
                        ctx.beginPath()
                        ctx.moveTo(width / 2, height)
                        ctx.lineTo(0, 0)
                        ctx.lineTo(width, 0)
                        ctx.closePath()
                        ctx.fill()
                    }
                }

                // Tick labels: two lines each. Top line is the ISO date,
                // bottom line is a relative phrase ("now", "3 days ago",
                // "1 year ago") per SPEC §11.1. The relative phrases pin
                // off `root._labelNow`, refreshed on every windowChanged
                // commit (not a live wall-clock — second-by-second ticks
                // would just cause needless rebinds during drag).

                // t0 label (left)
                Column {
                    anchors.left: parent.left
                    anchors.top: axisLine.bottom
                    anchors.topMargin: 2
                    spacing: 0
                    Label {
                        text: isFinite(root.t0) ? TM.formatTimestamp(root.t0) : ""
                        font.pixelSize: 10
                        font.family: "monospace"
                        color: "#555"
                    }
                    Label {
                        text: isFinite(root.t0)
                              ? TM.formatRelative(root.t0, root._labelNow) : ""
                        font.pixelSize: 9
                        color: "#888"
                    }
                }
                // tm label (center)
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: axisLine.bottom
                    anchors.topMargin: 2
                    spacing: 0
                    Label {
                        text: isFinite(root.tm) ? TM.formatTimestamp(root.tm) : ""
                        font.pixelSize: 10
                        font.family: "monospace"
                        color: "#222"
                        font.bold: true
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                    Label {
                        text: isFinite(root.tm)
                              ? TM.formatRelative(root.tm, root._labelNow) : ""
                        font.pixelSize: 9
                        color: "#666"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
                // t1 label (right)
                Column {
                    anchors.right: parent.right
                    anchors.top: axisLine.bottom
                    anchors.topMargin: 2
                    spacing: 0
                    Label {
                        text: isFinite(root.t1) ? TM.formatTimestamp(root.t1) : ""
                        font.pixelSize: 10
                        font.family: "monospace"
                        color: "#555"
                        anchors.right: parent.right
                    }
                    Label {
                        text: isFinite(root.t1)
                              ? TM.formatRelative(root.t1, root._labelNow) : ""
                        font.pixelSize: 9
                        color: "#888"
                        anchors.right: parent.right
                    }
                }
            }

            // Drag-to-pan: 1 px = W/stripWidthPx seconds. Held-and-dragged
            // anywhere over the strip (curve area or axis). MouseArea last
            // in the stack so it sees the events.
            MouseArea {
                id: panArea
                anchors.fill: parent
                cursorShape: Qt.SizeHorCursor
                property real _dragStartX: 0
                property real _dragStartTm: 0
                onPressed: function (mouse) {
                    _dragStartX  = mouse.x
                    _dragStartTm = root.tm
                }
                onPositionChanged: function (mouse) {
                    if (!pressed) return
                    if (cursorStrip.width <= 0) return
                    var dx = mouse.x - _dragStartX
                    var secPerPx = root.windowW / cursorStrip.width
                    // Drag right = older content moves left = tm goes back.
                    var raw = _dragStartTm - dx * secPerPx
                    // Pre-clamp here so we don't fire `tm = raw` then
                    // immediately `tm = clamped` from _commitWindow,
                    // doubling windowChanged emissions on every drag tick.
                    root.tm = TM.clampMidpoint(
                        raw,
                        root.windowW,
                        isFinite(root.storeMinTs) ? root.storeMinTs : NaN,
                        root._now())
                }
            }
        }

        // Scale presets + Today + step buttons.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: [
                    { key: "day",   label: "Day"   },
                    { key: "week",  label: "Week"  },
                    { key: "month", label: "Month" },
                    { key: "year",  label: "Year"  }
                ]
                delegate: Button {
                    text: modelData.label
                    font.pixelSize: 11
                    padding: 4
                    highlighted: root.scalePreset === modelData.key
                    onClicked: root._setScale(modelData.key)
                }
            }

            Item { Layout.fillWidth: true }

            Button {
                text: "‹"
                font.pixelSize: 12
                padding: 4
                onClicked: root._stepBy(-root.windowW / 2)
            }
            Button {
                text: "Today"
                font.pixelSize: 11
                padding: 4
                onClicked: root._today()
            }
            Button {
                text: "›"
                font.pixelSize: 12
                padding: 4
                onClicked: root._stepBy(root.windowW / 2)
            }
        }
    }
}
