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

// Validate a date string + time string from the SubmitDialog When tab.
// Returns `{ ok: true, value: Date }` on success, `{ ok: false, error }`
// otherwise. Strict — accepts only `YYYY-MM-DD` + `HH:MM:SS`, rejects
// out-of-range months/days/hours and impossible calendar dates (e.g.
// `2026-02-31`). Both fields must be present; partial input is an
// error so the dialog can't silently fall back to the previously-valid
// capturedAt.
function validateDateTime(dateStr, timeStr) {
    if (!dateStr)  return { ok: false, error: "date is empty" }
    if (!timeStr)  return { ok: false, error: "time is empty" }
    var dm = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(dateStr)
    if (!dm) return { ok: false, error: "date must be YYYY-MM-DD" }
    var y = +dm[1], mo = +dm[2], dy = +dm[3]
    if (mo < 1 || mo > 12) return { ok: false, error: "month must be 1-12" }
    if (dy < 1 || dy > 31) return { ok: false, error: "day must be 1-31" }
    var tm = /^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/.exec(timeStr)
    if (!tm) return { ok: false, error: "time must be HH:MM or HH:MM:SS" }
    var h = +tm[1], mi = +tm[2], s = tm[3] !== undefined ? +tm[3] : 0
    if (h  < 0 || h  > 23) return { ok: false, error: "hour must be 0-23"   }
    if (mi < 0 || mi > 59) return { ok: false, error: "minute must be 0-59" }
    if (s  < 0 || s  > 59) return { ok: false, error: "second must be 0-59" }
    // Date.UTC normalises overflow (e.g. month=2, day=31 → March 3), so
    // detect impossible calendar dates by round-tripping the parts.
    var ms = Date.UTC(y, mo - 1, dy, h, mi, s)
    var d  = new Date(ms)
    if (d.getUTCFullYear()  !== y  || d.getUTCMonth() !== mo - 1
        || d.getUTCDate()   !== dy || d.getUTCHours() !== h
        || d.getUTCMinutes()!== mi || d.getUTCSeconds() !== s) {
        return { ok: false, error: dateStr + " is not a real date" }
    }
    return { ok: true, value: d }
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
