import QtQuick 2.15
import QtTest 1.15
import "../qml" as Local

// SPEC §11 TimeCursor smoke test. The §11 *math* is exercised in
// tst_timeline_model.qml against pure-JS helpers; this case validates that
// the QML component parses, instantiates, drives those helpers from its
// bindings, and emits windowChanged. We don't render — qmltestrunner runs
// offscreen — so visual fidelity is out of scope here (covered by manual
// e2e in basecamp).

TestCase {
    name: "TimeCursor"
    width: 800; height: 110
    when: windowShown

    Local.TimeCursor {
        id: cursor
        width: 800
        height: 110
        // Three refs spread over a few hours to exercise the histogram.
        refs: [
            { content_hash: "aa", timestamp: 1700000000, geohash: "u" },
            { content_hash: "bb", timestamp: 1700001800, geohash: "u" },
            { content_hash: "cc", timestamp: 1700003600, geohash: "u" }
        ]
        entryCount: 3
        storeMinTs: 1700000000
        storeMaxTs: 1700003600
        // Pin tm so the test doesn't drift with the system clock.
        tm: 1700001800
        scalePreset: "day"
    }

    SignalSpy {
        id: windowSpy
        target: cursor
        signalName: "windowChanged"
    }

    function test_window_emitted_on_load() {
        // Reset to known state — qmltestrunner runs test_* alphabetically,
        // so earlier cases may have mutated scalePreset / tm.
        cursor.scalePreset = "day"
        cursor.tm = 1700001800
        // Force at least one fresh emission against this spy: clear, nudge
        // tm by one second so the binding fires unambiguously, then assert.
        // The original version verified `count >= 1` immediately after the
        // assignments above, which only worked because Component.onCompleted
        // had populated the spy — brittle under test reordering.
        windowSpy.clear()
        cursor.tm = cursor.tm + 1
        verify(windowSpy.count >= 1, "windowChanged fired on tm change")
        verify(isFinite(cursor.t0))
        verify(isFinite(cursor.t1))
        // Day preset: W=86400 → half-width 43200. The +1 above shifts tm to
        // 1700001801; the window stays symmetric around the new midpoint.
        compare(cursor.windowW, 86400)
        compare(cursor.t0, 1700001801 - 43200)
        compare(cursor.t1, 1700001801 + 43200)
    }

    function test_scale_change_widens_window() {
        windowSpy.clear()
        cursor.scalePreset = "year"
        verify(windowSpy.count >= 1, "windowChanged fired on scale change")
        compare(cursor.windowW, 31536000)
    }

    function test_bins_reflect_refs() {
        // With tm centered in the refs and a day window, all three refs
        // should fall in the histogram; their total must equal the visible
        // ref count regardless of bin distribution.
        cursor.scalePreset = "day"
        cursor.tm = 1700001800
        var total = 0
        for (var i = 0; i < cursor.bins.length; i++) total += cursor.bins[i]
        compare(total, 3, "all in-window refs counted")
    }
}
