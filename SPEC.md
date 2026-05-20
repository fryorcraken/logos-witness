# Logos Witness — SPEC

> Status: v0 spec, pre-implementation. Authoritative until amended.
> License: MIT OR Apache-2.0.

## 1. Objective

Logos Witness is a basecamp application that lets a user upload a photo, strip
all device metadata, and publish an anonymous reference anchored to a
user-confirmed timestamp and geohash. Other instances of the app discover
contributions in real time via the Logos Delivery module and render them on a
shared map+timeline. References are durably committed to the Logos blockchain
in batches via `zone-sdk` inscriptions.

The narrative target user is the citizen journalist or activist; the v0 user
is anyone running basecamp as a desktop showcase. The real success criterion
for v0 is a legible end-to-end exercise of three Logos modules — Storage,
Delivery, and on-chain inscription — that another Logos builder can read and
reuse as a reference application.

Photos only in v0. Video extends the same loop later.

## 2. Architecture

Logos Witness is a basecamp application composed of two LGX modules:

- **`logos_witness_core`** — non-UI core module (Qt 6 / C++17). Owns the EXIF
  strip pipeline, the Storage upload/download client (calls
  `storage_module` via `LogosAPI`; see §2.1), the Delivery publisher and
  subscriber, the local pending-inscription queue, and the manual batch
  inscriber (`zone-sdk`). Runs in `logos_host`.
- **`logos_witness_ui_qml`** — QML UI module. File picker, geohash-on-map
  selector, timestamp confirm, submit button, live map+timeline view. Calls
  the core module via `logos.callModule()` and subscribes to its signals.

Both are packaged as `.lgx` and installed into a basecamp instance pinned via
the repo's `scaffold.toml`. Inter-module communication happens through the
`LogosAPI` global (`logosAPI`) in C++ and `logos.callModule()` in QML.

### Data flow (submit path)

```
[user picks photo]
    ↓
[UI: confirm timestamp + geohash_8 on map] ── user clicks Submit ──┐
    ↓                                                              │
[core: strip EXIF/XMP/ICC/maker-notes; verify with exiftool]       │
    ↓                                                              │
[core: sha256(stripped_bytes) → content_hash]                      │
    ↓                                                              │
[core: storage_module.uploadUrl(file://tmp/stripped.jpg)            │
       → wait for storageUploadDone event → storage_cid]            │
    ↓                                                              │
[core: build protobuf Reference message {v, h, cid, t, g}]         │
    ↓                                                              │
[core: Delivery.publish(global topic, Reference bytes)] ──────────→[other peers'
    ↓                                                                feeds light up]
[core: append reference to local pending-inscription queue]
```

### Data flow (discovery path)

```
[core: Delivery.subscribe(global topic)] ← live additions
    +
[core: zone-sdk.scanInscriptions(topic prefix)] ← historical
    ↓
[core: dedupe by content_hash, merge into in-memory index]
    ↓
[core: signals UI on changes]
    ↓
[UI: map renders markers; timeline renders entries; click →
     core.fetchPhoto(cid) → storage_module.downloadToUrl(cid, file://…)
     → wait for storageDownloadDone → file:// URL returned to UI →
     QML Image renders it]
    ↓
[Storage blob unreachable] → UI renders marker as "unavailable" (greyed)
```

### Data flow (inscription, manual)

```
[user clicks "Commit batch" in UI (debug action)]
    ↓
[core: take all queued references, encode as protobuf ReferenceBatch, zone-sdk.inscribe(payload)]
    ↓
[core: on success, drain queue; on failure, retain queue and surface error]
```

Manual trigger only in v0 — the signing / transaction-submit interface is
unstable and a hands-on flush keeps determinism. Automatic batching is a v1
decision once the tx interface settles.

### 2.1 Storage integration

Storage is provided by the upstream `logos-co/logos-storage-module` LGX —
a Qt6 wrapper around `libstorage` (Nim). It is registered in
`scaffold.toml` and installed into each profile by `lgs basecamp
install` alongside the witness modules. The earlier SPEC name
`easylibstorage` was the pre-rename label and survives only as the C
backing library inside `storage_module`; the Q_INVOKABLE module we call
is `storage_module` (interface `org.logos.StorageModuleInterface`).

`logos_witness_core` is the only consumer; the UI module does not call
Storage directly. The core invokes Storage via `LogosAPI::invokeRemote
Method("storage_module", …)` and subscribes to its events via the same
`onEventResponse` slot pattern used elsewhere.

**Node lifecycle.** `storage_module` is a stateful Logos node, not a
stateless RPC. The core module owns its lifecycle:

1. On `initLogos`, call `storage_module.init(jsonCfg)` once. Config
   shape is the canonical `storage_config.json` (per-instance
   `data-dir`, `disc-port`, `api-port`; `bootstrap-node` populated
   from the peer's SPR for non-first instances).
2. Call `storage_module.start()` and await the `storageStart` event.
3. Until `storageStart`, `submitPhoto` returns `{ok:false, error:
   "storage not ready"}` — this is a normal cold-start window, not
   an error condition.
4. On module unload, `stop()` + `destroy()`.

**Upload path** (`submitPhoto`):

1. Strip per §7.1 (sha256 on stripped bytes = `content_hash`).
2. Write stripped bytes to a per-submit tempfile under the profile's
   cache dir.
3. Call `storage_module.uploadUrl(QUrl::fromLocalFile(tmpPath))` —
   returns a sessionId synchronously.
4. Block (inside `submitPhoto`) on the `storageUploadDone(success,
   sessionId, cid)` event matching that sessionId. The UI's existing
   "Submit may block briefly" affordance covers this; v1 may swap
   for an async `pending` reply.
5. On success, store `cid` in the Reference's new `storage_cid`
   field and proceed with Delivery + queue.
6. On failure, return `{ok:false, error: <event message>}`. Strip
   tempfile is unlinked unconditionally.

**Download path** (new `fetchPhoto(cid)` invokable):

1. UI marker-click handler calls `core.fetchPhoto(cid)`.
2. Core checks an in-process cache `cid → local file path`. Hit → return
   immediately. Miss → continue.
3. Compute destination path `<cache>/photos/<cid>.jpg`. Call
   `storage_module.downloadToUrl(cid, QUrl::fromLocalFile(dest))`.
4. Block on `storageDownloadDone(success, sessionId, message)`
   matching the returned sessionId.
5. On success, populate the cache, return `{ok:true, file_url:
   "file://…"}`. UI sets `Image.source = file_url`.
6. On failure (timeout, peer unreachable, blob missing), return
   `{ok:false, error: <message>}`. UI greys the marker per Phase 8
   missing-blob UX.

**Why a `cid` *and* a `content_hash`.** The `content_hash` is sha256 of
the bytes we strip locally — an integrity anchor we own end-to-end. The
`storage_cid` is the retrieval address minted by Storage's chunked
DAG (IPFS-style multihash over a Merkle tree of fixed-size blocks).
The CID is opaque to us and not equal to the sha256 of the file bytes;
it depends on chunk size and DAG layout. Carrying both fields lets us
(a) verify retrieved bytes hash back to the original — defense against
a malicious Storage peer serving substituted content — and (b) use
`content_hash` as the dedupe key in the Delivery / chain-scan merge,
which is stable across upload paths in a way the CID is not.

### Core module surface

The Q_INVOKABLE surface on `LogosWitnessCoreInterface` is the contract that
the UI module and any `logoscore`/CLI consumer programs against. It splits
into two groups:

- **Behavioural** (state-changing or store-reading):
  - `submitPhoto(filePath, timestamp, geohash) → {ok, error?, content_hash?, storage_cid?, delivery_ok?, delivery_error?}`
    — `storage_cid` per §2.1; `delivery_ok` per §2.2 (false when the
    ref was stored locally but did not reach the Delivery network).
  - `fetchPhoto(cid) → {ok, error?, data_url?}` — async-internally,
    sync-externally; `data_url` is a `data:image/jpeg;base64,…` URL
    (workaround for basecamp's DenyAll `QNetworkAccessManager`; see
    §7 item 6). Populated from Storage; see §2.1 download path.
  - `listInscriptions(filter?) → [Reference, …]` — each Reference now
    includes `storage_cid` as a string field.
  - `flushBatch() → {ok, error?, flushed?}`
  - `subscribeFeed() → void` (idempotent opt-in to the live feed; signals follow)
  - `deliveryReady() → bool` — synchronous probe of the live-feed
    health, drives the UI's Delivery readiness pill. Cheap; called
    on a ~5 s tick from the UI poll loop. See §2.2.
  - `storageReady() → bool` — synchronous probe of the storage-module
    init/start state, drives the UI's Storage readiness pill. Same
    cadence + cost as `deliveryReady`. Independent of delivery —
    upload + fetch depend on this; cross-instance ref broadcast
    depends on `deliveryReady`. See §7 item 6.
- **Wire-format decoders** (pure functions over wire-format bytes):
  - `decodeReference(QByteArray refBytes) → {ok, error?, schema_version?, content_hash?, timestamp?, geohash?}`
  - `decodeGeohash(QString geohash) → {ok, error?, latitude?, longitude?}`

The decoders exist because the UI module is pure-QML and cannot link the C++
protobuf bindings the core uses internally. The two principled options were
(a) compile a JS protobuf+geohash decoder into the UI bundle, duplicating
wire-format knowledge in two languages, or (b) expose decoders on the core
as pure functions. We took (b): one source of truth for the wire format,
no second decoder to keep in sync. The decoders are required by the
contract — `decodeReference` consumes the `referenceObserved` signal
payload, `decodeGeohash` produces the lat/lon that map markers need
(SPEC §2 stores geohash only). Backend swap-outs in Phases 4–7 do not
disturb them; they are wire-format-only.

Signals emitted upward from the core:

- `referenceObserved(QByteArray refBytes)` — one serialised `Reference`
- `inscriptionsLoaded(QVariantList refs)` — historical-scan completion

Errors at the boundary surface as `QVariantMap { "ok": bool, "error": str,
"data": ... }`. Internally, exceptions or `std::expected`-style results are
fine; exceptions MUST NOT escape `Q_INVOKABLE` methods.

### Reference schema (protobuf)

Inscribed and announced payloads are protobuf. Choice rationale: aligns with
the `lssa-idl/0.1.0` framework declared in `scaffold.toml`, and gives
compile-time schema enforcement and cross-language tooling. proto3's
"unknown fields are preserved on parse" gives the same forward-compatibility
property that an extendable CBOR map would, with stricter producer
guarantees.

`logos-witness-core/proto/reference.proto`:

```protobuf
syntax = "proto3";
package logos.witness.v1;

// Single witness reference. Wire and on-chain canonical form.
message Reference {
  uint32 schema_version = 1;  // = 1 for v0
  bytes  content_hash   = 2;  // sha256(stripped photo bytes), 32B
  uint64 timestamp      = 3;  // unix seconds, user-confirmed
  string geohash        = 4;  // precision 8 (~20m)
  string storage_cid    = 5;  // Logos Storage CID for retrieval (added 2026-05-14)
}

// Batched on-chain inscription payload.
message ReferenceBatch {
  repeated Reference refs = 1;
}
```

Field numbers 1–5 are locked. Future fields (e.g., `media_type`,
`content_class`) take new field numbers and MUST be additive only —
renaming or repurposing existing numbers is a `schema_version` bump.
Decoders MUST tolerate unknown fields (proto3 default behaviour).

`storage_cid` was added in the 2026-05-14 §2.1 amendment when Phase 5
discovery surfaced that `storage_module`'s CID is not equal to
sha256(file). Older `Reference` messages (none on-chain yet at the
amendment time — Phase 7 hasn't shipped) will deserialize with
`storage_cid == ""`; consumers MUST treat empty as "no Storage
retrieval address known" and fall back to the missing-blob path.
`schema_version` stays at `1`: this is an additive field, not a
schema break.

### 2.2 Delivery integration

Delivery is provided by the upstream `logos-co/logos-delivery-module`
LGX — a Qt6 wrapper around `liblogosdelivery` (waku-derived). Same
shape as §2.1: registered in `scaffold.toml`, installed by `lgs
basecamp install`, accessed by `logos_witness_core` via the typed
`LogosModules::delivery_module` accessor. The UI does not call
Delivery directly.

**Node lifecycle.** Owned by the core, idempotent:

1. On first `submitPhoto` or explicit `subscribeFeed`, call
   `delivery_module.createNode(jsonCfg)`. Config is
   `{logLevel, mode:"Core", preset:"logos.dev", portsShift}` —
   `portsShift` is a random offset (overridable via
   `LOGOS_DELIVERY_PORTS_SHIFT` env var) so two profiles on one box
   don't collide on tcp/discv5/api ports.
2. Call `delivery_module.start()` (synchronous bool).
3. Register `on("messageReceived", cb)` BEFORE subscribing so no
   inbound is dropped between start and the on() call.
4. Call `delivery_module.subscribe(topic)`.

**Liveness signal.** The `deliveryReady()` Q_INVOKABLE on the core
returns the current value of an internal `deliveryReady_` flag —
true after the four lifecycle steps above complete successfully,
false otherwise. The UI polls this every 5 s to drive the
**Delivery** readiness pill (see §7 item 6). A separate
`storageReady()` invokable surfaces `storage_module` init/start
state on the same cadence and drives the **Storage** readiness
pill; the two pills are independent because the channels fail
independently (peer ref broadcast vs. photo upload/fetch). Polling
instead of a push signal is a pragmatic shortcut from before the
hybrid UI scaffold landed (see §5); task #27 may swap it for a
typed signal subscription.

**Publish path.** After a successful `submitPhoto` upload, the core
calls `delivery_publish(refBytes)`. The upstream `send()` internally
runs `payload.toUtf8().toBase64()` — raw protobuf bytes are not
valid UTF-8, so we pre-encode the bytes to base64 ourselves before
`send()`. The wire ends up carrying `base64(our_base64(refBytes))`;
the receiver double-decodes. This is a workaround documented inline
in `lib/delivery_client.cpp` and tracked as an upstream feature
request for a `sendBytes(topic, QByteArray)` API.

`submitPhoto`'s return shape carries `delivery_ok: bool` and
`delivery_error?: string`. A `delivery_ok=false` is **not fatal** —
the ref is durable in the local store and the UI surfaces a "saved
locally — not broadcast" warning banner. No silent fallbacks.

**Subscribe path.** On `messageReceived`, the core's slot
double-decodes the payload, runs `Reference.ParseFromArray`,
dedupes against an in-memory `QSet<QByteArray> knownHashes_` (keyed
on `content_hash`), and on a new ref appends to the store and emits
`referenceObserved` — the same signal path local submits use, so
the UI flow is unified.

**Bootstrap.** Delivery discovers peers via the public logos.dev
waku fleet — `preset: "logos.dev"` resolves to a hardcoded peer
list inside `liblogosdelivery`. We do not currently set our own
`bootstrap-node` for the Storage side (§2.1); cross-instance
Storage fetch over peer-to-peer paths is therefore not guaranteed
to work today. Captured as a known gap; see PLAN.md follow-ups.

### Delivery content topic

`/logos-witness/1/inscriptions/proto` — single global topic for v0. The
trailing `/proto` segment names the wire encoding (protobuf), per LIP-23.
Each Delivery message is one serialised `Reference` (~50–80 B), well under
the 150 KiB per-message cap. Sharding by geohash prefix is deferred until
subscription cost is a measured problem.

## 3. Project Structure

```
logos-witness/                   # repo root, MIT OR Apache-2.0
├── README.md
├── SPEC.md                      # this file
├── LICENSE-MIT
├── LICENSE-APACHE
├── .gitignore
├── scaffold.toml                # pins basecamp + registers both modules
├── logos-witness-core/          # core LGX module (C++17, Qt 6)
│   ├── flake.nix                # logos-module-builder template
│   ├── metadata.json
│   ├── CMakeLists.txt
│   ├── proto/
│   │   └── reference.proto      # Reference / ReferenceBatch schema
│   ├── src/
│   │   ├── logos_witness_core_interface.h
│   │   ├── logos_witness_core_plugin.h
│   │   └── logos_witness_core_plugin.cpp
│   ├── lib/                     # internal helpers (strip, queue, codec)
│   │   ├── exif_strip.{h,cpp}
│   │   ├── reference_codec.{h,cpp}    # protobuf encode/decode wrapper
│   │   └── pending_queue.{h,cpp}
│   └── tests/
│       └── … (Qt Test)
└── logos-witness-ui-qml/          # QML UI LGX module
    ├── flake.nix
    ├── metadata.json
    ├── Main.qml                 # map + timeline + submit
    ├── components/
    │   ├── MapView.qml
    │   ├── Timeline.qml
    │   └── SubmitDialog.qml
    └── icons/
```

The two-module split follows the basecamp journey-doc pattern of a core
(non-UI) module plus a separate UI module, communicating via `LogosAPI`.

## 4. Commands

All commands assume Nix with flakes enabled and a basecamp dev build pinned
in `scaffold.toml`.

### Build

```bash
# Core module
cd logos-witness-core
nix build '.#lgx'                  # dev variant
nix build '.#lgx-portable'         # portable variant

# UI module
cd ../logos-witness-ui-qml
nix build '.#lgx'

# Both, via scaffold (preferred)
lgs basecamp setup
lgs basecamp install
```

### Inspect

```bash
nix build 'github:logos-co/logos-module/tutorial-v1#lm' --out-link ./lm
./lm/bin/lm metadata logos-witness-core/result/lib/logos_witness_core_plugin.so
./lm/bin/lm methods  logos-witness-core/result/lib/logos_witness_core_plugin.so
```

### Run

```bash
lgs basecamp launch                # launches pinned basecamp with both modules installed
```

### Test

```bash
# Core unit tests
cd logos-witness-core && nix develop --command bash -c 'cmake -B build -GNinja && cmake --build build && ctest --test-dir build'

# Integration: round-trip via headless logoscore
nix build 'github:logos-co/logos-logoscore-cli/tutorial-v1' --out-link ./logos
./logos/bin/logoscore -D -m ./modules
./logos/bin/logoscore call logos_witness_core submitPhoto <args>

# Strip-pipeline acceptance: every test asset must produce zero residual metadata
exiftool -a -G1 logos-witness-core/tests/fixtures/*.stripped.jpg   # expect: nothing identifying
```

## 5. Code Style

### C++ (core module)

- C++17. Qt 6 idioms: `Q_INVOKABLE`, `QString`, `QByteArray`, signals/slots for async. Generated protobuf C++ classes for the wire schema (see Protobuf subsection below).
- Follow the `logos-module-builder/tutorial-v1` template layout exactly.
  Renaming placeholders in lockstep across `metadata.json`, `CMakeLists.txt`,
  `*_interface.h`, `*_plugin.h`, `*_plugin.cpp` is non-negotiable — a
  mismatch builds but fails at install.
- Interface ID: `org.logos.LogosWitnessCoreInterface`. Methods on the interface
  are `Q_INVOKABLE virtual` and pure-virtual. The plugin implements them.
- `initLogos(LogosAPI* api)` is `Q_INVOKABLE` only — **not** `override`,
  **not** `virtual`. Inside, assign to the global `logosAPI` declared by
  `liblogos`, never to a class member. (See journey doc troubleshooting.)
- Public Qt-facing types (`QString`, `QByteArray`) at the interface; internal
  helpers may use `std::` types freely.
- One translation unit per logical concern in `lib/`: strip, codec, queue.
  Keep `*_plugin.cpp` thin — orchestration only.
- No raw `new`. Use `std::unique_ptr` / `QScopedPointer` for owned heap
  objects; Qt parent-child ownership where appropriate.
- Errors at the boundary surface as `QVariantMap { "ok": bool, "error": str,
  "data": ... }` returns from `Q_INVOKABLE` methods. Internally, exceptions
  or `std::expected`-style results are fine; do not let exceptions escape
  invokable methods.

### QML (UI module)

The UI module is a **hybrid `ui_qml + C++ backend`**: a single `.lgx`
that bundles both the QML view (`qml/Main.qml` and friends) and a
native plugin (`logos_witness_ui_qml_plugin.so`) declared via
`metadata.json`'s `main` field. Basecamp's loader instantiates the
C++ plugin and calls `initLogos(LogosAPI* api)` before showing the
QML view, so the QML side can address typed properties and slots on
the backend via `logos.module("logos_witness_ui_qml")`. CI gates the
bundle on every push: the `.lgx` MUST contain the `main` plugin `.so`
alongside the QML view (see §9).

Conventions:

- Qt Quick / Qt Quick Controls 2 (matches `logos-tictactoe-qml` baseline).
- Top-level `qml/Main.qml` is the entry view; helper components live
  in `qml/` alongside it. JS modules (`TimelineModel.js`,
  `SubmitHelpers.js`) are `.pragma library`-style helpers exercised
  by `qmltestrunner`.
- **Two call patterns to the core, both supported:**
  - `logos.callModule("logos_witness_core", "<method>", [...])` — the
    framework's untyped JSON-bridge invocation. Original v0 pattern;
    blocks the QML thread. Wrap each site in a small JS helper rather
    than inlining strings.
  - `logos.module("logos_witness_ui_qml").<typed-property-or-slot>` —
    typed accessor exposed by the UI backend plugin (declared in
    `src/logos_witness_ui_qml.rep`). New as of the hybrid scaffold;
    task #27 migrates per-site call patterns onto this surface to
    eliminate the QML-thread block and enable push signals.
- No external assets fetched at runtime. All icons, fonts, and map tiles
  bundled or self-hosted (see Boundaries §7).

### CMake

- Use the `logos_module()` macro provided by `logos-module-builder`. Do not
  hand-roll Qt plugin setup.
- `NAME` in `logos_module()` MUST equal `name` in `metadata.json`.

### Protobuf

- One source of truth: `logos-witness-core/proto/reference.proto`. The UI
  module never defines its own messages and never ships a parallel decoder.
  The pure-QML UI consumes wire-format bytes only through the core's
  `decodeReference` / `decodeGeohash` invokables (see §2 Core module
  surface). Any future C++-linked UI tooling may use the generated
  bindings directly; QML callers go through the invokables.
- Generated C++ via `protoc --cpp_out` invoked from CMake. Generated files
  are NOT committed; they are build artifacts. Wire all generation through
  the `logos_module()` macro extensions or a small `proto/CMakeLists.txt`.
- Field numbers 1–4 are reserved for the v0 schema. New fields take fresh
  numbers and MUST NOT reuse retired numbers. `reserved` markers are added
  for any number ever removed.
- No `optional`, no `oneof`, no nested messages in v0. Keep the wire format
  flat until there's a reason not to.

### Nix

- Flake `description` field set to a meaningful one-liner per module.
- Pin `logos-module-builder` to a specific commit before any tagged release —
  the template's default URL is unpinned for tutorial convenience.
- Protobuf compiler (`protoc`) is taken from `nixpkgs` via the flake; it
  is not assumed present on the host.

## 6. Testing Strategy

Three layers, in order of cost and frequency:

### Unit (fast, every commit)

- Qt Test inside `logos-witness-core/tests/`.
- **Strip pipeline:** for each fixture in `tests/fixtures/*.jpg` (mix of
  EXIF-rich, XMP-rich, ICC-profile, embedded-thumbnail, maker-note variants),
  assert the stripped output passes the residual-metadata check (see
  Boundaries §7 — this is enforced by a test, not a guideline).
- **Reference codec:** round-trip protobuf encode/decode for known vectors;
  forward-compat decode of payloads carrying unknown future fields;
  rejection of malformed payloads; canonical-encoding determinism check
  (same input → byte-equal output).
- **Pending queue:** persistence across process restart, drain semantics,
  ordering preservation.

### Module-level (medium, before PR)

- `lm metadata` and `lm methods` on the built `.so` confirm exposed surface
  matches the interface header.
- `logoscore` headless invocation of `submitPhoto` / `flushBatch` /
  `listInscriptions` against a real basecamp test fixture.

### End-to-end (slow, before merge to main)

- Two basecamp instances on the same machine (separate user dirs per the
  journey doc's known-constraint note). Submit on instance A; verify the
  reference appears live in instance B's UI within seconds via Delivery, and
  that a manual batch flush on A produces an inscription that instance B
  picks up on the historical-scan path.
- Storage round-trip: blob put on A retrievable from B; intentional
  unavailability path (delete blob) renders a "missing" marker in B's UI
  without crashing.

### Test-data hygiene

- Fixtures committed to the repo MUST be either freshly generated (camera
  metadata of a controlled rig) or downloaded from a public test corpus with
  a permissive license. Real personal photos go nowhere near `tests/`.

## 7. Boundaries

These are non-negotiable for any contributor — human or agent. Violations
require an explicit SPEC amendment.

### Always

1. **Strip and verify before upload.** Any path that places bytes into
   Logos Storage MUST run them through the strip pipeline AND verify with a
   second-tool check (e.g., `exiftool -a`) that no EXIF, XMP, ICC profile,
   maker-note, or embedded thumbnail remains. The verification step is
   fail-closed: if it fails, the upload does not happen.
2. **Require explicit user confirmation of timestamp and geohash before
   submit.** No silent auto-publish. The UI MUST show the exact values that
   are about to leave the device, and the user clicks to confirm.
3. **Use the extendable protobuf reference schema.** Adding new fields with
   fresh numbers is allowed without re-spec; renaming or repurposing an
   existing field number is not. Retired numbers are marked `reserved`,
   never re-used. Decoders MUST tolerate unknown fields (proto3 default).
   `schema_version` is bumped only on backwards-incompatible changes.
4. **Pin to basecamp-bundled module versions.** Delivery, Storage, and
   `zone-sdk` are taken from whatever the `scaffold.toml`-pinned basecamp
   ships, not from `master` of those repos.
5. **Keep `README.md` current with usage documentation at all times.** Any
   change that alters how a user installs, configures, builds, runs, or
   interacts with the app — including `lgs` commands, basecamp pin,
   environment variables, or UI flow — MUST update the README in the same
   commit. CI fails the build if the README has not been touched alongside
   a change to user-facing surface (see §9). "Docs in a follow-up PR" is
   not acceptable.
6. **Respect basecamp's UI plugin sandbox.** Every UI plugin's QML engine
   is instantiated with a deny-all `QNetworkAccessManager` plus a
   `RestrictedUrlInterceptor` that only allows `qrc:` and `file://`
   URLs rooted under the plugin's own runtime install dir
   (`pluginPath` — the directory basecamp extracts the .lgx contents
   into and points the QML engine's `baseUrl` at). Consequences a UI
   contributor MUST design around:
   - **`data:`, `image://<provider>/...`, `http(s)://`, and `file://`
     outside `pluginPath` are all blanked by the interceptor.** An
     `Image.source` set to any of these resolves to `QUrl()` and the
     image silently fails to load — no QML error, no log line.
   - **Photo display (Submit-dialog preview AND reference-detail
     dialog) routes through the UI plugin's C++ backend.** The
     backend reads the bytes (local file pick OR `storage_module`
     download), copies them into a `preview-cache/` dir under
     `pluginPath`, and returns a `file://` URL the interceptor
     accepts. QML binds that URL into `Image.source` as a plain
     local file. Cache key is content-addressed (SHA-256 prefix for
     picks, CID for storage); LRU-bounded at 1 GB.
   - **File reads of user-supplied paths happen in the C++ backend**
     (ui-host process), not in QML — QML has no FS affordance and
     wouldn't pass the interceptor anyway. The UI plugin's
     `loadLocalPhotoUrl(QString filePath)` SLOT is the entrypoint.
   - **Every `logos.callModule()` from QML is synchronous and blocks
     the render thread.** Per CLAUDE.md, all blocking core RPCs MUST
     be owned by the UI plugin's C++ backend (which marshals through
     a single thread because the upstream `LogosAPIClient` isn't
     reentrant) and surfaced to QML via auto-syncing `PROP`s or
     fire-and-forget `SLOT`/`SIGNAL` pairs. QtRO `SLOT` returns are
     wrapped with `logos.watch(...)` on the QML side because they're
     async.
   - QML imports basecamp does not bundle (e.g., `QtLocation`,
     `QtPositioning`) are vendored into the plugin's view directory and
     must be ABI-matched to basecamp's `qtdeclarative`. The refresh
     procedure lives in the README; the source rev lives in the
     `SOURCE.md` next to each vendored import.
   - **Capability readiness is two surfaces, not one.** The UI shows
     a **Delivery** pill (driven by `core.deliveryReady()`) AND a
     **Storage** pill (driven by `core.storageReady()`) side-by-side
     in the timeline header. They fail independently: a peer ref can
     arrive over delivery while storage is down (no photo
     retrievable), and a submit can upload to storage while delivery
     is offline (no peer will see it). Surfacing them as one
     "Online/Offline" badge is forbidden by this rule because it
     hides which capability is degraded from the user.

### Ask first

7. **Schema field changes.** Adding a field is routine; bumping `v` or
   removing/renaming is a SPEC amendment.
8. **Inscription batching policy.** Manual-only is the v0 contract.
   Switching to time-based or hybrid auto-flush requires confirming the
   signing/tx interface is stable and updating the SPEC.
9. **Topic strategy.** Splitting beyond the single global topic.
10. **Adding a third module** (e.g., a separate viewer-only app).

### Never

11. **Never call third-party network APIs**, with one explicit, temporary
    carve-out for v0: OSM tile servers (`tile.openstreetmap.org`) are the
    sole permitted external data source, capped at zoom level 9 (regional,
    no street-name detail), used only by the in-app map view. The carve-out
    is deliberate — shipping a demo-able UI before tile-distribution
    infrastructure exists — and is scheduled for removal before public-scale
    deployment per OSMF's tile usage policy. Long-term, map tiles migrate to
    distribution over Logos Storage as a separate prototype project (see
    §10). All other external assets remain forbidden: no Mapbox/Carto/Google
    tile traffic, no telemetry, no error reporters, no analytics, no font
    CDNs, no "just this once" fetches. All non-tile assets are bundled or
    self-hosted. Aside from OSM tiles, the only network operations the app
    performs go through Logos Core (Delivery, Storage, chain).
12. **Never publish unstripped bytes**, even in dev/debug paths. There is no
    `--keep-metadata` flag.
13. **Never inscribe a per-contributor identifier on chain.** No signer
    pubkey, device ID, app install ID, or anything that could pseudonymously
    cluster contributions to one origin. Discovery is geohash + timestamp;
    that is the entire on-chain payload contract.
14. **Never store user photos outside Logos Storage**, including no local
    "originals" sidecar copy after submission. Once the stripped bytes are
    in Storage and the reference is queued, the original-on-disk lifecycle
    is the user's; the app does not retain it.

## 8. Out of Scope (v0)

Mirrors the idea-refine one-pager and is repeated here so SPEC stands alone:

- Mobile, PWA, web frontends.
- Video.
- Live capture / streaming / chunked upload.
- Selective metadata reveal / commitment scheme.
- LEZ programs / smart-contract logic beyond `zone-sdk` inscriptions.
- Spam, abuse, moderation, blocklists.
- Identity, accounts, profiles, signers, reputation systems.
- Two-app split (uploader vs. investigator viewer).
- Sharded Delivery topics.
- Automatic batch inscription.

## 9. CI and Release

CI runs on every push and every pull request. The pipeline is reproducible
end-to-end via Nix and `lgs`; no step depends on the host toolchain beyond
Nix itself.

### CI pipeline (per push / PR)

1. **Setup**: `lgs basecamp setup` — resolves and caches the pinned basecamp
   per `scaffold.toml`. Fails fast if the pin is unreachable.
2. **Build**: `lgs basecamp install` — scaffold-driven build of both modules
   (`logos_witness_core`, `logos_witness_ui_qml`) into `.lgx` packages and
   installation into the basecamp instance's `modules/` and ui-plugins
   directories. This is the single source of truth for "does the app
   build"; do not invoke `nix build` directly in CI for the per-module
   packages.
3. **Inspect**: `lm metadata` and `lm methods` against each built `.so` to
   confirm metadata sanity and exposed surface match the interface header.
4. **Unit tests**: Qt Test suite under `logos-witness-core/tests/` via
   `ctest` inside `nix develop`.
5. **Strip-pipeline acceptance**: `exiftool -a -G1` over every output of
   the strip-pipeline test harness. CI fails on any residual identifying
   tag, regardless of test-pass status above. This is the §7.1 guarantee.
6. **Headless integration**: `logoscore` daemon load + invoke a scripted
   submitPhoto / flushBatch / listInscriptions round-trip against an
   in-CI basecamp test fixture. *Status (2026-05-19): temporarily
   un-wired in `ci.yml`. The first implementation hung CI to its 6 h
   cap (foreground `-D`). A deps-aware redo is required because the
   witness core plugin declares hard deps on `storage_module` +
   `delivery_module` (`lm metadata`); the bundled logoscore-cli only
   ships `capability_module`, so a naive `load-module` cannot resolve.*
7. **Docs gate**: when the diff touches user-facing surface (any file under
   `logos-witness-core/src/`, `logos-witness-ui-qml/`, `scaffold.toml`, build
   commands in the workflow file, or `metadata.json`), CI fails unless
   `README.md` is also modified in the same commit (§7.5).

### Release artifacts

A release is cut by tagging `v<major>.<minor>.<patch>` on `main`. The
release workflow MUST attach the following assets to the GitHub Release:

- `logos_witness_core-<version>-<platform>.lgx` — portable bundle (`nix build
  '.#lgx-portable'`), one per supported platform (Linux x86_64, Linux
  aarch64, macOS arm64, macOS x86_64).
- `logos_witness_ui_qml-<version>-<platform>.lgx` — same.
- A combined `logos-witness-<version>-<platform>.tar.gz` containing both
  `.lgx` files plus a `manifest.txt` listing checksums, basecamp pin, and
  `lgs` version used to build.
- `SHA256SUMS` for all of the above.

Attach via `gh release upload`. Releases without the full set of assets are
considered broken and must be re-cut, not patched.

The release workflow MUST refuse to publish if any CI gate above failed on
the tagged commit, including the docs gate.

## 10. Open questions (track and resolve before v0 ship)

- Missing-blob UX: greyed marker vs. hidden vs. explicit "unavailable" state.
  Default: greyed marker, click reveals "blob unreachable" detail.
- `zone-sdk` inscribe API shape (sync vs. async, signing requirement, byte
  cap per inscription) — confirms the manual-flush UX before any code lands.
- Geohash selector UX: drop-pin on a map tile vs. text entry. **Decided
  (Phase 3.2):** drop-pin on an OSM-backed map capped at zoom level 9, with
  the resulting geohash-8 and lat/lon both shown and copy-able from the pin
  readout so users can verify in another app.
- Map tile source long-term — v0 uses OSM with the §7 item 11 carve-out; the
  target end-state is tile distribution over Logos Storage, prototyped as
  a separate project. Open: when does Witness depend on it (v0.x, v1)?
- Exact "user-facing surface" globs used by the README docs gate (§9.7) —
  conservative default above is fine for v0 but may need pruning to avoid
  false positives on internal-only refactors.

## 11. Time cursor

The time cursor is the sole time-navigation control in the UI. It replaces the
Phase 3.5 prototype `RangeSlider` entirely — that control was a discoverable
but design-thin first pass; it does not ship. The cursor binds together three
ideas: a centered playhead at "now I'm looking here", a configurable window
width around it, and an at-a-glance distribution of how busy the rest of the
world's contributions are around that moment.

### 11.1 Anatomy

Layout, bottom of the main window, spanning the full width minus the timeline
rail. Top-to-bottom:

```
┌─────────────────────────────────────────────────────────────────┐
│   density curve (area chart, refs/bin)                          │  ← upper strip
│                  ╱╲                                             │
│             ╱╲  ╱  ╲   ╱╲                                       │
│        ╱╲  ╱  ╲╱    ╲ ╱  ╲                                      │
├─────────────────────────────┼───────────────────────────────────┤
│ ●─────────────────────────●─┼─●─────────────────────────●       │  ← cursor line
│ t0                          ▼                         t1        │
│                          midpoint                               │
│  [Day] [Week] [Month] [Year•]                  ‹ today ›        │  ← controls
└─────────────────────────────────────────────────────────────────┘
```

- **Cursor line** — a horizontal axis from `t0` (left edge) to `t1` (right
  edge). The midpoint `tm = t0 + (t1 - t0) / 2` is marked with a fixed
  triangular indicator centered on the strip. All three ticks (`t0`, `tm`,
  `t1`) are labeled with two lines: the short ISO date on top (e.g.
  `2026-05-12`), and a relative phrase below in a smaller, dimmer font
  (e.g. `now`, `2 days ago`, `3 weeks ago`, `1 year ago`). Bucket
  granularity for the relative phrase: `now` (within ±1 min of `now`),
  `N minutes ago`, `N hours ago`, `N days ago`, `N weeks ago`, `N months
  ago`, `N years ago` — whichever unit gives `N ≥ 1`. Future ticks (rare
  after §11.6's clamp) read `in N …`.
- **Density curve** — area chart above the cursor line, computed over the
  visible window only (§11.4).
- **Scale buttons** — `Day`, `Week`, `Month`, `Year`. Exactly one is active;
  switching presets re-centers the window on the current midpoint and resets
  width per §11.3.
- **Today shortcut** — a single button that anchors the right edge to
  `now`: `tm = now - W/2`, so `t1 = now` and the strip shows the most
  recent full window of past time without any empty future half. Does not
  change the active scale. Distinct from drag/step (§11.6), which remain
  centered-playhead operations and may freely pan `tm` so long as the
  §11.6 bounds hold — a user who wants the playhead centered on a past
  midpoint can still drag there; `Today` is the sensible default after
  scrolling, not a hard right-edge bound.

### 11.2 Window model

The cursor holds two state variables:

- `tm` (midpoint, unix seconds) — what the user is "looking at".
- `W`  (window width, seconds) — fully determined by the active scale preset.

Derived: `t0 = tm - W/2`, `t1 = tm + W/2`. The window is always symmetric
around the midpoint; the user never sets `t0` or `t1` directly.

This differs from the rejected RangeSlider model (two free handles) on
purpose: the symmetric-around-midpoint constraint makes scrolling and scaling
compositional, and matches the "playhead" mental model of the YouTube
heatmap analogue the user requested.

### 11.3 Scale presets

| Preset | Width `W`     | Notes                                |
|--------|---------------|--------------------------------------|
| Day    | 86 400 s      | 24 h                                 |
| Week   | 604 800 s     | 7 days                               |
| Month  | 2 592 000 s   | 30 days (fixed; not calendar-aligned)|
| Year   | 31 536 000 s  | 365 days (fixed; not calendar-aligned, default) |

`Year` is the default on first launch because v0 contribution density is
expected to be sparse — a wider initial window maximises the chance the user
sees something.

Calendar alignment is deliberately rejected for v0. Fixed widths keep the
scrolling math trivial (`tm += W/2` for a half-window step) and the cursor
behaviour identical across DST transitions and month-length variation. A
future preset like `Custom` or calendar-aligned `This month` is a v1
decision; it requires a SPEC amendment.

### 11.4 Density curve

The curve over the strip is a histogram of references in `[t0, t1]`, binned
across the curve's pixel width. It is recomputed on every change to `tm`,
`W`, or the underlying store.

- **Bins**: `N = floor(curveWidthPx / 4)`, clamped to `[16, 256]`. One bar
  per ~4 px is dense enough to look continuous after the area fill and cheap
  enough to recompute on every scroll frame at v0 scale.
- **Counts**: number of refs whose `timestamp` falls in the half-open
  interval `[bin_start, bin_end)`. The last bin is closed on both ends so
  exactly-at-`t1` refs are included.
- **Render**: filled area chart; the curve's vertical axis is auto-scaled to
  the max bin count in the visible window (so the curve always reaches the
  top of the strip when there's at least one ref). No grid lines, no
  numeric Y axis; this is a glanceable indicator, not a chart.
- **Empty window**: when every bin is zero, render no curve (just the cursor
  line below it). Do not render a flat baseline — empty looks empty.

The histogram is computed over the in-memory store the same way as the
timeline list and map markers — single source of data. As Phase 7 (chain
historical scan) lands, that store grows; the curve picks up the new
density automatically.

### 11.5 Marker opacity gradient

Every visible map marker and every visible timeline row carries an opacity
derived from its timestamp's distance to the midpoint:

```
d = |timestamp - tm| / (W / 2)           # 0 at midpoint, 1 at the edge
opacity = 1.0 - d * (1.0 - opacityMin)
opacityMin = 0.15                         # marker at t0 or t1
```

- `opacity = 1.0` at the exact midpoint.
- `opacity = 0.15` at the edges `t0` and `t1`.
- Linear in between. No easing function in v0; if the curve looks
  too harsh in practice, a cosine ease is a follow-up that does not
  touch the contract.

Refs whose timestamp falls outside `[t0, t1]` are hidden entirely — not
rendered on the map, not present in the timeline rail, not counted in the
density curve. The timeline counter shows `N of M refs` whenever `N < M`.

The opacity gradient applies uniformly to map markers and timeline-row
content. Hit-testing follows opacity: a marker at `opacity = 0.15` is still
clickable (basecamp's `MouseArea` doesn't gate on alpha), but its click
hitbox is the same size as a full-opacity marker. We do not shrink markers
at the edges in v0 — the opacity ramp is the visual signal.

### 11.6 Scrolling

Two input methods, both maintain the invariant that scrolling pans `tm`
without changing `W`:

- **Drag the cursor strip horizontally.** Click-and-hold anywhere in the
  cursor strip (curve area or axis), then drag. One pixel of horizontal
  drag = `W / stripWidthPx` seconds of pan. Releasing the drag freezes the
  new `tm`.
- **Step buttons.** A pair of `‹` / `›` buttons on the right of the scale
  row pan `tm` by `W / 2` (half the visible window) per click. Keeps a
  ~50% overlap with the previous view so the user can read across
  consecutive windows without losing context.

Mouse-wheel over the strip is **not** wired in v0 — the basecamp host's
QML build has flaky `WheelEvent` semantics under the sandboxed
`QNetworkAccessManager`, and the drag + step buttons cover the use case.
The wheel is a v1 question.

`tm` is bounded: it may never go more than `W/2` past `now` (no scrolling
"into the future" beyond the right edge of the current window). The
earliest bound is `tm = oldestRefTimestamp - W/2` — one full window past
the oldest ref, so the user can see "the oldest ref is here" with empty
space to its left. Step / drag clamp to these bounds.

### 11.7 Component contract (`TimeCursor.qml`)

The cursor is a reusable QML component imported by `Main.qml`. It owns its
own `tm` and `scalePreset` state and emits a single `windowChanged(t0,
t1)` signal whenever either changes.

Properties:

- `property var refs` — array of `{timestamp, ...}` objects; the cursor
  reads only `timestamp`. Driven by the same store `Main.qml` feeds the
  map and timeline.
- `property real tm` — midpoint, bindable two-way.
- `property string scalePreset` — one of `"day"`, `"week"`, `"month"`,
  `"year"`.
- `readonly property real t0`, `readonly property real t1` — derived.
- `readonly property int binCount`, `readonly property var bins` — the
  histogram (exposed for testability).

Signals:

- `windowChanged(real t0, real t1)` — emitted after every commit of `tm`
  or `scalePreset`.

`Main.qml` connects `windowChanged` to its existing `_rebuildBindings`
path, replacing the RangeSlider's `_scrubberMoved` callback. The opacity
formula in §11.5 lives in `TimelineModel.js` (`opacityFor(ts, tm, W)`) so
qmltest exercises it without standing up the cursor component.

### 11.8 Test coverage

Pure-JS in `TimelineModel.js`, exercised under `qmltestrunner`:

- `windowFromMidpoint(tm, scalePreset) → {t0, t1}` — symmetric window,
  preset width lookup, rejection of unknown presets.
- `binCounts(refs, t0, t1, binCount) → [int]` — empty array on zero refs,
  edge inclusion on `t1`, half-open elsewhere, correct counts under known
  vectors.
- `opacityFor(ts, tm, W) → real` — 1.0 at midpoint, 0.15 at edges, linear
  in between, clamped to `[0, 1]` for out-of-window safety.
- `clampMidpoint(tm, W, oldest, now) → real` — enforces the §11.6 bounds.

Manual e2e (basecamp): submit refs at deliberately spread-out timestamps
(min 3), confirm midpoint markers are opaque, edge markers are faint,
out-of-window markers are absent; scroll left/right with both drag and
step buttons; switch scales and observe the curve re-bin live.

### 11.9 Out of scope (v0, deferred)

- Keyboard navigation (Arrow keys, Home/End).
- Touch / pinch-to-zoom on the strip.
- Mouse-wheel scrolling (see §11.6).
- Calendar-aligned presets, custom-width entry.
- Persisting `tm` / `scalePreset` across UI plugin reloads (in-memory only
  in v0; Phase 5+ may revisit when the store itself becomes durable).
- Marker grouping / clustering when density is high (curve already
  communicates "lots happened here"; clustering is a v1 affordance).
