import QtQuick 2.15
import QtTest 1.15
import "../qml/SubmitHelpers.js" as SubmitHelpers

// Phase 3.3: timestamp + arg-marshalling helpers consumed by SubmitDialog.
// These are pure JS so they're cheap to test with qmltestrunner without
// standing up a C++ build for the UI module.

TestCase {
    name: "SubmitHelpers"

    function test_unixSecondsString_now_is_decimal_integer_string() {
        var s = SubmitHelpers.unixSecondsString(new Date())
        verify(typeof s === "string", "result must be a string")
        verify(/^\d+$/.test(s), "result must be a decimal-integer string, got: " + s)
        // Sanity: unix seconds for any time after 2001 is at least 10 chars.
        verify(s.length >= 10, "expected ≥10 chars, got: " + s)
    }

    function test_unixSecondsString_specific_date() {
        // 2024-01-01T00:00:00Z → 1704067200
        var d = new Date(Date.UTC(2024, 0, 1, 0, 0, 0))
        compare(SubmitHelpers.unixSecondsString(d), "1704067200")
    }

    function test_unixSecondsString_truncates_subseconds() {
        // 1714867200.789 → "1714867200" (no decimal point, no rounding-up)
        var d = new Date(1714867200789)
        compare(SubmitHelpers.unixSecondsString(d), "1714867200")
    }

    function test_canSubmit_requires_all_three_fields() {
        verify(!SubmitHelpers.canSubmit("",         "geohash8", new Date()))
        verify(!SubmitHelpers.canSubmit("file:///x", "",        new Date()))
        verify(!SubmitHelpers.canSubmit("file:///x", "geohash8", null))
        verify( SubmitHelpers.canSubmit("file:///x", "geohash8", new Date()))
    }

    function test_filePathFromUrl_strips_file_scheme() {
        // logos_witness_core.submitPhoto expects a plain filesystem path,
        // not a file:// URL — Phase 1.3 contract.
        compare(SubmitHelpers.filePathFromUrl("file:///tmp/demo.jpg"), "/tmp/demo.jpg")
        compare(SubmitHelpers.filePathFromUrl("/tmp/demo.jpg"),        "/tmp/demo.jpg")
    }

    // Geohash output is on-chain (SPEC §2 fixes precision at 8). A regression
    // here corrupts every submitted Reference, so we pin against the canonical
    // Wikipedia reference vector. MapView.qml inlines the same algorithm; if
    // the two ever drift, fix MapView — this test is the source of truth.
    function test_encodeGeohash_wikipedia_reference_vector() {
        // (57.64911, 10.40744) → "u4pruydqqvj" — Wikipedia "Geohash" article.
        // Truncated to 8 chars per SPEC §2.
        compare(SubmitHelpers.encodeGeohash(57.64911, 10.40744, 8), "u4pruydq")
    }

    function test_encodeGeohash_origin() {
        // (0, 0) → "s00000000…" — every halving picks the upper bit on lon
        // (0 ≥ 0) and the lower bit on lat (0 < 45 after first split).
        // The leading "s" is the canonical encoding of the prime-meridian
        // equator point.
        compare(SubmitHelpers.encodeGeohash(0.0, 0.0, 8), "s0000000")
    }

    function test_encodeGeohash_precision_is_respected() {
        // Length must equal the requested precision exactly — the wire
        // format is fixed-width.
        compare(SubmitHelpers.encodeGeohash(57.64911, 10.40744, 5).length, 5)
        compare(SubmitHelpers.encodeGeohash(57.64911, 10.40744, 8).length, 8)
        compare(SubmitHelpers.encodeGeohash(57.64911, 10.40744, 12).length, 12)
    }

    function test_encodeGeohash_uses_base32_alphabet() {
        // Standard Niemeyer alphabet excludes a, i, l, o.
        var s = SubmitHelpers.encodeGeohash(57.64911, 10.40744, 8)
        verify(/^[0-9bcdefghjkmnpqrstuvwxyz]+$/.test(s),
               "expected base32-geohash chars only, got: " + s)
    }

    // ---- validateDateTime: dogfood feedback ------------------------------

    function test_validateDateTime_canonical() {
        var r = SubmitHelpers.validateDateTime("2026-05-13", "14:30:00")
        verify(r.ok)
        compare(r.value.getUTCFullYear(), 2026)
        compare(r.value.getUTCMonth(), 4)   // May = 4
        compare(r.value.getUTCDate(), 13)
        compare(r.value.getUTCHours(), 14)
    }

    function test_validateDateTime_accepts_short_fields() {
        // Single-digit day/month/hour/minute/second — what the user
        // actually types. The regex is intentionally lenient on width;
        // range checks below catch genuine out-of-range values.
        verify(SubmitHelpers.validateDateTime("2026-5-7",  "9:05:00").ok)
        verify(SubmitHelpers.validateDateTime("2026-12-1", "00:00:00").ok)
        verify(SubmitHelpers.validateDateTime("2026-5-7",  "9:5:0").ok)
    }

    function test_validateDateTime_accepts_HHMM_without_seconds() {
        var r = SubmitHelpers.validateDateTime("2026-05-13", "14:30")
        verify(r.ok)
        compare(r.value.getUTCSeconds(), 0)
    }

    function test_validateDateTime_empty_inputs() {
        verify(!SubmitHelpers.validateDateTime("", "14:00").ok)
        verify(!SubmitHelpers.validateDateTime("2026-05-13", "").ok)
    }

    function test_validateDateTime_malformed_strings() {
        // Non-numeric, garbage, wrong separators — all rejected.
        verify(!SubmitHelpers.validateDateTime("yesterday", "14:00").ok)
        verify(!SubmitHelpers.validateDateTime("2026/05/13", "14:00").ok)
        verify(!SubmitHelpers.validateDateTime("2026-05-13", "14h00").ok)
    }

    function test_validateDateTime_out_of_range() {
        verify(!SubmitHelpers.validateDateTime("2026-13-01", "00:00").ok,
               "month 13 rejected")
        verify(!SubmitHelpers.validateDateTime("2026-00-15", "00:00").ok,
               "month 0 rejected")
        verify(!SubmitHelpers.validateDateTime("2026-05-32", "00:00").ok,
               "day 32 rejected")
        verify(!SubmitHelpers.validateDateTime("2026-05-13", "24:00:00").ok,
               "hour 24 rejected")
        verify(!SubmitHelpers.validateDateTime("2026-05-13", "12:60:00").ok,
               "minute 60 rejected")
    }

    function test_validateDateTime_impossible_calendar_date() {
        // 31 February doesn't exist; previously this would have silently
        // rolled forward to early March via Date overflow.
        verify(!SubmitHelpers.validateDateTime("2026-02-31", "00:00").ok)
        verify(!SubmitHelpers.validateDateTime("2025-02-29", "00:00").ok,
               "2025 isn't a leap year")
        verify( SubmitHelpers.validateDateTime("2024-02-29", "00:00").ok,
               "2024 IS a leap year")
    }
}
