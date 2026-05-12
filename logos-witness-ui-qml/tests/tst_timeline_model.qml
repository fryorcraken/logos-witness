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
}
