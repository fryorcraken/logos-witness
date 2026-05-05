# Logos Witness

A basecamp application for publishing anonymous, time- and place-anchored
photographs to the Logos network. Photos are stripped of all device metadata
before upload to Logos Storage; references are announced live over Logos
Delivery and durably committed in batches as on-chain inscriptions via
`zone-sdk`. Other instances of the app render contributions on a shared
map+timeline.

> **Status:** pre-alpha. Photos only in v0; video and live capture are
> deferred. See [`SPEC.md`](./SPEC.md) for the authoritative design.

## Architecture at a glance

Two LGX modules, both built with Nix and installed into `logos-basecamp`:

| Module               | Type | Role                                                             |
| -------------------- | ---- | ---------------------------------------------------------------- |
| `logos_witness_core`   | core | EXIF strip, Storage upload, Delivery pub/sub, batch inscriber    |
| `logos_witness_ui_qml` | UI   | File picker, geohash-on-map selector, submit, map+timeline view  |

The single global Delivery topic is `/logos-witness/1/inscriptions/proto`.
Each on-chain reference is a CBOR map: `{v, h, t, g}` — schema version,
sha256 of the stripped photo, unix timestamp, geohash precision-8.

## Prerequisites

- Linux x86_64 / aarch64 or macOS arm64 / x86_64
- ≥ 10 GB free disk
- [Nix](https://nixos.org/download.html) with flakes enabled
- The `lgs` scaffold CLI ([`logos-co/logos-scaffold`](https://github.com/logos-co/logos-scaffold))
- Git

## Quickstart

```bash
git clone https://github.com/<org>/logos-witness.git
cd logos-witness

# Resolve and install the pinned basecamp + both modules.
lgs basecamp setup
lgs basecamp install

# Launch basecamp with Witness installed.
lgs basecamp launch
```

In basecamp, open **Witness Map**, click **Submit**, pick a photo, confirm
the timestamp and geohash, and submit. The reference appears on the map
immediately on every running instance subscribed to the Delivery topic.

To commit the pending references on-chain, click **Commit batch** (manual
trigger only in v0).

## Build a single module manually

```bash
# Core
cd logos-witness-core
nix build '.#lgx'             # dev
nix build '.#lgx-portable'    # portable

# UI
cd ../logos-witness-ui-qml
nix build '.#lgx'
```

Inspect a built module:

```bash
nix build 'github:logos-co/logos-module/tutorial-v1#lm' --out-link ./lm
./lm/bin/lm metadata logos-witness-core/result/lib/logos_witness_core_plugin.so
./lm/bin/lm methods  logos-witness-core/result/lib/logos_witness_core_plugin.so
```

## Test

```bash
# Unit tests (Qt Test)
cd logos-witness-core
nix develop --command bash -c 'cmake -B build -GNinja && cmake --build build && ctest --test-dir build'

# Strip-pipeline residual-metadata gate (must report no identifying tags)
exiftool -a -G1 logos-witness-core/tests/fixtures/*.stripped.jpg
```

See [`SPEC.md` §6](./SPEC.md#6-testing-strategy) for the integration and
end-to-end layers.

## Privacy posture

The on-chain payload is intentionally minimal: hash, timestamp, geohash.
No signer, no device ID, no app install ID. Network-layer anonymity is
provided by Logos Core / Delivery transport; the chain entry itself
carries nothing that links contributions to a single origin. Geohash
precision is fixed at 8 (~20 m).

The strip pipeline is fail-closed: any failure to verify that EXIF, XMP,
ICC, maker-notes, and embedded thumbnails are gone aborts the upload.
There is no `--keep-metadata` flag.

See [`SPEC.md` §7 Boundaries](./SPEC.md#7-boundaries) for the full set of
non-negotiable rules. **This README is part of the contract** — any change
to install, build, run, or interaction surface MUST update this file in
the same commit.

## Repository layout

```
logos-witness/
├── README.md                 # this file
├── SPEC.md                   # authoritative design & boundaries
├── LICENSE-MIT
├── LICENSE-APACHE
├── scaffold.toml             # basecamp pin + module registry
├── logos-witness-core/         # core LGX module (C++17 / Qt 6)
└── logos-witness-ui-qml/       # QML UI LGX module
```

## License

Dual-licensed under either of:

- MIT License ([LICENSE-MIT](./LICENSE-MIT))
- Apache License 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))

at your option. Contributions are accepted under the same dual licensing.
