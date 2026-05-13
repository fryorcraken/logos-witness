.pragma library

// Phase 3.4 timeline + marker state for Main.qml.
//
// The store is a flat list of refs sorted by timestamp descending, deduped
// by content_hash. Both sources of refs — `listInscriptions()` at startup
// and per-submission `referenceObserved` deliveries — feed through the same
// merge function. Phase 6's Delivery integration replaces the second source
// but the merge logic stays.
//
// Ref shape (matches the core's listInscriptions / decodeReference output):
//   { schema_version, content_hash, timestamp, geohash }
// Markers add a resolved centroid:
//   { ...ref, latitude, longitude }
// Geohash → centroid happens through the core's decodeGeohash invokable,
// not here — this module stays Qt/host-bridge-free so the qmltest can
// exercise it.

function makeStore() {
    return { entries: [], byHash: {} };
}

// Insert a ref into the store. Returns true if it was new, false if dropped
// as a duplicate of an already-seen content_hash. Sort is incremental:
// linear scan to find insertion point, list stays sorted in O(n).
function mergeReference(store, ref) {
    if (!ref || !ref.content_hash) return false;
    if (store.byHash[ref.content_hash]) return false;
    store.byHash[ref.content_hash] = true;

    var ts = Number(ref.timestamp);
    var i = 0;
    while (i < store.entries.length && Number(store.entries[i].timestamp) >= ts) {
        i++;
    }
    store.entries.splice(i, 0, ref);
    return true;
}

// Replace store contents from a (possibly unsorted) list. Used to seed
// from listInscriptions() at startup.
function seedFromList(store, refs) {
    store.entries.length = 0;
    for (var k in store.byHash) delete store.byHash[k];
    if (!refs) return;
    for (var i = 0; i < refs.length; i++) {
        mergeReference(store, refs[i]);
    }
}

// Compact human label for a unix-seconds timestamp. ISO-8601 down to
// minutes in UTC. Avoids locale surprises and keeps timeline rows the
// same width across users.
function formatTimestamp(unixSeconds) {
    var n = Number(unixSeconds);
    if (!isFinite(n)) return "(invalid timestamp)";
    var d = new Date(n * 1000);
    function pad(x) { return (x < 10 ? "0" : "") + x; }
    return d.getUTCFullYear() + "-"
         + pad(d.getUTCMonth() + 1) + "-"
         + pad(d.getUTCDate()) + " "
         + pad(d.getUTCHours()) + ":"
         + pad(d.getUTCMinutes()) + "Z";
}

// 8-char hex prefix of the hex-encoded content_hash. Enough to eyeball
// distinctness in the timeline without overwhelming the row.
function shortHash(hashHex) {
    if (!hashHex) return "";
    return String(hashHex).slice(0, 8);
}

// Min/max timestamp across the store, in unix seconds. Returns null when
// the store is empty so callers can hide the scrubber rather than render
// a degenerate range. Phase 3.5: drives the RangeSlider bounds.
function storeTimeRange(store) {
    if (!store || !store.entries || store.entries.length === 0) return null;
    // entries are sorted ts-desc, so the extremes are the endpoints.
    var newest = Number(store.entries[0].timestamp);
    var oldest = Number(store.entries[store.entries.length - 1].timestamp);
    if (!isFinite(newest) || !isFinite(oldest)) return null;
    return { min: oldest, max: newest };
}

// SPEC §11.3 scale presets. Width in seconds. Year is the v0 default.
var SCALE_PRESETS = {
    "day":   86400,
    "week":  604800,
    "month": 2592000,
    "year":  31536000
};

// SPEC §11.2: window is symmetric around the midpoint. Returns null on an
// unknown preset so callers can reject rather than silently default.
function windowFromMidpoint(tm, scalePreset) {
    var W = SCALE_PRESETS[scalePreset];
    if (W === undefined) return null;
    var m = Number(tm);
    if (!isFinite(m)) return null;
    return { t0: m - W / 2, t1: m + W / 2, W: W };
}

// SPEC §11.4: histogram of `refs` over [t0, t1] in `binCount` bins.
// Half-open `[bin_start, bin_end)` everywhere except the last bin, which
// closes on `t1` so exactly-at-t1 refs are included. Returns [] when
// binCount <= 0 or the interval is degenerate.
function binCounts(refs, t0, t1, binCount) {
    var n = Number(binCount) | 0;
    if (n <= 0) return [];
    var lo = Number(t0), hi = Number(t1);
    if (!isFinite(lo) || !isFinite(hi) || hi <= lo) return [];
    var out = new Array(n);
    for (var i = 0; i < n; i++) out[i] = 0;
    if (!refs) return out;
    var width = hi - lo;
    for (var j = 0; j < refs.length; j++) {
        var ts = Number(refs[j].timestamp);
        if (!isFinite(ts)) continue;
        if (ts < lo || ts > hi) continue;
        // Exactly-at-t1 falls in the last bin (closed on the right).
        var idx;
        if (ts === hi) {
            idx = n - 1;
        } else {
            idx = Math.floor((ts - lo) / width * n);
            if (idx < 0) idx = 0;
            else if (idx >= n) idx = n - 1;
        }
        out[idx]++;
    }
    return out;
}

// SPEC §11.5: linear opacity ramp from 1.0 at the midpoint to 0.15 at the
// edges. Clamped to [0, 1] for out-of-window safety (callers should hide
// such refs entirely, but the clamp keeps the formula well-defined).
function opacityFor(ts, tm, W) {
    var OPACITY_MIN = 0.15;
    var t = Number(ts), m = Number(tm), w = Number(W);
    if (!isFinite(t) || !isFinite(m) || !isFinite(w) || w <= 0) return 1.0;
    var d = Math.abs(t - m) / (w / 2);
    if (d <= 0) return 1.0;
    if (d >= 1) return OPACITY_MIN;
    return 1.0 - d * (1.0 - OPACITY_MIN);
}

// SPEC §11.6: clamp the midpoint so the user can't scroll a full window
// past `now` on the right or past `oldest - W/2` on the left. Empty store
// (oldest=null/NaN) falls back to the right bound only.
function clampMidpoint(tm, W, oldest, now) {
    var m = Number(tm), w = Number(W), nowN = Number(now);
    if (!isFinite(m) || !isFinite(w) || w <= 0 || !isFinite(nowN)) return tm;
    var rightBound = nowN + w / 2;       // tm + W/2 == now, no future
    if (m > rightBound) m = rightBound;
    var oldN = Number(oldest);
    if (isFinite(oldN)) {
        var leftBound = oldN - w / 2;
        if (m < leftBound) m = leftBound;
    }
    return m;
}

// Filter entries to those with `fromTs <= timestamp <= toTs`. Inclusive on
// both ends so the scrubber at full extent shows everything. A non-finite
// bound is treated as "no constraint on that side".
function filterByRange(entries, fromTs, toTs) {
    if (!entries) return [];
    var lo = Number(fromTs);
    var hi = Number(toTs);
    var loActive = isFinite(lo);
    var hiActive = isFinite(hi);
    if (!loActive && !hiActive) return entries.slice();
    var out = [];
    for (var i = 0; i < entries.length; i++) {
        var ts = Number(entries[i].timestamp);
        if (!isFinite(ts)) continue;
        if (loActive && ts < lo) continue;
        if (hiActive && ts > hi) continue;
        out.push(entries[i]);
    }
    return out;
}
