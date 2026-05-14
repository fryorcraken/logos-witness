<img src="logos-witness-ui-qml/icon.png" alt="" width="96" align="right" />

# Logos Witness

A basecamp application for publishing anonymous, time- and place-anchored
photographs to the Logos network. Photos are stripped of all device metadata
before upload to Logos Storage; references are announced live over Logos
Delivery and durably committed in batches as on-chain inscriptions via
`zone-sdk`. Other instances of the app render contributions on a shared
map+timeline.

> **Status:** pre-alpha, Phases 1, 2.1, 2.2, 3.1, 3.2, and 3.3 of
> [`PLAN.md`](./PLAN.md) complete. Photos-only in v0; video and live
> capture are deferred. See [`SPEC.md`](./SPEC.md) for the authoritative
> design.

## What works today

The core module (`logos_witness_core`) builds, installs into a basecamp
profile, and round-trips through `logoscore` against an in-memory stub
store. The UI module (`logos_witness_ui_qml`) loads in basecamp and
exposes two buttons: "ping core" calls `listInscriptions` via the
`logos.callModule()` bridge and renders the JSON result; "Submit photo…"
opens a modal dialog with three tabs — Photo (JPEG picker, filename
only — see "Vendored Qt imports" below for why there is no preview),
Location (OSM map; click selects a place, drops a precision-8 geohash
pin, lat/lon are copy-able), and When (defaults to now, editable to
backdate). Submit stays disabled until all three inputs are set, then
calls `submitPhoto(filePath, unixSecondsString, geohash8)` against the
in-memory stub core via `logos.callModule()`; the dialog closes on
success. No network photo flow yet: strip pipeline (Phase 4), Storage
(5), Delivery (6) and `zone-sdk` (7) replace the stubs in turn; the
post-submit map+timeline of received refs lands in 3.4. The
`Q_INVOKABLE` interface surface is locked so later phases can swap
implementations without disturbing callers.

| Concern                  | Today                                 | After Phase…                |
| ------------------------ | ------------------------------------- | --------------------------- |
| EXIF / metadata strip    | strip_jpeg → sha256 of stripped bytes | shipped Phase 4.1–4.3       |
| Photo storage            | nothing stored, just a hash           | Phase 5 (Logos Storage)     |
| Cross-instance discovery | none — single process only            | Phase 6 (Delivery pub/sub)  |
| On-chain inscription     | `flushBatch` is a no-op stub          | Phase 7 (zone-sdk)          |
| User interface           | submit flow against stub core (photo path + geohash + time → submitPhoto); no inline photo preview | Phase 3.4 (post-submit map + timeline) → 3.5 (scrubber) |

## Architecture at a glance

Two LGX modules, both built with Nix and installed into `logos-basecamp`:

| Module                 | Type | Role                                                             |
| ---------------------- | ---- | ---------------------------------------------------------------- |
| `logos_witness_core`   | core | EXIF strip, Storage upload, Delivery pub/sub, batch inscriber    |
| `logos_witness_ui_qml` | UI   | File picker, geohash-on-map selector, submit, map+timeline view (skeleton today, full UI in Phase 3) |

The single global Delivery topic will be `/logos-witness/1/inscriptions/proto`.
Each on-chain reference is a protobuf `Reference` message —
`{schema_version, content_hash, timestamp, geohash}` — with a
precision-8 geohash. See `logos-witness-core/proto/reference.proto`.

## Prerequisites

- Linux x86_64 / aarch64 or macOS arm64 / x86_64
- ≥ 10 GB free disk
- [Nix](https://nixos.org/download.html) with flakes enabled
- The `lgs` scaffold CLI ([`logos-co/logos-scaffold`](https://github.com/logos-co/logos-scaffold))
- Git

## Quickstart

Two ways to run today: the **CLI flow** (`logoscore`, easy, no GUI) and the
**UI flow** (basecamp window, requires an env wedge — see "Launching the UI"
below for why).

```bash
git clone https://github.com/fryorcraken/logos-witness.git
cd logos-witness

# 1. Resolve and build basecamp + lgpm + alice/bob profiles.
lgs basecamp setup

# 2. Build + install both modules into the alice/bob profiles.
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

# 3. Submit a photo (stub: no strip, no Storage; just hash + in-memory store).
echo "demo photo" > /tmp/demo.jpg
/tmp/logoscore/bin/logoscore call logos_witness_core submitPhoto /tmp/demo.jpg 1714867200 u4pruydq
# → {"result":{"content_hash":"e0...","ok":true},"status":"ok"}

# 4. List references back.
/tmp/logoscore/bin/logoscore call logos_witness_core listInscriptions
# → {"result":[{"content_hash":"e0...","geohash":"u4pruydq","schema_version":1,"timestamp":1714867200}],"status":"ok"}

# 5. Manual batch flush is a no-op stub today (zone-sdk inscribe lands in Phase 7).
/tmp/logoscore/bin/logoscore call logos_witness_core flushBatch
# → {"result":{"flushed":0,"note":"stub: zone-sdk inscribe wired in Phase 7","ok":true},"status":"ok"}

# 6. Stop the daemon when finished.
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

No inline photo preview: basecamp installs a DenyAll `QNetworkAccessManager`
on every UI plugin's QML engine, so `Image.source = file://<path>` is
rejected for any local file path. The Photo tab shows the filename only;
the core module (which has unrestricted filesystem access) reads the bytes
on submit. Inline preview returns when basecamp exposes a sanctioned local
image-provider API, or when we move photos through Logos Storage first
(Phase 5).

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
# Protobuf reference codec round-trip (Phase 1.2).
cd logos-witness-core
nix develop --command bash -c '
  cmake -B build -GNinja \
    && cmake --build build --target test_reference_codec \
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
├── PLAN.md                    # phase-ordered task breakdown
├── LICENSE-MIT
├── LICENSE-APACHE
├── scaffold.toml              # basecamp pin + module registry
├── scripts/
│   └── launch-witness.sh      # env-wedge launcher (see "UI flow")
├── logos-witness-core/        # core LGX module (C++17 / Qt 6)
│   ├── CMakeLists.txt
│   ├── flake.nix              # pinned to logos-module-builder commit 5e196e2769
│   ├── metadata.json
│   ├── proto/reference.proto  # wire / on-chain schema
│   ├── src/                   # interface + plugin + initLogos
│   ├── lib/                   # InMemoryStore (stub backend, Phase 1)
│   └── tests/                 # protobuf round-trip
└── logos-witness-ui-qml/      # UI LGX module (QML)
    ├── flake.nix              # pinned to logos-module-builder commit 5e196e2769
    ├── metadata.json          # view = qml/Main.qml, icon = icon.png
    ├── icon.svg               # sidebar icon (source)
    ├── icon.png               # sidebar icon (128×128, shipped in the .lgx)
    ├── qml/                   # bundled as the view directory
    │   ├── Main.qml           # ping-core + open-submit-dialog buttons
    │   ├── SubmitDialog.qml   # photo (3.1) + map (3.2) + when + submit (3.3)
    │   ├── MapView.qml        # OSM map, click → geohash-8 pin
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
