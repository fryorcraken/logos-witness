<img src="logos-witness-ui-qml/icon.png" alt="" width="96" align="right" />

# Logos Witness

A basecamp application for publishing anonymous, time- and place-anchored
media — photos and videos — to the Logos network. Media is stripped of all
device metadata before upload to Logos Storage; references are announced
live over Logos Delivery and durably committed in batches as on-chain
inscriptions via `zone-sdk`. Other instances of the app render
contributions on a shared map + timeline.

v0 ships photo support first; video and live capture follow on the same
pipeline once the photo flow is settled end-to-end.

> **Status:** v0.0.1 (pre-release), 2026-05-15. Phases 1–6 of
> [`PLAN.md`](./PLAN.md) complete; Phases 7 (on-chain inscribe) and
> 8 (missing-blob UX) outstanding before v0.1.0. See
> [`SPEC.md`](./SPEC.md) for the authoritative design and
> [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

## What works today

Open the app, click **Submit photo…**, pick a JPEG, drop a pin on
the map, confirm the timestamp, and submit. Within a second or two
the photo's metadata is stripped, the bytes are uploaded to Logos
Storage, and a small reference is broadcast on the network.
Anyone else running the app sees a new marker on their map and a
new row on their timeline a few seconds later — no servers, no
accounts, no signups.

What you see on screen:

- A full-window map with a marker for every reference you and your
  peers have submitted.
- A timeline panel on the right listing the same references with
  time, location, and a short CID.
- **Delivery** and **Storage** readiness pills at the top of the
  timeline. Delivery green = receiving cross-instance ref broadcasts
  (peer photos will appear). Storage green = photo upload + fetch
  available (your submits will land, peer photos will render). The
  two are independent — a peer ref can arrive while photos are
  unfetchable, or your submit can land without any peer seeing it.
- An upload progress strip while a submission is in flight, with
  Retry if it fails and a "saved locally — not broadcast" warning
  if the upload completed but couldn't reach the network.
- A time slider along the bottom (day / week / month / year scale)
  that fades out references outside the visible window so the map
  isn't overwhelmed when there are lots of them.
- A detail view, on clicking a marker or row, that fetches the
  photo back from Storage and displays it inline.

Manual batch-to-chain inscription is the one piece still
outstanding — `flushBatch()` is a stub that lands in Phase 7.

| Concern                  | Today                                                                   | Status                       |
| ------------------------ | ----------------------------------------------------------------------- | ---------------------------- |
| EXIF / metadata strip    | `strip_jpeg` + exiftool residual gate in CI                             | shipped Phase 4              |
| Photo storage            | upload to `storage_module` (libstorage), CID embedded in `Reference`    | shipped Phase 5              |
| Cross-instance discovery | publish + subscribe via `delivery_module` (waku, logos.dev fleet)       | shipped Phase 6              |
| On-chain inscription     | `flushBatch` is a no-op stub                                            | Phase 7 (zone-sdk) — pending |
| Missing-blob UX          | error inline; no greyed-marker fallback                                 | Phase 8 — pending            |
| Video + live capture     | not started                                                             | post-v0                      |

## Architecture at a glance

Two LGX modules built by this repo, plus two runtime dependencies
declared in `scaffold.toml` and installed alongside:

| Module                 | Type | Provided by | Role                                                                  |
| ---------------------- | ---- | ----------- | --------------------------------------------------------------------- |
| `logos_witness_core`   | core | this repo   | EXIF strip, Storage upload, Delivery pub/sub, batch inscriber (stub)  |
| `logos_witness_ui_qml` | UI   | this repo   | File picker, geohash-on-map selector, submit, map + timeline view     |
| `storage_module`       | core | upstream    | Logos Storage wrapper (libstorage / Nim runtime, CID-addressed blobs) |
| `delivery_module`      | core | upstream    | Logos Delivery wrapper (waku-derived publish/subscribe + JSON config) |

The single global Delivery topic is `/logos-witness/1/inscriptions/proto`.
Each on-chain reference is a protobuf `Reference` message —
`{schema_version, content_hash, timestamp, geohash, storage_cid}` —
with a precision-8 geohash. See `logos-witness-core/proto/reference.proto`.

`logos_witness_core` declares `storage_module` and `delivery_module`
in its `metadata.json` `dependencies` array; `logos-module-builder`
emits typed `m_logos->storage_module.*` and
`m_logos->delivery_module.*` accessors against those deps' generated
SDK headers. There is no `loadPlugin` dance — the framework binds the
typed clients on first use.

## Prerequisites

- Linux x86_64 / aarch64 or macOS arm64 / x86_64
- ≥ 10 GB free disk
- [Nix](https://nixos.org/download.html) with flakes enabled
- The `lgs` scaffold CLI ([`logos-co/logos-scaffold`](https://github.com/logos-co/logos-scaffold))
- Git

### Basecamp compatibility

This release is built against
[`logos-basecamp@pre-release-b44a5cf-260`](https://github.com/logos-co/logos-basecamp/tree/pre-release-b44a5cf-260)
(2026-05-08). The pin lives in [`scaffold.toml`](./scaffold.toml) and is
recorded in every release's `manifest.txt`.

The newest tagged RC, `0.1.2-RC2`, is **not** compatible: it bundles an
older `lgpm` that rejects QML-only modules whose `manifest.json`
declares `main: {}` — which is our UI module's shape. The fix landed
one `lgpm` commit later (PR #9, `865fc5a`); `pre-release-b44a5cf-260`
is the first basecamp release to bundle that fix. The full rationale
is captured in the `scaffold.toml` comment block. Running this build
against a different basecamp pin is unsupported — the witness modules'
Qt 6.9.2 ABI and the bundled lgpm's manifest-validation rules are both
load-bearing.

## Install from a tagged release (Linux x86_64)

Each tagged release attaches portable `.lgx` bundles for both witness
modules plus a combined tarball. Pull them from the [Releases page](https://github.com/fryorcraken/logos-witness/releases)
and drop them into your basecamp profile's `modules/` and
`plugins/` directories (or feed them to `lgpm install`):

```bash
# Pick the latest release tag.
TAG=v0.0.1
PROFILE=$HOME/.cache/your-basecamp-profile/xdg-data/Logos/LogosBasecampDev

gh release download "$TAG" -R fryorcraken/logos-witness \
  --pattern '*.lgx' --pattern 'SHA256SUMS'

# Verify checksums before installing — SPEC §9 considers a release
# without matching SHA256SUMS broken; the workflow refuses to publish
# one, but always verify on your side anyway.
sha256sum --check SHA256SUMS

lgpm --modules-dir "$PROFILE/modules" \
     --ui-plugins-dir "$PROFILE/plugins" \
     install --file logos_witness_core-${TAG#v}-linux-x86_64.lgx
lgpm --modules-dir "$PROFILE/modules" \
     --ui-plugins-dir "$PROFILE/plugins" \
     install --file logos_witness_ui_qml-${TAG#v}-linux-x86_64.lgx
```

The witness modules need `storage_module` and `delivery_module` to
also be installed — pin them to the same revs the release was built
against (recorded in the tarball's `manifest.txt`). The scaffold
flow below installs all four automatically.

## Quickstart from source

Two ways to run: the **CLI flow** (`logoscore`, easy, no GUI) and the
**UI flow** (basecamp window, requires an env wedge — see "Launching the UI"
below for why).

```bash
git clone https://github.com/fryorcraken/logos-witness.git
cd logos-witness

# 1. Resolve and build basecamp + lgpm + alice/bob profiles.
lgs basecamp setup

# 2. Build + install all four modules (core + UI + storage + delivery)
#    into both alice and bob profiles.
lgs basecamp install
```

### CLI flow: drive the core module via `logoscore`

```bash
ALICE=$PWD/.scaffold/basecamp/profiles/alice/xdg-data/Logos/LogosBasecampDev

# 1. Build logoscore (cached after first run).
nix build 'github:logos-co/logos-logoscore-cli/tutorial-v1' --out-link /tmp/logoscore

# 2. Start the daemon, load the module.
/tmp/logoscore/bin/logoscore -D -m "$ALICE/modules"
/tmp/logoscore/bin/logoscore load-module logos_witness_core

# 3. Submit a real JPEG. The core strips metadata, sha256s the stripped
#    bytes, uploads them to storage_module, embeds the returned CID,
#    and publishes the protobuf Reference on the Delivery topic.
/tmp/logoscore/bin/logoscore call logos_witness_core submitPhoto /path/to/photo.jpg 1714867200 u4pruydq
# → {"result":{"ok":true,"content_hash":"e0...","storage_cid":"zDv...HrkJV2","delivery_ok":true},"status":"ok"}

# 4. List references back. Local submits + anything that's arrived
#    from peers via Delivery, deduped by content_hash.
/tmp/logoscore/bin/logoscore call logos_witness_core listInscriptions
# → {"result":[{"ok":true,"content_hash":"e0...","geohash":"u4pruydq","schema_version":1,"timestamp":1714867200,"storage_cid":"zDv...HrkJV2"}],"status":"ok"}

# 5. Fetch the photo bytes back from Storage (returned as a data: URL
#    so the UI can render without `file://` access; CLI users just see
#    the base64 prefix).
/tmp/logoscore/bin/logoscore call logos_witness_core fetchPhoto zDv...HrkJV2
# → {"result":{"ok":true,"data_url":"data:image/jpeg;base64,/9j/4AAQ..."},"status":"ok"}

# 6. Manual batch flush is a no-op stub today (zone-sdk inscribe lands in Phase 7).
/tmp/logoscore/bin/logoscore call logos_witness_core flushBatch
# → {"result":{"flushed":0,"note":"stub: zone-sdk inscribe wired in Phase 7","ok":true},"status":"ok"}

# 7. Stop the daemon when finished.
/tmp/logoscore/bin/logoscore stop
```

The module call signature is `submitPhoto(<path>, <unix_seconds>, <geohash_8>)`.
The timestamp is a decimal-string because `logoscore` and the LogosAPI
marshalling forward numeric args as `QString` — a `qint64` slot fails the
QMetaObject invocation silently. Geohash is precision-8 (≈ 20 m).

### UI flow: launching basecamp

`lgs basecamp launch` runs basecamp via a wrapper script that hard-overrides
`QT_PLUGIN_PATH`. Our UI module relies on vendored `QtLocation` +
`QtPositioning` (see "Vendored Qt imports" below); to make them visible
to Qt we bypass the wrapper and call basecamp's inner binary directly with
the env we need. A helper script lives at [`scripts/launch-witness.sh`](./scripts/launch-witness.sh).

```bash
./scripts/launch-witness.sh alice
```

To dogfood the live cross-instance feed, launch a second profile in
another terminal. Pass `LOGOS_DELIVERY_PORTS_SHIFT` so the
`delivery_module` instances don't collide on local ports:

```bash
LOGOS_DELIVERY_PORTS_SHIFT=200 ./scripts/launch-witness.sh bob
```

Submit a photo in alice; within a few seconds the same reference
appears on bob's map + timeline. Both connect to the public
logos.dev waku fleet, so the demo doesn't need any local
bootstrap configuration.

Pre-alpha caveat: the script reaches into the scaffold cache and reproduces
the wrapper's env inline. It will keep working as long as the basecamp pin
in `scaffold.toml` and the vendored Qt 6.9.2 imports stay in sync. Both
move together — see "Vendored Qt imports" for the refresh procedure.

### Vendored Qt imports

`MapView.qml` imports `QtLocation` and `QtPositioning`, which basecamp does
not bundle. We ship those QML import directories inside the UI module at
[`logos-witness-ui-qml/qml/QtLocation/`](./logos-witness-ui-qml/qml/QtLocation)
and `qml/QtPositioning/`, built from the same nixpkgs revision basecamp
itself pins. They include their `.so` plugins; `.gitignore` carves an
exception for those specific files.

ABI requires the vendored imports to match basecamp's Qt **exactly** (a
6.9.3 vs 6.9.2 minor bump fails with `undefined symbol _ZNK...AOTCompiledContext...`).
To refresh after a basecamp pin bump:

```bash
NIXPKGS_REV=$(python3 -c 'import json; print(json.load(open("/tmp/lb-bc/flake.lock"))["nodes"]["nixpkgs"]["locked"]["rev"])')   # rev from basecamp's flake.lock
QTLOC=$(nix build --no-link --print-out-paths "github:nixos/nixpkgs/$NIXPKGS_REV#qt6.qtlocation")
QTPOS=$(nix build --no-link --print-out-paths "github:nixos/nixpkgs/$NIXPKGS_REV#qt6.qtpositioning")
rm -rf logos-witness-ui-qml/qml/QtLocation logos-witness-ui-qml/qml/QtPositioning
cp -r "$QTLOC/lib/qt-6/qml/QtLocation"   logos-witness-ui-qml/qml/QtLocation
cp -r "$QTPOS/lib/qt-6/qml/QtPositioning" logos-witness-ui-qml/qml/QtPositioning
chmod -R u+w logos-witness-ui-qml/qml/QtLocation logos-witness-ui-qml/qml/QtPositioning
```

No inline photo preview *in the Submit dialog*: basecamp installs a
DenyAll `QNetworkAccessManager` on every UI plugin's QML engine, so
`Image.source = file://<path>` is rejected for any local file path.
The Photo tab shows the filename only; the core module (which has
unrestricted filesystem access) reads the bytes on submit. **After
upload**, clicking a marker fetches the photo from Storage via
`fetchPhoto(cid)` and the core returns it as a base64 `data:` URL
the QML engine *will* accept — that's the inline preview path.

## Inspect a built module

```bash
nix build 'github:logos-co/logos-module/tutorial-v1#lm' --out-link /tmp/lm
cd logos-witness-core
nix build '.#lib' --out-link result-lib
/tmp/lm/bin/lm metadata result-lib/lib/logos_witness_core_plugin.so
/tmp/lm/bin/lm methods  result-lib/lib/logos_witness_core_plugin.so
```

## Tests

```bash
# Core unit tests: protobuf reference codec (Phase 1.2), geohash
# decoder (Phase 3.4), strip pipeline (Phase 4.1) + exiftool
# residual-metadata gate (Phase 4.2). storage_client and
# delivery_client are not unit-tested — they require a live
# storage_module / delivery_module node, so the gate is the
# two-instance dogfood + CI's build-portable smoke.
cd logos-witness-core
nix develop --command bash -c '
  cmake -B build -GNinja \
    && cmake --build build --target test_reference_codec test_geohash test_exif_strip \
    && ctest --test-dir build --output-on-failure'

# UI helper unit tests — timestamp formatting, submit-args marshalling
# (Phase 3.3), TimelineModel + TimeCursor (Phase 3.4–3.5). Runs offscreen.
# QML2_IMPORT_PATH is pinned to the same qtdeclarative store path as the
# qmltestrunner binary; a multi-version `find` glob picks the wrong
# qtdeclarative and triggers ABI mismatches when tests import controls.
cd ../logos-witness-ui-qml
QTDECL=$(nix eval --raw nixpkgs#qt6.qtdeclarative)
export QML2_IMPORT_PATH="$QTDECL/lib/qt-6/qml"
export QT_QPA_PLATFORM=offscreen
nix shell nixpkgs#qt6.qtdeclarative nixpkgs#qt6.qtbase \
  --command qmltestrunner -input tests/
```

The strip pipeline and its residual-metadata gate (`exiftool -a` over
the stripped fixtures with a `[ExifTool] [System] [File] [JFIF]
[Composite]` whitelist — anything outside fails ctest) are wired into
`ctest` as of Phase 4.2. Full CI per SPEC §9 lands in Phase 9. See
[`SPEC.md` §6](./SPEC.md#6-testing-strategy) and
[`SPEC.md` §9](./SPEC.md#9-ci-and-release).

## Privacy posture

The on-chain payload is intentionally minimal: hash, timestamp, geohash.
No signer, no device ID, no app install ID. Network-layer anonymity is
provided by Logos Core / Delivery transport; the chain entry itself
carries nothing that links contributions to a single origin. Geohash
precision is fixed at 8 (~20 m).

The strip pipeline is fail-closed: any failure to verify that EXIF,
XMP, ICC, maker-notes, and embedded thumbnails are gone aborts the
upload. There is no `--keep-metadata` flag. Phase 4.1 ships the
strip itself (libjpeg-turbo coefficient copy, byte-identical decoded
pixels), Phase 4.2 the residual-metadata gate (`exiftool -a` with
a five-group whitelist, plus an automated negative self-test), and
Phase 4.3 wires the strip into `submitPhoto` so `content_hash` is
sha256 of stripped bytes. Malformed or non-JPEG inputs propagate as
`ok=false` to the caller — the UI's existing error path surfaces
that.

### Map tiles: a known v0 compromise

The submission pipeline is the part that's anonymity-shaped: stripped
bytes, hash-only references, no signer on chain, network-layer anonymity
via Logos Core. The **map browse** is not. v0 fetches tiles from
`tile.openstreetmap.org` (the SPEC §7 item 11 carve-out), which means every
pan and zoom is an HTTP request to OSMF logged with your IP and the
viewed region. Zoom is capped at level 9 — no street-name detail — to
narrow the leakage, but a determined observer of OSMF logs can still
correlate "this IP looked at this region around this time". If you are
in an adversarial network context, route the app through Tor or a
trusted VPN. The long-term fix is to distribute tiles over Logos Storage
so map traffic is indistinguishable from normal app traffic; that is
tracked as a separate prototype project, not v0 scope.

See [`SPEC.md` §7 Boundaries](./SPEC.md#7-boundaries) for the full set of
non-negotiable rules. **This README is part of the contract** — any change
to install, build, run, or interaction surface MUST update this file in
the same commit.

## Repository layout

```
logos-witness/
├── README.md                  # this file
├── SPEC.md                    # authoritative design & boundaries
├── PLAN.md                    # phase-ordered task breakdown + status
├── CHANGELOG.md               # release notes (Keep-a-Changelog)
├── LICENSE-MIT
├── LICENSE-APACHE
├── scaffold.toml              # basecamp pin + module registry (project + 2 deps)
├── scripts/
│   └── launch-witness.sh      # env-wedge launcher (see "UI flow")
├── .github/workflows/
│   ├── ci.yml                 # PR + main canary: build, ctest, qmltest, docs gate
│   └── release.yml            # `v*.*.*` tag → portable .lgx bundles to a Release
├── logos-witness-core/        # core LGX module (C++17 / Qt 6)
│   ├── CMakeLists.txt
│   ├── flake.nix              # pinned to logos-module-builder commit 5e196e2769
│   ├── metadata.json          # declares storage_module + delivery_module deps
│   ├── proto/reference.proto  # wire / on-chain schema
│   ├── src/                   # interface + plugin + initLogos
│   ├── lib/                   # InMemoryStore, exif_strip, storage_client, delivery_client
│   └── tests/                 # protobuf round-trip, geohash, strip pipeline + exiftool gate
└── logos-witness-ui-qml/      # UI LGX module (QML)
    ├── flake.nix              # pinned to logos-module-builder commit 5e196e2769
    ├── metadata.json          # view = qml/Main.qml, icon = icon.png
    ├── icon.svg               # sidebar icon (source)
    ├── icon.png               # sidebar icon (128×128, shipped in the .lgx)
    ├── qml/                   # bundled as the view directory
    │   ├── Main.qml           # map + timeline + cursor + upload banner + Delivery/Storage pills
    │   ├── SubmitDialog.qml   # photo + map + when + submit
    │   ├── MapView.qml        # OSM map, click → geohash-8 pin / display markers
    │   ├── TimeCursor.qml     # SPEC §11 centered-playhead time cursor
    │   ├── TimelineModel.js   # store + window + opacity helpers (unit-tested)
    │   ├── SubmitHelpers.js   # unit-tested arg/timestamp helpers
    │   ├── QtLocation/        # vendored Qt 6.9.2 QML import (see README)
    │   └── QtPositioning/     # vendored Qt 6.9.2 QML import (see README)
    └── tests/                 # qmltestrunner unit tests
```

## License

Dual-licensed under either of:

- MIT License ([LICENSE-MIT](./LICENSE-MIT))
- Apache License 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))

at your option. Contributions are accepted under the same dual licensing.
