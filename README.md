# Logos Witness

A basecamp application for publishing anonymous, time- and place-anchored
photographs to the Logos network. Photos are stripped of all device metadata
before upload to Logos Storage; references are announced live over Logos
Delivery and durably committed in batches as on-chain inscriptions via
`zone-sdk`. Other instances of the app render contributions on a shared
map+timeline.

> **Status:** pre-alpha, Phases 1, 2.1, 3.1, and 3.2 of [`PLAN.md`](./PLAN.md)
> complete. Photos-only in v0; video and live capture are deferred. See
> [`SPEC.md`](./SPEC.md) for the authoritative design.

## What works today (Phases 1 + 2.1 + 3.1 + 3.2)

The core module (`logos_witness_core`) builds, installs into a basecamp
profile, and round-trips through `logoscore` against an in-memory stub
store. The UI module (`logos_witness_ui_qml`) loads in basecamp and
exposes two buttons: "ping core" calls `listInscriptions` via the
`logos.callModule()` bridge and renders the JSON result; "Submit photo…"
opens a modal dialog with a Photo tab (JPEG picker + preview) and a
Location tab (OSM map capped at zoom 9 — regional view, no street
detail; click drops a pin and shows the precision-8 geohash plus
six-decimal lat/lon, both with Copy buttons so you can paste into
another app to verify). The dialog is Cancel-only today — submit
wire-up to the core lands in Phase 3.3 once the timestamp confirm UI
is in place. No network photo flow yet: strip pipeline (Phase 4),
Storage (5), Delivery (6) and `zone-sdk` (7) replace the stubs in turn;
map+timeline of received refs land in 3.4. The `Q_INVOKABLE` interface
surface is locked so later phases can swap implementations without
disturbing callers.

| Concern                  | Today                                 | After Phase…                |
| ------------------------ | ------------------------------------- | --------------------------- |
| EXIF / metadata strip    | none — sha256 of raw bytes            | Phase 4                     |
| Photo storage            | nothing stored, just a hash           | Phase 5 (Logos Storage)     |
| Cross-instance discovery | none — single process only            | Phase 6 (Delivery pub/sub)  |
| On-chain inscription     | `flushBatch` is a no-op stub          | Phase 7 (zone-sdk)          |
| User interface           | submit dialog with photo picker + OSM-backed geohash drop-pin (z≤9) | Phase 3.3–3.5 (timestamp confirm, submit wire-up, map+timeline) |

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

Build and install both modules into the seeded `alice` basecamp profile.
The CLI flow drives the core module via `logoscore`; the UI flow needs
basecamp launched (manual eyeball today, full submit + map land in Phase 3).

```bash
git clone https://github.com/fryorcraken/logos-witness.git
cd logos-witness

# 1. Resolve and build basecamp + lgpm + alice/bob profiles.
lgs basecamp setup

# 2. Build both modules.
( cd logos-witness-core   && nix build '.#lgx' )
( cd logos-witness-ui-qml && nix build '.#lgx' )

# 3. Install into the alice profile.
BASECAMP_PIN=$(grep -oP '(?<=^pin = ")[^"]+' scaffold.toml | head -1)
LGPM=$HOME/.cache/logos-scaffold/basecamp/$BASECAMP_PIN/lgpm-result/bin/lgpm
ALICE=$PWD/.scaffold/basecamp/profiles/alice/xdg-data/Logos/LogosBasecampDev
$LGPM --modules-dir    "$ALICE/modules"     install --file logos-witness-core/result/logos-logos_witness_core-module-lib.lgx
$LGPM --ui-plugins-dir "$ALICE/ui-plugins"  install --file logos-witness-ui-qml/result/logos-logos_witness_ui_qml-lib.lgx
```

Then start `logoscore` and exercise the round-trip:

```bash
# 4. Build logoscore (cached after first run).
nix build 'github:logos-co/logos-logoscore-cli/tutorial-v1' --out-link /tmp/logoscore

# 5. Start the daemon, load the module.
/tmp/logoscore/bin/logoscore -D -m "$ALICE/modules"
/tmp/logoscore/bin/logoscore load-module logos_witness_core

# 6. Submit a photo (stub: no strip, no Storage; just hash + in-memory store).
echo "demo photo" > /tmp/demo.jpg
/tmp/logoscore/bin/logoscore call logos_witness_core submitPhoto /tmp/demo.jpg 1714867200 u4pruydq
# → {"result":{"content_hash":"e0...","ok":true},"status":"ok"}

# 7. List references back.
/tmp/logoscore/bin/logoscore call logos_witness_core listInscriptions
# → {"result":[{"content_hash":"e0...","geohash":"u4pruydq","schema_version":1,"timestamp":1714867200}],"status":"ok"}

# 8. Manual batch flush is a no-op stub today (zone-sdk inscribe lands in Phase 7).
/tmp/logoscore/bin/logoscore call logos_witness_core flushBatch
# → {"result":{"flushed":0,"note":"stub: zone-sdk inscribe wired in Phase 7","ok":true},"status":"ok"}

# 9. Stop the daemon when finished.
/tmp/logoscore/bin/logoscore stop
```

The module call signature is `submitPhoto(<path>, <unix_seconds>, <geohash_8>)`.
The timestamp is a decimal-string because `logoscore` and the LogosAPI
marshalling forward numeric args as `QString` — a `qint64` slot fails the
QMetaObject invocation silently. Geohash is precision-8 (≈ 20 m).

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
```

The strip-pipeline residual-metadata gate (`exiftool -a` on stripped
fixtures) lands in Phase 4. CI lands in Phase 9. See
[`SPEC.md` §6](./SPEC.md#6-testing-strategy) and
[`SPEC.md` §9](./SPEC.md#9-ci-and-release).

## Privacy posture

The on-chain payload is intentionally minimal: hash, timestamp, geohash.
No signer, no device ID, no app install ID. Network-layer anonymity is
provided by Logos Core / Delivery transport; the chain entry itself
carries nothing that links contributions to a single origin. Geohash
precision is fixed at 8 (~20 m).

The strip pipeline (Phase 4) is fail-closed: any failure to verify that
EXIF, XMP, ICC, maker-notes, and embedded thumbnails are gone aborts the
upload. There is no `--keep-metadata` flag. The Phase 1 stub does not
strip — it only hashes — so the in-memory `content_hash` reflects raw
bytes for now and will change shape once strip lands.

### Map tiles: a known v0 compromise

The submission pipeline is the part that's anonymity-shaped: stripped
bytes, hash-only references, no signer on chain, network-layer anonymity
via Logos Core. The **map browse** is not. v0 fetches tiles from
`tile.openstreetmap.org` (the SPEC §7.10 carve-out), which means every
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
├── logos-witness-core/        # core LGX module (C++17 / Qt 6)
│   ├── CMakeLists.txt
│   ├── flake.nix              # pinned to logos-module-builder/tutorial-v1
│   ├── metadata.json
│   ├── proto/reference.proto  # wire / on-chain schema
│   ├── src/                   # interface + plugin + initLogos
│   ├── lib/                   # InMemoryStore (stub backend, Phase 1)
│   └── tests/                 # protobuf round-trip
└── logos-witness-ui-qml/      # UI LGX module (QML)
    ├── flake.nix              # pinned to logos-module-builder/tutorial-v1
    ├── metadata.json
    ├── Main.qml               # ping-core + open-submit-dialog buttons
    ├── SubmitDialog.qml       # tabbed: photo picker (3.1) + map (3.2)
    ├── MapView.qml            # OSM map (z≤9), click → geohash-8 pin
```

## License

Dual-licensed under either of:

- MIT License ([LICENSE-MIT](./LICENSE-MIT))
- Apache License 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))

at your option. Contributions are accepted under the same dual licensing.
