# Photo display in a basecamp `ui_qml` plugin — investigation log

Living document. Updated as we try things in dogfood.

## Problem

The witness app needs to render a JPEG inside the QML view of its
`ui_qml`-type plugin. Two flavours:

1. **Submit-dialog preview** — show the user the file they just picked,
   before they submit. Bytes are on local disk; no network/storage
   involved.
2. **Reference detail preview** — show the photo for a `storage_cid`
   we already submitted or received from a peer. Bytes are fetched
   via `storage_module.downloadToUrl`.

Both reduce to the same QML question: **how do you point an `Image`
element at runtime-obtained JPEG bytes when basecamp's QML engine has
a `DenyAllNAMFactory` + `RestrictedUrlInterceptor`?**

## What basecamp enforces

`logos-basecamp/src/MainUIBackend.cpp` (commit `b44a5cf4787f…`) sets
up the QML engine for every `ui_qml` plugin with:

```cpp
engine->setNetworkAccessManagerFactory(new DenyAllNAMFactory());
QStringList allowedRoots;
allowedRoots << pluginPath;  // the plugin's runtime install dir
engine->addUrlInterceptor(new RestrictedUrlInterceptor(allowedRoots));
engine->setBaseUrl(QUrl::fromLocalFile(pluginPath + "/"));
```

`RestrictedUrlInterceptor::intercept`:

```cpp
if (url.scheme() == QLatin1String("qrc")) return url;
if (url.isLocalFile()) {
    /* allow if path startsWith one of allowedRoots */
    return url;  // or QUrl() if outside
}
return QUrl();   // block http/https/data/image:/anything-else
```

So the engine sees:

- ✅ `qrc:/...` — unconditionally allowed.
- ✅ `file:///<pluginPath>/...` — allowed (canonical-path startsWith
  match against allowed roots).
- ❌ `file://` outside pluginPath — blocked.
- ❌ `data:image/jpeg;base64,…` — blocked.
- ❌ `image://<provider>/...` — blocked (any non-qrc, non-local-file
  scheme).
- ❌ `http://`, `https://` — blocked.

A blocked URL becomes `QUrl()` (empty), so `Image.source` gets a
silently-invalid value and the Image just doesn't paint. No QML error,
no log line from basecamp's main process (the interceptor doesn't log).
Plugin-side `console.warn` doesn't reach basecamp's log either.

Track: upstream issue
[logos-co/logos-basecamp#189](https://github.com/logos-co/logos-basecamp/issues/189)
— "What's the supported pattern for displaying dynamically-fetched
images in a hybrid ui_qml plugin?"

## What we tried

### Attempt 1 — `data:` URL from `core.fetchPhoto`

**Status:** ❌ silently rejected.

The core module's `Q_INVOKABLE QVariantMap fetchPhoto(cid)` returned
`{"ok": true, "data_url": "data:image/jpeg;base64,…"}`. QML side did

```qml
Image { source: detailDialog.photoDataUrl }
```

Image stayed in `Image.status === Error` (confirmed empirically with
an `onStatusChanged` diagnostic). Source-reading of
`RestrictedUrlInterceptor::intercept` confirmed `data:` is structurally
blocked — the scheme isn't `qrc:`, isn't a local file, falls through
to the trailing `return QUrl()`. Same goes for the 67-byte
red-1×1-pixel `data:` URI from the Wikipedia RFC 2397 examples; it
isn't a payload-size or content issue. The interceptor wipes the URL
before `Image` ever sees it.

This was the original Phase 5 implementation and is what shipped in
`v0.0.1`. It has never worked under basecamp's sandboxed engine.

### Attempt 2 — `QQuickImageProvider` from the plugin

**Status:** ❌ not tried; rejected on inspection.

Even if we could grab the QML engine and call
`engine->addImageProvider("witness", new WitnessImageProvider(...))`,
`Image { source: "image://witness/<cid>" }` goes through the
interceptor first. `image://` isn't `qrc:`, isn't a local file →
blocked. The provider would never get invoked.

Caveat: not confirmed empirically. There's a small chance Qt routes
`image://` URLs to the provider *before* the interceptor sees them. To
test would require registering the provider from inside our backend,
which itself is non-trivial — see Attempt 3.

### Attempt 3 — Hybrid plugin architecture (Phase 1, in flight)

**Status:** ✅ for everything except the actual rendering channel.

Moved every `logos.callModule(...)` call off the QML render thread by
putting the blocking core calls behind SLOTs on the UI module's C++
backend (`logos-witness-ui-qml/src/logos_witness_ui_qml.rep`). Backend
exposes:

- `PROP refs` (auto-syncing QVariantList) — replaces the
  `_refreshFromCore` polling Timer.
- `PROP deliveryReady` (auto-syncing bool) — replaces `_probeDelivery`.
- `SLOT submitPhotoAsync(localId, …) + SIGNAL submitDone(...)` —
  optimistic submit; row appears in the timeline with an
  "uploading…" pill while the upload runs on a worker thread.
- `SLOT fetchPhotoAsync(cid) + SIGNAL photoReady(cid, QByteArray) /
  photoFailed(cid, error)` — non-blocking photo fetch.

This solves the freeze problem (UI never blocks on a sync core call)
but does NOT solve the rendering problem. `photoReady` delivers
`QByteArray` to QML; QML's `Image.source` only accepts URLs.

QML cannot:
- bind `Image.source` to a `QByteArray` (no built-in conversion);
- write a `QByteArray` to disk (sandbox; QML has no filesystem write
  affordance);
- register a `QQuickImageProvider` (no API on the QML side).

Bytes-to-`Image` therefore still needs a C++-side channel that
materialises something the interceptor accepts.

### Attempt 4 — `file://` under the plugin's runtime install dir

**Status:** 🟡 in progress; current bug.

The interceptor explicitly whitelists `file://` under `pluginPath`.
That dir is **writable** (verified by `touch __writable_probe__`) —
basecamp installs the .lgx contents there with `+w` permissions.

Design: backend exposes
`SLOT(QString loadLocalPhotoUrl(QString filePath))`. It reads the
picked file, copies the bytes to
`<pluginPath>/preview-cache/<sha256-prefix>.<ext>`, returns
`file://<absolute_path>`. QML binds `Image.source = backend.loadLocalPhotoUrl(...)`.

Caches by SHA-256 prefix → picking the same photo twice is a free hit.

Backend implementation in `logos_witness_ui_qml_plugin.cpp` (current
commit). UI in `SubmitDialog.qml`'s Photo tab.

**Current bug (2026-05-20):** preview shows
`Preview error: Backend returned no URL (got: "")`.

The empty string is the diagnostic clue. The backend's
`loadLocalPhotoUrl` has no return path that produces `""` — every
branch returns either a `"file://..."` URL or a `"error:..."` string.
The empty string must come from the QtRO replica path.

Root cause (hypothesis, confirmed by the
[tutorial](https://github.com/logos-co/logos-tutorial/blob/master/tutorial-cpp-ui-app.md#step-6-qml-view)):
**QtRO SLOT calls from QML are not synchronous.** A replica call
returns a `QRemoteObjectPendingCall` immediately; the actual result
arrives later via signal. The tutorial wraps every backend-method
call with `logos.watch(...)`:

```qml
logos.watch(backend.foo(args),
    function(value) { /* success */ },
    function(error) { /* error */ })
```

Our `_refreshPreview` calls `backend.loadLocalPhotoUrl(...)` and
treats the return value as if it's a string. JS sees an empty
"unwrapped" default → empty string → our QML wrongly classifies it
as "backend returned no URL".

**Fix (next step):** rewrite `_refreshPreview` to use `logos.watch`,
mirroring the calc-tutorial idiom. Same fix likely applies to
`decodeGeohash` in `Main.qml`'s `_decodeGeohashCentroid` (currently
synchronous-style), though decodeGeohash hasn't visibly failed yet —
it may be benefiting from `QtRO` round-tripping fast enough that the
"empty default" never gets observed in the cache-miss path. Worth
fixing both regardless.

### Attempt 5 — `QResource::registerResource` of a runtime-built `.rcc`

**Status:** ⏸ deferred.

Build a minimal Qt resource bundle (`.rcc`) at runtime containing the
JPEG under a path like `:/witness/<cid>.jpg`, call
`QResource::registerResource(rccPath)`, hand QML
`qrc:/witness/<cid>.jpg`. qrc passes the interceptor by design.

Doable but fiddly (Qt's RCC binary format isn't designed for runtime
assembly). Hold off unless Attempt 4 has a fatal flaw we don't see
yet.

## Decision

Proceed with **Attempt 4 (file:// under pluginPath)**. Fix the
`logos.watch` mismatch first, then verify the preview lands, then port
the same pattern to the reference-detail dialog.

If Attempt 4 turns out to have a fatal flaw (interceptor canonicalises
the path differently than I think; cache permissions get scrubbed by
basecamp on app start; etc.) — fall back to Attempt 5.

`QQuickImageProvider` (Attempt 2) stays parked unless we get a
basecamp upstream answer that says "yes, image:// is routed past the
interceptor, you just need a hook to register".
