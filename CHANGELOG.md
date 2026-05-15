# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The v0.0.x line is pre-release territory: shape changes are routine,
binary format changes are flagged but not yet stabilised. Don't depend
on it from production tooling. The v0.1.0 final tag is the first
intended-to-be-stable cut and ships with the SPEC §9 four-platform
matrix.

## [0.0.1] — 2026-05-15

First tagged build of the witness app. Linux x86_64 only.

### Added

- Two-instance live cross-instance feed via the upstream
  `delivery_module` (waku-derived). Submitting a photo on instance A
  surfaces it on instance B's timeline + map within seconds.
- Storage integration: stripped JPEG bytes are uploaded to Logos
  Storage and addressed by CID. The CID is shown on every timeline
  row (truncated) and in the Reference detail dialog (full).
- EXIF/XMP/ICC/maker-notes/thumbnail strip pipeline with an
  exiftool-based residual-metadata gate in CI.
- Upload status banner (Uploading / Saved locally — not broadcast /
  Upload failed + Retry).
- Live / Offline indicator for the Delivery feed in the Timeline
  header.
- Time-cursor navigator along the bottom (centered-playhead per
  SPEC §11) with day/week/month/year scale presets and a density
  curve above the cursor line.

### Known gaps (closed before v0.1.0)

- Phase 7 not implemented: no on-chain inscription via `zone-sdk`;
  `flushBatch()` is a stub that always returns `ok: true`.
- Phase 8 not implemented: missing-blob UX (greyed-out marker) is
  pending — clicking a marker for a CID that's unreachable surfaces
  an inline error instead of degrading gracefully.
- Default submit timestamp is "now" (dialog open time) rather than
  EXIF `DateTimeOriginal`. Users browsing the past on the time
  cursor will not see fresh refs in the visible window. Fix is
  tracked.
- Storage `bootstrap-node` config gap: instances discover peers via
  UPnP + local discv5 only. Cross-instance photo *fetch* doesn't
  work without manual SPR exchange. Delivery is unaffected (uses
  the public logos.dev waku fleet).
- Single-platform release: macOS and Linux aarch64 builds land
  before the v0.1.0 final tag.

### Internal

- See `PLAN.md` for the full phase status, code-review history, and
  the deferred follow-up list.

[0.0.1]: https://github.com/fryorcraken/logos-witness/releases/tag/v0.0.1
