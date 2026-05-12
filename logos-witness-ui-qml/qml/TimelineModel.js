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
