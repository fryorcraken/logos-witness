import QtQuick 2.15
import QtTest 1.15
import "../SubmitHelpers.js" as SubmitHelpers

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
}
