# Implementation Plan: Logos Witness v0

> Companion to `SPEC.md`. Vertical slices, dependency-ordered, sized S/M.
> Each task has acceptance criteria and a concrete verification step.

## Status (2026-05-12)

**Done:** Phase 0 (skipped — scaffold pin assumed working), 1.1 / 1.2 / 1.3,
2.1, 2.2 (bring-up in basecamp; basecamp + lgpm + module-builder pins
bumped, vendored Qt6 QtLocation/QtPositioning imports, env-wedge launcher),
3.1, 3.2, 3.3, 3.4 (map + timeline app shell + decode invokables + SPEC §2
amendment locking decoders into the core surface).

**Re-opened:** 3.5 — first pass shipped a `RangeSlider` (two free
handles, hard filter). Dogfooding surfaced both a reactivity bug
(plain-JS array reads not re-evaluating) and, more importantly, that
the design was thin. SPEC §11 now defines a proper time cursor:
centered playhead, day/week/month/year scaling, opacity-graded markers,
YouTube-style density curve. 3.5 below is rewritten against §11.

**Resume here:** Phase 3.5 redux — implement SPEC §11 time cursor.
Once that lands, Phase 3 checkpoint review + Phase 4 (strip pipeline).

**Notable deviations from the original plan**, documented in commit history
and reflected in the per-task checkboxes below:
- 3.1 acceptance criterion "image renders" is technically NOT met under
  basecamp: the UI plugin's QML engine has a deny-all
  `QNetworkAccessManager` that rejects `Image.source = file://<path>`. We
  ship filename-only on the Photo tab; the core module reads the bytes on
  submit (its process has unrestricted filesystem access). Inline preview
  returns when basecamp exposes a sanctioned local-image provider or when
  photos move through Logos Storage (Phase 5). Documented in
  `SubmitDialog.qml` header and SPEC §7 item 6.
- 3.2 chose OSM tile servers over a bundled offline tile source. SPEC §7
  item 11 carries a temporary carve-out; long-term target is tile
  distribution over Logos Storage as a separate prototype project. The
  zoom cap (z=9) is enforced inside `MapView.qml` via
  `minimumZoomLevel`/`maximumZoomLevel`; the UI no longer narrates the
  cap to users (it was internal copy on a non-interactive control).
- 3.3 default timestamp is "now" (dialog open time), not file mtime —
  reading mtime from a `file://` URL would have required either a new
  `Q_INVOKABLE` on the locked Phase 1.3 core interface or a C++ helper in
  the pure-QML UI module. Picker is fully editable to backdate. EXIF
  DateTimeOriginal auto-fill is mentioned in the When-tab label as a TBD.
- Phase 2.2 (bring-up in basecamp) was unplanned: getting the UI module
  to actually load + run in basecamp required cascading pin bumps
  (basecamp → pre-release-b44a5cf-260, lgpm → main, module-builder →
  5e196e2769), a metadata.json migration to manifest v0.2.0 (`view`
  replacing `main`), vendoring of Qt 6.9.2 QtLocation/QtPositioning QML
  imports, and a launcher script that bypasses basecamp's wrapper to
  inject `QT_PLUGIN_PATH`. See README → "Vendored Qt imports" and
  `scripts/launch-witness.sh`. SPEC §7 item 6 captures the sandbox
  constraints this work surfaced.
- A bundle-completeness CI gate was added during 3.1 after a silent-drop
  trap (untracked QML files don't appear in the lgx bundle). Scoped to
  top-level `*.qml` during 3.3 to allow `tests/` files to coexist.

## Overview

Build the v0 application end-to-end — from `lgs basecamp setup` to a
two-instance demo in which a stripped photo submitted on instance A appears
on instance B's map+timeline within seconds (live via Delivery) and survives
a manual batch flush (durable via on-chain inscription). Two LGX modules,
both Nix-built, both installed by `lgs basecamp install`.

UI ships before the real Storage / Delivery / `zone-sdk` integrations, working
against an **in-memory stub core**. Real backends slot in behind the same
interface afterwards. This means the user-facing flow is validated and
demo-able well before the riskier protocol integrations land, and the stub
core also serves as a known-good baseline if a backend integration starts
misbehaving later.

## Architecture Decisions

Carried over from `SPEC.md` §2; restated for this plan's bottom-up dependency
ordering:

- **Two-module split:** `logos_witness_core` (C++17 / Qt 6, headless) and
  `logos_witness_ui_qml` (QML UI), per the lgx core / UI module shapes
  documented in the basecamp journey docs.
- **Wire format: protobuf**, single source of truth at
  `logos-witness-core/proto/reference.proto`. Generated C++ via `protoc` in
  CMake. Aligns with `lssa-idl/0.1.0` framework.
- **In-memory stub core first.** `submitPhoto` / `listInscriptions` /
  `flushBatch` operate on a process-local store until the real backends
  replace them, slice by slice.
- **Anonymity is network-layer**, not payload-layer. On-chain reference is
  `Reference{schema_version, content_hash, timestamp, geohash}` — no signer.
- **Manual batch inscription** for v0; signing/tx interface assumed unstable.
- **Single global Delivery topic** `/logos-witness/1/inscriptions/proto`.

## Dependency Graph (high-level)

```
Phase 0: Tooling smoke (basecamp + hello-world module)
              │
Phase 1: Core skeleton + protobuf + interface stubs (in-memory)
              │
Phase 2: UI module skeleton + logos.callModule wiring
              │
Phase 3: Submit dialog + map/timeline against stub core (UI vertical)
              │
Phase 4: Strip pipeline (still no network) ─────────────────┐
              │                                             │
Phase 5: Storage integration (real bytes flow)              │
              │                                             │
Phase 6: Delivery integration (live cross-instance feed) ───┤
              │                                             │
Phase 7: Pending queue + manual inscribe (zone-sdk) ────────┤
              │                                             │
Phase 8: Missing-blob UX (closes Phase 5 loose end) ────────┘
              │
Phase 9: CI + Release
```

Phases 0–3 deliver a single-instance demoable app on the stub core. From
Phase 4 onwards, each phase swaps one stubbed concern for the real one
without breaking the UI.

---

## Phase 0 — Tooling smoke test

Validate that basecamp + scaffold work on this machine before any code lands.
The riskier probes (`zone-sdk` inscribe shape, `easylibstorage` reliability)
move into their consuming phases.

### Task 0.1: Confirm `lgs basecamp setup` resolves a usable basecamp

**Description:** Run `lgs basecamp setup` against the pin in `scaffold.toml`,
confirm caches resolve and a basecamp build succeeds.

**Acceptance criteria:**
- [ ] `lgs basecamp setup` exits 0
- [ ] `lgs basecamp launch` opens a basecamp window with no Witness modules
- [ ] If the pin is broken, document the failure and bump to a working pin

**Verification:** `lgs basecamp launch` shows a basecamp UI, then close.

**Dependencies:** None. **Scope:** XS.

### Task 0.2: Build and inspect a hello-world core module

**Description:** Scaffold a throwaway core module from
`logos-module-builder/tutorial-v1`, build it, install into basecamp, verify
methods exposed via `lm`. Discard after.

**Acceptance criteria:**
- [ ] `nix build '.#lgx'` succeeds against the template
- [ ] `lm methods` lists the template's `doSomething` method
- [ ] `lgpm install` puts the .lgx into basecamp's modules dir
- [ ] `logoscore call <module> doSomething hi` returns the expected value

**Verification:** Output of `lgs basecamp launch` shows the throwaway module
loaded; `logoscore call` round-trip succeeds.

**Dependencies:** 0.1. **Scope:** S.

### Checkpoint: Phase 0 done

- [ ] Toolchain works end-to-end on dev machine
- [ ] Scaffold pin is confirmed-working or bumped

---

## Phase 1 — Core skeleton + protobuf + interface (in-memory stubs)

Foundation. Everything else depends on this.

### Task 1.1: Scaffold `logos-witness-core` from logos-module-builder

**Description:** `nix flake init -t github:logos-co/logos-module-builder/tutorial-v1`
in `logos-witness-core/`, rename all placeholders to `logos_witness_core`
in lockstep across `metadata.json`, `CMakeLists.txt`, `*_interface.h`,
`*_plugin.h`, `*_plugin.cpp`. Verify `nix build '.#lgx'` produces a `.so`
with the right name.

**Acceptance criteria:**
- [ ] `nix build '.#lgx'` succeeds
- [ ] `lm metadata` shows `name: "logos_witness_core"`, version `0.1.0`
- [ ] `lm methods` shows only `initLogos`
- [ ] `grep -r witness_map .` returns nothing (no leftover placeholders)

**Verification:** `lm` output matches; build clean.

**Dependencies:** Phase 0. **Files:** `logos-witness-core/{flake.nix,
metadata.json,CMakeLists.txt,src/*}`. **Scope:** S.

### Task 1.2: Add protobuf schema + generation in CMake

**Description:** Create `proto/reference.proto` with `Reference` and
`ReferenceBatch` per SPEC §2. Add `protoc --cpp_out` invocation in CMake
(driving from the `logos_module()` macro or a `proto/CMakeLists.txt`).
Add `protoc` to flake inputs.

**Acceptance criteria:**
- [ ] `nix build '.#lgx'` still succeeds
- [ ] Generated `reference.pb.{h,cc}` exist under `build/` (not committed)
- [ ] A trivial encode-then-decode round-trip in a smoke test passes

**Verification:** `ctest` after adding a single protobuf round-trip unit
test; passes.

**Dependencies:** 1.1. **Files:** `proto/reference.proto`,
`CMakeLists.txt`, `flake.nix`, `tests/test_reference_codec.cpp`.
**Scope:** M. **Risk:** MEDIUM (Qt + protoc + Nix wiring).

### Task 1.3: Interface methods backed by an in-memory stub store

**Description:** Declare the full `Q_INVOKABLE virtual` surface and
implement it against a process-local `InMemoryStore`:

- `QVariantMap submitPhoto(QString filePath, QString timestamp, QString geohash)`
  → reads the file, computes sha256, builds a `Reference`, stores in memory,
  emits `referenceObserved`. `timestamp` is a decimal-string of unix
  seconds: `logoscore` and the LogosAPI marshalling both forward numeric
  args as `QString`, so a `qint64` slot fails the QMetaObject invocation
  with "method not invokable".
- `QVariantList listInscriptions(QVariantMap filter)` and zero-arg
  `QVariantList listInscriptions()` → returns all stored Refs (filter
  ignored in stub). The zero-arg overload exists because CLI/JS callers
  cannot easily construct a wire-side QVariantMap.
- `QVariantMap flushBatch()` → no-op in stub, returns `{ "ok": true,
  "flushed": <N> }`.
- `void subscribeFeed()` (signals carry events).
- `QVariantMap decodeReference(QByteArray refBytes)` → pure function over
  wire-format bytes; returns the same shape `listInscriptions` entries
  use. UI consumes `referenceObserved` payloads through this.
- `QVariantMap decodeGeohash(QString geohash)` → returns
  `{latitude, longitude}` of the geohash centroid. UI needs this to
  place markers; SPEC §2 stores geohash only.
- Signals: `referenceObserved(QByteArray refBytes)`,
  `inscriptionsLoaded(QVariantList refs)`.

  The decoder invokables were added to the SPEC after Phase 1 landed
  (see SPEC §2 Core module surface) — they were missing from the
  original interface and get added as part of Task 3.4's first
  sub-step.

The interface is the contract for the rest of the project. The stub
behaviour is replaced phase-by-phase — the interface does not change.

**Acceptance criteria:**
- [ ] Interface ID is `org.logos.LogosWitnessCoreInterface`
- [ ] `lm methods` lists every method as invokable
- [ ] Single-instance round-trip via `logoscore`: submit → list returns
      the submitted ref
- [ ] `initLogos` assigns to global `logosAPI`, not a member
- [ ] No file metadata is read or stored (paths only); no network calls

**Verification:** `lm methods --json` matches expected surface; scripted
`logoscore` submit + list round-trip succeeds.

**Dependencies:** 1.1, 1.2. **Files:** `src/logos_witness_core_interface.h`,
`src/logos_witness_core_plugin.{h,cpp}`, `lib/in_memory_store.{h,cpp}`.
**Scope:** M.

### Checkpoint: Phase 1 done

- [ ] Both core builds (dev and portable) clean
- [ ] Single-instance submit/list round-trip works against the stub
- [ ] README updated with `lgs` invocations now that they work against
      this repo (SPEC §7.5)

---

## Phase 2 — UI module skeleton

### Task 2.1: Scaffold `logos-witness-ui-qml` ✅ DONE (commit 6162286)

**Description:** `nix flake init` from the QML UI template variant.
Rename placeholders. Wire a tiny JS helper around
`logos.callModule("logos_witness_core", ...)`.

**Acceptance criteria:**
- [x] UI module builds via `nix build '.#lgx'`
- [x] Installs into basecamp's UI plugins dir via `lgpm`
- [x] Renders a placeholder window when launched in basecamp
- [x] A "ping core" button calls `listInscriptions` and renders the
      (empty) result

**Verification:** Manual launch via `lgs basecamp launch`; ping returns.

**Dependencies:** 1.3. **Scope:** M.

---

### Task 2.2: Bring-up in basecamp (unplanned) ✅ DONE

**Description:** Get the UI module to actually load + run in a current
basecamp window. The originally-targeted basecamp (and the modules
built against `logos-module-builder/tutorial-v1`) used an older
manifest format that newer basecamp / lgpm reject. Required cascading
pin bumps, a manifest migration, vendoring two Qt6 QML imports, and a
custom launcher.

**Acceptance criteria:**
- [x] basecamp pin bumped to a release with the v0.2.0 manifest
      contract (`pre-release-b44a5cf-260` at the time of writing); see
      `scaffold.toml` rationale comment.
- [x] `logos-package-manager` pinned to a `main` commit that emits the
      v0.2.0 manifest + integrity hashes during `lgpm install`.
- [x] `logos-module-builder` pinned to a commit whose
      `mkLogosQmlModule` packager understands the new manifest +
      bundles the whole `qml/` view directory (the old default copied
      only the named view file).
- [x] `logos-witness-ui-qml/metadata.json` migrated: `view: qml/Main.qml`
      replacing `main: Main.qml`; QML moved under `qml/`.
- [x] `logos-witness-core/src/logos_witness_core_plugin.cpp::initLogos`
      stops deleting the framework-set `logosAPI` global; without this
      change the new framework's QRemoteObjects registry never came up
      and the UI's `logos.callModule()` calls hung.
- [x] `QtLocation` + `QtPositioning` (Qt 6.9.2, matching basecamp's
      `qtdeclarative`) vendored under `logos-witness-ui-qml/qml/` so
      `MapView.qml` resolves at runtime; refresh procedure documented
      in README → "Vendored Qt imports".
- [x] `scripts/launch-witness.sh` replicates basecamp's wrapper env,
      prepends our QtLocation/QtPositioning paths to `QT_PLUGIN_PATH`
      and `LD_LIBRARY_PATH`, then execs `.LogosBasecamp` directly. The
      stock `lgs basecamp launch` wrapper hard-overrides
      `QT_PLUGIN_PATH`, so injection has to happen post-wrapper.

**Verification:** `./scripts/launch-witness.sh alice` — basecamp comes
up, the witness icon appears in the sidebar, clicking it loads the UI
without an instant unload, "ping core" returns the empty inscription
list, and the Submit dialog walks Photo → Location → When → Submit
against the stub core with `ok: true`.

**Dependencies:** 2.1. **Scope:** L (the work was discovery-heavy).
The remaining sandbox constraints (no inline photo preview, vendored
Qt imports) are captured in SPEC §7 item 6.

---

## Phase 3 — UI vertical against the stub core

The user-facing flow becomes demo-able here. No network, no Storage, no
chain — the stub core is the entire backend. This is the moment to
iterate on UX with cheap iteration cost.

### Task 3.1: File picker + photo preview ✅ DONE (commit 9074053; preview deferred — see deviation)

**Description:** `SubmitDialog.qml` — open file picker, show photo preview,
no auto-publish.

**Acceptance criteria:**
- [x] picker opens, no calls to core yet
- [~] image renders **— deferred.** Under basecamp the UI plugin's QML
      engine has a deny-all `QNetworkAccessManager` that rejects
      `Image.source = file:///<path>`. Photo tab shows filename only;
      the picked path is read by the core module on submit. Inline
      preview returns when basecamp exposes a sanctioned local-image
      provider or when Storage (Phase 5) routes photos through a URL
      the sandbox permits. Documented in SPEC §7 item 6.

**Verification:** Manual.

**Dependencies:** 2.1. **Scope:** S.

### Task 3.2: Geohash drop-pin on map ✅ DONE (commit 9074053)

**Description:** `MapView.qml` — Qt Location's `osm` plugin renders OSM
tiles at low zoom (max z=9, no street-name detail); click drops a pin
and emits `pinned(geohash, lat, lon)`. SPEC §7 item 11 carries an
explicit, temporary carve-out for OSM tiles as the sole permitted
external data source for v0; long-term direction is tile distribution
over Logos Storage as a separate prototype project.

**Acceptance criteria:**
- [x] Click on map → `geohash` string returned to caller
- [x] ~~Tile source is fully offline / bundled (no third-party API)~~
      **Deviated:** OSM tile servers, capped at z=9. Carved out
      explicitly in SPEC §7 item 11. README privacy section flags
      that map browse leaks IP + viewed region to OSMF, in contrast
      to the anonymous submission pipeline.
- [x] Precision is exactly 8 characters

**Bonus shipped:** lat/lon readout with copy-to-clipboard so users can
paste into another app to verify the pin location.

**Verification:** Manual.

**Dependencies:** 2.1. **Scope:** M. **Risk:** MEDIUM — landed.

### Task 3.3: Timestamp confirm + submit wire-up ✅ DONE (commit f48bc28)

**Description:** Submit tab + Submit button. Calls `submitPhoto(filePath,
timestamp, geohash)` on the stub core. Default timestamp deviates from
the original "file mtime" plan — see Status section above for rationale.

**Acceptance criteria:**
- [x] User cannot submit without explicit confirmation click (SPEC §7.2):
      Submit button stays disabled until file + pin + timestamp are all
      set; no auto-publish path exists.
- [x] On success the dialog closes; the new Ref appears in the map view
      once Task 3.4 lands. Today the stub core's `referenceObserved`
      signal fires after a successful submit; 3.4 consumes it.

**TDD shipped:** `SubmitHelpers.js` + `tests/tst_submit_helpers.qml`
(7 unit tests under `qmltestrunner`, wired into CI). Covers
`unixSecondsString`, `canSubmit`, `filePathFromUrl`. The dialog inlines
the same logic because the lgx UI builder only globs top-level
`*.qml` into the bundle.

**Verification:** Manual e2e in basecamp against the stub core; CI
exercises the helper unit tests.

**Dependencies:** 3.1, 3.2, 1.3. **Scope:** S.

### Task 3.4: Map + timeline view fed by the stub core — NEXT

**Description:** Replace the current `Main.qml` (two buttons + JSON
status area) with the actual app shell — a full-window MapView (the
same `MapView.qml` from 3.2, but used in display mode, not picker mode)
overlaid with a scrollable timeline panel. On module init, call
`listInscriptions()` to seed the model; subscribe to
`referenceObserved` for live updates from the core. Click a marker →
fetch the blob (stub: just shows the local file path, since there is
no Storage yet). The Submit button stays in `Main.qml` and opens the
existing `SubmitDialog`.

**Concrete pointers for the next session:**
- `MapView.qml` currently mixes "click to pick a geohash" with display.
  Add a `pickable` bool prop (default true to preserve 3.2 callers): when
  false, the click MouseArea and the floating geohash readout/copy frame
  are inert. Same component handles both pick and display.
- `referenceObserved(QByteArray refBytes)` carries a serialized
  `Reference` protobuf. Per SPEC §2 Core module surface, the UI decodes
  via the core's `decodeReference(QByteArray)` invokable — wire-format
  knowledge stays single-sourced in C++. Similarly, geohash → centroid
  for marker placement goes through `decodeGeohash(QString)`. Both
  invokables are now part of the locked interface; implement them in
  this task before the Main.qml rewrite.
- Live-update path is empirical. Start by trying to subscribe to
  `referenceObserved` from QML through the existing `logos` shim. If
  basecamp's host bridge does not forward module-side signals into the
  UI today, fall back to a 1 Hz `listInscriptions()` poll while the
  window is foreground. Either outcome is acceptable for 3.4; if the
  forwarding works, Phase 6 (Delivery) inherits a working signal path.
  If polling is forced, add a §7 sandbox carve-out documenting it
  alongside the existing `QNetworkAccessManager` deny-all and OSM tile
  notes.
- The "marker click → fetch blob" stub for v0 is just the local file
  path stored alongside the Ref. Phase 5 swaps in real Storage.
- A second `qmltest` is worth adding here for the timeline-model
  merge logic (live observed + historical scan dedupe-by-content_hash).

**Acceptance criteria:**
- [x] New Refs appear within 1 s of submit (single-instance) — `SubmitDialog.onAccepted`
      directly re-runs `listInscriptions`, no wait for the 5 s safety-net poll.
- [x] Reload of the UI re-fetches via `listInscriptions` and re-renders
      (`Component.onCompleted` calls `_refreshFromCore`).
- [ ] Click marker shows a placeholder photo view (real Storage in Phase 5)
      — currently shows a detail dialog with hash/geohash/timestamp + a
      "photo preview lands in Phase 5" note. Manual verify pending.

**Implementation notes (2026-05-12):**
- SPEC §2 was amended to add `decodeReference` and `decodeGeohash`
  invokables to the locked core surface. UI calls `decodeGeohash` per
  marker to resolve geohash → centroid for map placement.
- Geohash decode also lives in `logos-witness-core/lib/geohash.h` as a
  Qt-free header so `tests/test_geohash.cpp` can verify the Niemeyer-2008
  alphabet matches the encoder side (Wikipedia reference vectors).
- `TimelineModel.js` is a `.pragma library` JS module imported from
  `Main.qml`. Confirmed the lgx packager recursively copies the view
  directory (so `.js` files ship in the bundle) — the stale
  `SubmitHelpers.js` header comment was updated to reflect this.
- Live updates are poll-based for v0: `SubmitDialog.onAccepted` triggers
  an immediate refresh, plus a 5 s `Timer` safety net. The signal-
  forwarding probe is deferred to Phase 6 where the Delivery wiring
  needs cross-process signal transport anyway. No SPEC §7 carve-out
  required because the SPEC never mandated signal-driven UI updates.

**Verification:** Manual; submit 3 photos, see 3 markers + 3 timeline
entries; close and reopen, still 3.

**Follow-ups surfaced by review (track, do not block 3.4):**
- `decodeReference` silently accepts unknown `schema_version`. proto3
  forward-compat is intentional at the wire level, but the boundary
  decoder should at minimum surface the version to callers (or reject
  != 1 with an explicit error) once the schema actually moves. Revisit
  when Phase 6 (Delivery decode) or Phase 7 (chain-scan decode) lands —
  whichever first reads bytes produced by a foreign instance.
- `decodeGeohash` is invoked per-marker per-refresh via the host bridge.
  At v0 scale (<50 refs, 5 s poll) this is fine, but a `decodeGeohashes
  (list)` batch invokable, or memoising the centroid in `TimelineModel.js`
  keyed by geohash, would eliminate N synchronous round-trips per
  refresh. Pick whichever fits when timelines grow past hundreds of
  refs (Phase 7 historical scan is the natural trigger).
- SPEC §2 lists `ok` only on `decodeReference`'s output; `listInscriptions`
  entries omit it. Worth one extra sentence in §2 making that contrast
  explicit so a future reader writing a strict consumer doesn't assume
  every map is `{ok, …}`.

**Dependencies:** 3.3. **Scope:** M.

### Task 3.5: Time cursor (per SPEC §11) — REWRITE

**Description:** Replace the prior RangeSlider with a proper time cursor
matching SPEC §11. The cursor occupies the bottom strip of the main
window with: a centered playhead at `tm`, a day/week/month/year scale
selector, a today shortcut, ‹/› half-window step buttons, drag-to-pan
on the strip, opacity-graded map markers + timeline rows, and a
density curve (histogrammed refs/bin) above the cursor line.

The prior `RangeSlider` implementation (handles, `filterByRange`,
"Reset" button, `fromTs`/`toTs` properties) is removed in this same
task. `TimelineModel.filterByRange` stays as a building block — the
cursor's "show refs inside [t0, t1]" is exactly that, just driven by a
midpoint+width derivation rather than two handles.

**Acceptance criteria:**
- [ ] `TimeCursor.qml` component renders along the bottom, full-width
      minus the timeline rail. Scale row sits below the cursor line:
      `[Day] [Week] [Month] [Year]` with one highlighted (default
      `Year`); a `Today` shortcut and `‹` / `›` step buttons.
- [ ] Midpoint `tm` is bindable; defaults to `now` on first load.
      Switching scale recenters on current `tm` and updates `W`.
- [ ] Dragging the cursor strip horizontally pans `tm` (1 px =
      `W/stripWidthPx` seconds). `‹` / `›` step `tm` by `W/2`.
      `Today` snaps `tm = now`. Bounds enforced per §11.6.
- [ ] Refs outside `[t0, t1]` are hidden from both map and timeline
      (drop existing visibility rules in `Main.qml`'s
      `_rebuildBindings`). Counter shows `N of M refs`.
- [ ] Each visible marker + timeline row gets opacity per
      `TimelineModel.opacityFor(ts, tm, W)`: 1.0 at midpoint, 0.15 at
      the edges, linear in between.
- [ ] Density curve above the cursor line: area chart over
      `binCounts(refs, t0, t1, binCount)`, auto-Y-scaled to the max bin.
      Curve hides cleanly when every bin is zero.
- [ ] `TimeCursor` emits `windowChanged(t0, t1)` on every
      `tm`/`scalePreset` commit; `Main.qml`'s `_rebuildBindings`
      consumes it (replacing the RangeSlider's `_scrubberMoved`).
- [ ] Reactivity bug from the first 3.5 pass does not recur: the
      cursor reads from explicit reactive properties on `Main.qml`
      (`entryCount`, `storeMinTs`, `storeMaxTs`), not from
      `store.entries.length` directly.

**Tests (qmltestrunner, in `TimelineModel.js`):**
- `windowFromMidpoint(tm, scalePreset)` — preset widths, symmetric
  window, reject unknown preset.
- `binCounts(refs, t0, t1, binCount)` — empty input, `t1` inclusion,
  half-open elsewhere, known-vector counts.
- `opacityFor(ts, tm, W)` — midpoint=1.0, edges=0.15, linearity,
  clamp for out-of-window inputs.
- `clampMidpoint(tm, W, oldest, now)` — future-side and past-side
  bounds, store-empty fallback.
- Existing `filterByRange` tests stay — the cursor uses it; the
  function survives the rewrite.

**Files touched:**
- `qml/TimeCursor.qml` — new component.
- `qml/Main.qml` — drop scrubber Frame + `fromTs/toTs` props +
  `_scrubberMoved`; mount `TimeCursor` instead; thread
  `windowChanged` into `_rebuildBindings`; apply
  `opacityFor` to timeline row + marker delegates.
- `qml/MapView.qml` — accept an `opacity` field per marker entry and
  bind the `markerDot.opacity` to it.
- `qml/TimelineModel.js` — add `windowFromMidpoint`,
  `binCounts`, `opacityFor`, `clampMidpoint`; keep `filterByRange`.
- `tests/tst_timeline_model.qml` — new tests above; tests that
  exercised "Reset button restores NaN" can be deleted.

**Verification:** `qmltestrunner` green. Manual e2e: submit ≥ 3
photos at different times spanning at least a few hours; confirm
midpoint markers are opaque, edge markers faint, out-of-window
absent. Switch scales; observe curve re-bin. Drag + step + Today
all change `tm` without changing `W`.

**Dependencies:** 3.4. **Scope:** M.

**First pass (closed):** RangeSlider with two free handles +
`filterByRange` + Reset. Shipped but did not survive design review or
dogfood — see SPEC §11 for why a centered-playhead model replaces it.
The pure-JS helpers from that pass (`filterByRange`, `storeTimeRange`)
and the reactivity scaffolding (`entryCount`, `storeMinTs/MaxTs` on
`Main.qml`) survive into the rewrite. The bundle-completeness CI gate
fix (scan `qml/*.qml` rather than empty top-level glob) also stays —
that bug was orthogonal.

### Checkpoint: Phase 3 done — demo-able single-instance app

- [ ] One-line demo: launch basecamp, open Witness, submit a photo, see
      it on the map. End-to-end, single instance, stub core
- [ ] README quickstart updated with the actual button sequence
- [ ] Screenshots in README (or a docs/ subfolder) for the demo

---

## Phase 4 — Strip pipeline

Now that the UI is settled, harden the bytes that will eventually reach
Storage. Still single-instance and no network.

### Task 4.1: `exif_strip` implementation

**Description:** Implement `lib/exif_strip.{h,cpp}` taking a JPEG byte
buffer and returning a stripped byte buffer. Rebuild the JPEG via libjpeg
(or QImage round-trip) so that no embedded EXIF/XMP/ICC/maker-notes/
thumbnails survive.

**Acceptance criteria:**
- [ ] Strips EXIF, XMP, ICC profile, maker-notes, embedded thumbnail
- [ ] Pixel content visually identical (byte-equal SHA-256 over decoded
      pixels)
- [ ] Fail-closed: malformed input returns an error, not partial output

**Verification:** Unit-test fixtures cover EXIF-rich, XMP-rich, ICC-tagged,
embedded-thumbnail, maker-notes variants. `exiftool -a -G1` on every
output reports nothing identifying.

**Dependencies:** 1.3. **Files:** `lib/exif_strip.{h,cpp}`,
`tests/fixtures/*.jpg`, `tests/test_exif_strip.cpp`. **Scope:** M.
**Risk:** MEDIUM — embedded thumbnails sometimes survive naive strips.

### Task 4.2: CMake `exiftool` residual-metadata gate

**Description:** Wire the test target so `ctest` invokes `exiftool -a`
over every produced fixture and fails the build on any identifying tag.
This is the SPEC §7.1 enforcement.

**Acceptance criteria:**
- [ ] `ctest` runs `exiftool` on stripped outputs and fails on residue
- [ ] CI surfaces the failure clearly (not buried in logs)

**Verification:** Inject a fixture that intentionally retains EXIF; ctest
fails. Remove fixture; ctest passes.

**Dependencies:** 4.1. **Files:** `CMakeLists.txt`, `tests/...`. **Scope:** S.

### Task 4.3: Wire strip into `submitPhoto` (still stub-stored)

**Description:** `submitPhoto` now strips before hashing/storing. The
hash committed to the Reference is over the *stripped* bytes (SPEC §2).
Storage backend remains the in-memory stub.

**Acceptance criteria:**
- [ ] Submitted hash matches sha256 of stripped bytes
- [ ] UI flow is unchanged from the user's perspective

**Verification:** Submit a photo; manually compute sha256 of the strip
output; match against the Reference's `content_hash`.

**Dependencies:** 4.1, 1.3. **Scope:** S.

### Checkpoint: Phase 4 done

- [ ] Strip pipeline + residual-metadata gate enforce SPEC §7.1 by test
- [ ] Bytes that will hit Storage in Phase 5 are now safe

---

## Phase 5 — Storage integration

First real-network phase. Replaces the stub blob store; in-memory Ref
metadata persists for now.

### Task 5.1: Probe `easylibstorage` round-trip

**Description:** Two-instance harness: put a 5 MB blob, retrieve it from
the second instance. Measure latency, confirm reachability, characterise
the failure mode for an unreachable blob.

**Acceptance criteria:**
- [ ] Two instances on the same machine round-trip a 5 MB blob in < 10 s
- [ ] Failure mode for unreachable blob is documented (return code or
      exception type) — feeds Phase 8

**Verification:** Throwaway harness logs put + get success and timings.

**Dependencies:** Phase 0. **Scope:** S. **Risk:** HIGH if availability
turns out to be flaky — re-shapes Phase 8 priority and may force a SPEC
amendment.

### Task 5.2: `easylibstorage` client integration

**Description:** Wire the `easylibstorage` plugin from basecamp via
`LogosAPI`. Replace the stub blob path in `submitPhoto`: stripped bytes
go to Storage; Reference still tracked in-memory by core for now.

**Acceptance criteria:**
- [ ] `submitPhoto` happy path puts stripped bytes and returns
      content_hash from Storage
- [ ] Round-trip: another instance can `get(content_hash)` and recover
      byte-equal data
- [ ] Marker-click in UI fetches the real blob from Storage and renders
      the photo

**Verification:** Two-instance manual e2e.

**Dependencies:** 5.1, 4.3. **Files:** `lib/storage_client.{h,cpp}`.
**Scope:** M.

### Checkpoint: Phase 5 done

- [ ] Real photos flow through Storage; UI displays them

---

## Phase 6 — Delivery integration

Replaces in-memory cross-instance fan-out (which never existed) with the
real live feed.

### Task 6.1: Delivery publish

**Description:** Wire the Delivery plugin via `LogosAPI`. Publish a
serialised `Reference` on `/logos-witness/1/inscriptions/proto` after
every successful `submitPhoto`.

**Acceptance criteria:**
- [ ] `submitPhoto` happy path publishes one message on the topic
- [ ] Payload is byte-equal to `Reference.SerializeAsString()`

**Verification:** Subscriber on a second instance receives the message
within 2 s.

**Dependencies:** 5.2. **Files:** `lib/delivery_client.{h,cpp}`. **Scope:** S.

### Task 6.2: Delivery subscribe + dedupe-by-hash

**Description:** Subscribe on module init. On message, decode `Reference`,
emit `referenceObserved` upward. Maintain in-memory set keyed by
`content_hash` to suppress duplicates from local submits.

**Acceptance criteria:**
- [ ] Two-instance: A submits, B's signal fires within 2 s, B's UI
      renders a marker
- [ ] Duplicate of the same content_hash does not re-emit

**Verification:** Scripted two-instance test.

**Dependencies:** 6.1. **Scope:** M.

### Checkpoint: Phase 6 done

- [ ] Live cross-instance feed works end-to-end
- [ ] No on-chain inscription yet; events are Delivery-only

---

## Phase 7 — Pending queue + manual inscribe

### Task 7.1: Probe `zone-sdk` inscribe API

**Description:** Read `zone-sdk/src/` at the basecamp-bundled pin.
Determine the inscribe call signature, async vs sync, signing requirement,
payload byte cap. Record findings in `SPEC.md` §10 Open questions.

**Acceptance criteria:**
- [ ] Inscribe API signature documented in SPEC §10
- [ ] Payload cap confirmed sufficient for a `ReferenceBatch` of ≥ 16
- [ ] Signing requirement (or absence) documented

**Verification:** SPEC §10 amended with concrete answers, not speculation.

**Dependencies:** Phase 0. **Scope:** S. **Risk:** HIGH — if signing
infra is not available to us, Phase 7 descopes to v0.2 and v0.1 ships
Delivery-only.

### Task 7.2: Pending-inscription queue persistence

**Description:** Implement `lib/pending_queue.{h,cpp}` — append-only
on-disk queue of unflushed `Reference` messages, location under the
basecamp app data dir. Survives process restart.

**Acceptance criteria:**
- [ ] `submitPhoto` enqueues after Storage put
- [ ] Restart preserves queue contents
- [ ] `flushBatch` drains atomically on success

**Verification:** Unit test for persistence + drain semantics.

**Dependencies:** 6.2. **Scope:** M.

### Task 7.3: Manual `flushBatch` via `zone-sdk` inscribe

**Description:** Encode queued Refs as `ReferenceBatch`, call
`zone-sdk.inscribe(payload)`, drain queue on success, retain on failure.

**Acceptance criteria:**
- [ ] Successful inscribe: queue empty, transaction id observable
- [ ] Failure path: queue retained, error surfaced via return value

**Verification:** Two-instance e2e: A submits 3 photos, A clicks Commit
batch, B's `listInscriptions` historical scan returns the three Refs.

**Dependencies:** 7.1, 7.2. **Scope:** M. **Risk:** HIGH — depends on 7.1.

### Task 7.4: `listInscriptions` historical scan

**Description:** Scan the chain for inscriptions on the witness namespace,
decode each `ReferenceBatch`, merge into in-memory index alongside the
Delivery feed.

**Acceptance criteria:**
- [ ] Cold-start instance with no Delivery history sees historical refs
      after one scan
- [ ] Geohash + time-range filter works (client-side filter is fine for
      v0)

**Verification:** Cold-start a third instance; it sees Refs that were
committed before it joined.

**Dependencies:** 7.3. **Scope:** M.

### Checkpoint: Phase 7 done

- [ ] Full data lifecycle: submit → live → flushed on-chain → discovered
      by a fresh instance via chain scan
- [ ] README updated with `flushBatch` operator workflow

---

## Phase 8 — Missing-blob UX

### Task 8.1: Greyed marker for unreachable blobs

**Description:** When `easylibstorage.get(content_hash)` fails (per the
failure mode characterised in 5.1), render the marker greyed; click
reveals "blob unreachable" detail.

**Acceptance criteria:**
- [ ] App does not crash on missing blob
- [ ] User can distinguish reachable vs missing markers at a glance

**Verification:** Inject a Ref whose blob doesn't exist; verify rendering.

**Dependencies:** 5.2, 6.2. **Scope:** S.

---

## Phase 9 — CI + Release

### Task 9.1: GitHub Actions CI workflow

**Description:** Implement SPEC §9 pipeline as `.github/workflows/ci.yml`
running on push and PR.

**Acceptance criteria:**
- [ ] All seven CI steps run (setup → install → inspect → unit → strip
      gate → headless integration → docs gate)
- [ ] Docs gate fails when user-facing surface changes without a README
      diff
- [ ] Time-to-green under 30 minutes after first cache fill

**Verification:** Open a test PR with an intentional README omission;
docs gate fails. Fix; passes.

**Dependencies:** Phases 1–7 (something to build). **Scope:** M.

### Task 9.2: Release workflow with `.lgx` asset upload

**Description:** Tag `v0.1.0` triggers a release workflow producing
per-platform `.lgx-portable` for both modules + combined tarball +
SHA256SUMS, attached via `gh release upload`.

**Acceptance criteria:**
- [ ] `git tag v0.1.0 && git push --tags` triggers the workflow
- [ ] Release page shows all required assets per SPEC §9
- [ ] Workflow refuses to publish if any CI gate failed

**Verification:** Cut a `v0.1.0-rc1` against this plan's completion.

**Dependencies:** 9.1, full feature set. **Scope:** M.

### Checkpoint: v0 ship-ready

- [ ] Two-instance demo works end-to-end
- [ ] CI green on `main`
- [ ] Release `v0.1.0-rc1` published with all assets
- [ ] README quickstart matches the live release

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `zone-sdk` inscribe API requires signing keys we don't have | HIGH | Task 7.1 surfaces this late, but the UI + Delivery path (Phases 1–6) ships independently; v0.1 can ship Delivery-only if Phase 7 blocks |
| `easylibstorage` retrieval flaky between instances | HIGH | Task 5.1 measures it; Phase 8 (missing-blob UX) is the safety net; if outright broken, escalate to a SPEC amendment before Phase 6 |
| `protoc` + Qt + Nix integration in lgx template | MEDIUM | Task 1.2 isolates the build wiring early; fallback is committing generated files (last resort) |
| Embedded JPEG thumbnails survive naive strip | MEDIUM | Phase 4 fixtures explicitly cover this; CMake `exiftool` gate is the safety net |
| Offline map tile source / licensing / size | MEDIUM | Task 3.2 resolves before any UI work commits; bundled MBTiles likely answer |
| basecamp module pin diverges from `master` HEAD APIs | MEDIUM | SPEC §7.4 is explicit; pin updates require SPEC amendment |
| UI built on stub then breaks on real backends (interface drift) | LOW | Task 1.3 freezes the interface; later phases swap implementations behind it without changing the Q_INVOKABLE surface |

## Open Questions

- `zone-sdk` inscribe API shape — answered in Task 7.1.
- Storage availability guarantees on basecamp v0.1 testnet — answered
  in 5.1; informs Phase 8 priority.
- Offline tile source — bundled MBTiles vs. rasterised at build vs. Qt
  Location offline cache. Decided in 3.2.
- CI runner OS for headless basecamp/logoscore — Linux x86_64 only for
  v0, or matrix? Decide before 9.1.

## Verification (this plan)

- [x] Every task has acceptance criteria and a verification step
- [x] Task dependencies are identified and ordered correctly
- [x] No task is XL — Phase 0 is XS/S, core/UI/strip mostly M, integrations S/M
- [x] Checkpoints exist between phases
- [x] UI ships before Storage / Delivery / `zone-sdk` per current direction
- [ ] **Human review and approval** — pending
