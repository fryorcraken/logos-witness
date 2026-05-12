.pragma library

// Phase 3.3 helpers for SubmitDialog. Kept as a .js library so qmltestrunner
// can exercise them without a Qt Quick scene. The current lgx UI builder
// (logos-module-builder/lib/mkLogosQmlModule.nix) recursively copies the
// entire view directory, so this file is included in the runtime bundle
// alongside Main.qml — confirmed by inspecting `tar tf result/*.lgx`.
// Phase 3.3 originally inlined the helpers into SubmitDialog.qml as a
// defensive measure against an earlier builder version that globbed only
// `*.qml`; the inline copy is kept for now to avoid an unnecessary edit.
// New consumers (Phase 3.4 `TimelineModel.js`) import from .js directly.

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

// Niemeyer-2008 geohash. SPEC §2 fixes the wire-format precision at 8;
// `precision` is parameterised so tests can pin shorter/longer outputs.
// Output is on-chain (encoded into the protobuf Reference), so the
// reference vectors in tst_submit_helpers.qml are the source of truth —
// the inline copy in MapView.qml must match this implementation.
var _GEOHASH_ALPHABET = "0123456789bcdefghjkmnpqrstuvwxyz"
function encodeGeohash(lat, lon, precision) {
    var latLo = -90.0, latHi = 90.0
    var lonLo = -180.0, lonHi = 180.0
    var bits = []
    var even = true
    while (bits.length < precision * 5) {
        if (even) {
            var lonMid = (lonLo + lonHi) / 2
            if (lon >= lonMid) { bits.push(1); lonLo = lonMid }
            else               { bits.push(0); lonHi = lonMid }
        } else {
            var latMid = (latLo + latHi) / 2
            if (lat >= latMid) { bits.push(1); latLo = latMid }
            else               { bits.push(0); latHi = latMid }
        }
        even = !even
    }
    var out = ""
    for (var i = 0; i < bits.length; i += 5) {
        var idx = bits[i]*16 + bits[i+1]*8 + bits[i+2]*4 + bits[i+3]*2 + bits[i+4]
        out += _GEOHASH_ALPHABET.charAt(idx)
    }
    return out
}
