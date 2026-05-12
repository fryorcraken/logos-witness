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
}
