import QtQuick 2.15
import QtTest 1.15
import "../qml/TimelineModel.js" as TM

// Phase 3.4 timeline-model unit tests. Pure JS — runs under qmltestrunner
// without standing up a host bridge. Covers the merge logic the live
// `referenceObserved` path will hit every time a new ref arrives.

TestCase {
    name: "TimelineModel"

    function mkRef(hashHex, timestamp, geohash) {
        return {
            schema_version: 1,
            content_hash:   hashHex,
            timestamp:      timestamp,
            geohash:        geohash || "u4pruydq"
        }
    }

    function test_seed_from_list_sorts_descending() {
        var s = TM.makeStore()
        TM.seedFromList(s, [
            mkRef("aa", 100),
            mkRef("bb", 300),
            mkRef("cc", 200)
        ])
        compare(s.entries.length, 3)
        compare(s.entries[0].content_hash, "bb", "newest first")
        compare(s.entries[1].content_hash, "cc")
        compare(s.entries[2].content_hash, "aa", "oldest last")
    }

    function test_merge_dedupes_by_content_hash() {
        var s = TM.makeStore()
        verify( TM.mergeReference(s, mkRef("aa", 100)), "first insert is new")
        verify(!TM.mergeReference(s, mkRef("aa", 100)), "exact dup rejected")
        verify(!TM.mergeReference(s, mkRef("aa", 999)),
               "same hash with different ts still rejected — content_hash is identity")
        compare(s.entries.length, 1)
    }

    function test_live_merge_preserves_sort() {
        var s = TM.makeStore()
        TM.seedFromList(s, [
            mkRef("aa", 100),
            mkRef("cc", 300)
        ])
        // Live ref slots between 100 and 300.
        TM.mergeReference(s, mkRef("bb", 200))
        compare(s.entries.map(function (e) { return e.content_hash }).join(","),
                "cc,bb,aa")
    }

    function test_merge_rejects_malformed() {
        var s = TM.makeStore()
        verify(!TM.mergeReference(s, null))
        verify(!TM.mergeReference(s, {}))
        verify(!TM.mergeReference(s, { timestamp: 100 }))  // no content_hash
        compare(s.entries.length, 0)
    }

    function test_seed_resets_previous_state() {
        var s = TM.makeStore()
        TM.seedFromList(s, [mkRef("aa", 100), mkRef("bb", 200)])
        TM.seedFromList(s, [mkRef("cc", 300)])
        compare(s.entries.length, 1)
        compare(s.entries[0].content_hash, "cc")
        // Re-inserting an old hash after a reset must succeed.
        verify(TM.mergeReference(s, mkRef("aa", 100)))
    }

    function test_formatTimestamp_iso_utc() {
        // 2024-01-01T00:00:00Z → 1704067200.
        compare(TM.formatTimestamp(1704067200), "2024-01-01 00:00Z")
    }

    function test_formatTimestamp_invalid() {
        compare(TM.formatTimestamp("not-a-number"), "(invalid timestamp)")
    }

    function test_shortHash_8_chars() {
        compare(TM.shortHash("0123456789abcdef0123456789abcdef"), "01234567")
        compare(TM.shortHash(""), "")
        compare(TM.shortHash(null), "")
    }

    // ---- Phase 3.5: scrubber range + filter ------------------------------

    function test_storeTimeRange_empty_returns_null() {
        var s = TM.makeStore()
        verify(TM.storeTimeRange(s) === null)
        verify(TM.storeTimeRange(null) === null)
    }

    function test_storeTimeRange_uses_endpoints() {
        var s = TM.makeStore()
        TM.seedFromList(s, [
            mkRef("aa", 100),
            mkRef("bb", 300),
            mkRef("cc", 200)
        ])
        var r = TM.storeTimeRange(s)
        compare(r.min, 100)
        compare(r.max, 300)
    }

    function test_filterByRange_inclusive_bounds() {
        var entries = [
            mkRef("aa", 100),
            mkRef("bb", 200),
            mkRef("cc", 300)
        ]
        // Both bounds hit a sample exactly; both must be included.
        var out = TM.filterByRange(entries, 100, 300)
        compare(out.length, 3)
        out = TM.filterByRange(entries, 150, 250)
        compare(out.length, 1)
        compare(out[0].content_hash, "bb")
    }

    function test_filterByRange_no_match() {
        var entries = [mkRef("aa", 100), mkRef("bb", 200)]
        var out = TM.filterByRange(entries, 500, 600)
        compare(out.length, 0)
    }

    function test_filterByRange_open_ended() {
        var entries = [mkRef("aa", 100), mkRef("bb", 200), mkRef("cc", 300)]
        // NaN/undefined on one side means "no constraint there".
        var out = TM.filterByRange(entries, NaN, 200)
        compare(out.length, 2)
        out = TM.filterByRange(entries, 200, NaN)
        compare(out.length, 2)
        out = TM.filterByRange(entries, NaN, NaN)
        compare(out.length, 3)
    }

    function test_filterByRange_skips_invalid_timestamps() {
        var entries = [
            mkRef("aa", 100),
            { schema_version: 1, content_hash: "bad", timestamp: "nope", geohash: "u" },
            mkRef("cc", 300)
        ]
        var out = TM.filterByRange(entries, 0, 1000)
        compare(out.length, 2, "the bogus-ts entry is silently dropped")
    }

    // ---- SPEC §11 time cursor helpers ------------------------------------

    function test_windowFromMidpoint_preset_widths() {
        var day = TM.windowFromMidpoint(1000000, "day")
        compare(day.W, 86400)
        compare(day.t0, 1000000 - 43200)
        compare(day.t1, 1000000 + 43200)

        compare(TM.windowFromMidpoint(0, "week").W,  604800)
        compare(TM.windowFromMidpoint(0, "month").W, 2592000)
        compare(TM.windowFromMidpoint(0, "year").W,  31536000)
    }

    function test_windowFromMidpoint_symmetric() {
        var w = TM.windowFromMidpoint(500, "day")
        compare(w.t1 - 500, 500 - w.t0, "symmetric around tm")
    }

    function test_windowFromMidpoint_unknown_preset() {
        verify(TM.windowFromMidpoint(0, "decade") === null)
        verify(TM.windowFromMidpoint(0, "") === null)
        verify(TM.windowFromMidpoint(NaN, "day") === null)
    }

    function test_binCounts_empty_refs() {
        var bins = TM.binCounts([], 0, 100, 10)
        compare(bins.length, 10)
        for (var i = 0; i < bins.length; i++) compare(bins[i], 0)

        compare(TM.binCounts(null, 0, 100, 10).length, 10)
    }

    function test_binCounts_degenerate_window() {
        // hi <= lo or non-finite — caller asks for nothing, gets nothing.
        compare(TM.binCounts([mkRef("a", 50)], 100, 100, 10).length, 0)
        compare(TM.binCounts([mkRef("a", 50)], 100, 50,  10).length, 0)
        compare(TM.binCounts([mkRef("a", 50)], NaN, 100, 10).length, 0)
        compare(TM.binCounts([mkRef("a", 50)], 0,   100, 0).length,  0)
    }

    function test_binCounts_half_open_intervals() {
        // 10 bins over [0, 100). Bin width = 10. Bin boundaries land on
        // multiples of 10; a ref exactly at 10 belongs to bin 1, not bin 0.
        var refs = [
            mkRef("a", 0),    // bin 0
            mkRef("b", 9.99), // bin 0
            mkRef("c", 10),   // bin 1  ← edge belongs right
            mkRef("d", 55),   // bin 5
            mkRef("e", 99)    // bin 9
        ]
        var bins = TM.binCounts(refs, 0, 100, 10)
        compare(bins[0], 2, "0 and 9.99 fall in bin 0")
        compare(bins[1], 1, "10 falls in bin 1 (half-open left)")
        compare(bins[5], 1)
        compare(bins[9], 1)
    }

    function test_binCounts_t1_inclusive() {
        // SPEC §11.4: last bin closes on t1 so exactly-at-t1 refs count.
        var refs = [mkRef("a", 100)]
        var bins = TM.binCounts(refs, 0, 100, 10)
        compare(bins[9], 1, "ref at t1 goes into the last bin")
    }

    function test_binCounts_drops_out_of_window() {
        var refs = [mkRef("a", -5), mkRef("b", 50), mkRef("c", 105)]
        var bins = TM.binCounts(refs, 0, 100, 10)
        var total = 0
        for (var i = 0; i < bins.length; i++) total += bins[i]
        compare(total, 1, "only the in-window ref is counted")
    }

    function test_opacityFor_midpoint_and_edges() {
        // W=100 → half-width 50, so tm±50 are the edges.
        compare(TM.opacityFor(1000, 1000, 100), 1.0)
        compare(TM.opacityFor(1050, 1000, 100), 0.15)
        compare(TM.opacityFor( 950, 1000, 100), 0.15)
    }

    function test_opacityFor_linear() {
        // d = 0.5 → opacity = 1 - 0.5 * (1 - 0.15) = 0.575
        var o = TM.opacityFor(1025, 1000, 100)
        verify(Math.abs(o - 0.575) < 1e-9)
    }

    function test_opacityFor_clamps_out_of_window() {
        compare(TM.opacityFor(2000, 1000, 100), 0.15, "far past edge clamps to min")
        compare(TM.opacityFor(   0, 1000, 100), 0.15, "far before edge clamps to min")
    }

    function test_opacityFor_invalid_inputs() {
        compare(TM.opacityFor(NaN, 1000, 100), 1.0)
        compare(TM.opacityFor(1000, NaN, 100), 1.0)
        compare(TM.opacityFor(1000, 1000, 0), 1.0)
        compare(TM.opacityFor(1000, 1000, -5), 1.0)
    }

    function test_clampMidpoint_future_bound() {
        // No scrolling more than W/2 past now: tm + W/2 may not exceed now.
        // With W=100 and now=1000, the bound is tm <= 1050.
        compare(TM.clampMidpoint(9999, 100, 500, 1000), 1050)
        compare(TM.clampMidpoint(1050, 100, 500, 1000), 1050, "exactly at bound stays")
        compare(TM.clampMidpoint(1000, 100, 500, 1000), 1000, "below bound stays")
    }

    function test_clampMidpoint_past_bound() {
        // Earliest tm = oldest - W/2. With W=100, oldest=500, bound is 450.
        compare(TM.clampMidpoint(0,   100, 500, 1000), 450)
        compare(TM.clampMidpoint(450, 100, 500, 1000), 450)
    }

    function test_clampMidpoint_empty_store_fallback() {
        // No oldest → only the future bound applies.
        compare(TM.clampMidpoint(9999, 100, NaN, 1000), 1050)
        compare(TM.clampMidpoint(-9999, 100, NaN, 1000), -9999,
                "no past bound when store empty")
    }
}
