.pragma library

// Phase 3.3 helpers for SubmitDialog. Kept as a .js library so qmltestrunner
// can exercise them without a Qt Quick scene. Note: this file ships *only*
// for tests; the SubmitDialog inlines the same logic because the lgx UI
// builder only globs `*.qml` into the bundle (see flake of
// logos-module-builder/lib/mkLogosQmlModule.nix). If the inline copy and
// this file ever drift, the unit test will catch it because both end up
// formatting the same Date.

// Convert a JS Date to a decimal-integer string of unix seconds.
// `submitPhoto` slot expects a QString — see Phase 1.3 in PLAN.md / SPEC.
// Subseconds are truncated, not rounded, so the same Date always maps to
// the same wire value.
function unixSecondsString(date) {
    return Math.floor(date.getTime() / 1000).toString()
}

// True iff all three required submit inputs are populated.
function canSubmit(filePath, geohash8, timestampDate) {
    if (!filePath) return false
    if (!geohash8) return false
    if (!timestampDate) return false
    return true
}

// Strip a `file://` URL prefix to a filesystem path. The core's submitPhoto
// reads via QFile from a plain path, not a URL.
function filePathFromUrl(url) {
    var s = url.toString()
    if (s.indexOf("file://") === 0) return s.substring(7)
    return s
}
