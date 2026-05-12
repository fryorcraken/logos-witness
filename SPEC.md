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
  strip pipeline, the Storage upload client (`easylibstorage`), the Delivery
  publisher and subscriber, the local pending-inscription queue, and the
  manual batch inscriber (`zone-sdk`). Runs in `logos_host`.
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
[core: easylibstorage.put(stripped_bytes) → content_hash]          │
    ↓                                                              │
[core: build protobuf Reference message {v, h, t, g}]              │
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
[UI: map renders markers; timeline renders entries; click → fetch blob from Storage]
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
}

// Batched on-chain inscription payload.
message ReferenceBatch {
  repeated Reference refs = 1;
}
```

Field numbers 1–4 are locked. Future fields (e.g., `media_type`,
`content_class`) take new field numbers and MUST be additive only —
renaming or repurposing existing numbers is a `schema_version` bump.
Decoders MUST tolerate unknown fields (proto3 default behaviour).

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

- Qt Quick / Qt Quick Controls 2 (matches `logos-tictactoe-qml` baseline).
- Components in `components/`; only `Main.qml` at the top level.
- Calls into the core module go through `logos.callModule("logos_witness_core",
  "<method>", [...])`. Wrap each call site in a small JS helper rather than
  inlining strings.
- No external assets fetched at runtime. All icons, fonts, and map tiles
  bundled or self-hosted (see Boundaries §7).

### CMake

- Use the `logos_module()` macro provided by `logos-module-builder`. Do not
  hand-roll Qt plugin setup.
- `NAME` in `logos_module()` MUST equal `name` in `metadata.json`.

### Protobuf

- One source of truth: `logos-witness-core/proto/reference.proto`. The UI
  module never defines its own messages; it links to or copies generated
  bindings from the core module.
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
   `RestrictedUrlInterceptor` that only allows `qrc:` and a small list of
   filesystem roots. Consequences a UI contributor MUST design around:
   - `Image.source = file://<user-picked-path>` is rejected; only paths
     under basecamp's allowed roots resolve. The Photo tab is filename-only
     until basecamp exposes a sanctioned local-image provider or photos
     are routed through Logos Storage (Phase 5).
   - File reads of user-supplied paths happen in the core module, not in
     the UI plugin. The UI hands a path string across the
     `logos.callModule()` bridge; the core does the I/O.
   - QML imports basecamp does not bundle (e.g., `QtLocation`,
     `QtPositioning`) are vendored into the plugin's view directory and
     must be ABI-matched to basecamp's `qtdeclarative`. The refresh
     procedure lives in the README; the source rev lives in the
     `SOURCE.md` next to each vendored import.

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
   in-CI basecamp test fixture.
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
