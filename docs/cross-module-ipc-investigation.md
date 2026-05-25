# Cross-module IPC from third-party core plugins — investigation log

Living document. Tracks what we learned about cross-module RPC
failures when a third-party `core`-type plugin tries to call a sibling
module (storage_module / delivery_module) via the documented typed
accessor.

## Problem statement

`logos_witness_core` (our `type: core` plugin) needs to call:

- `m_logos->storage_module.init(...)` / `.start(...)` / `.uploadUrl(...)` / `.downloadToUrl(...)`
- `m_logos->delivery_module.createNode(...)` / `.subscribe(...)` / `.send(...)`

— from inside its `initLogos()` and Q_INVOKABLE methods.

This is the canonical pattern documented in
[logos-co/logos-docs#226](https://github.com/logos-co/logos-docs/pull/226)
(delivery journey) and
[logos-co/logos-docs#166](https://github.com/logos-co/logos-docs/pull/166)
(storage journey). Both journey docs show that exact call shape.

## What we observed

Across two basecamp pins (`pre-release-b44a5cf-260` and `0.1.2` / `tutorial-v2`)
the calls fail. Failure mode changes between pins but root cause is
the same:

### `pre-release-b44a5cf-260` (where we shipped v0.0.1)

- All modules load.
- `storage_module.init()` and `delivery_module.createNode()` calls
  appear to succeed (no error returned), but actual behaviour is
  flaky:
  - Sometimes `submitPhoto` lands a CID; sometimes it returns ok=true
    with no CID.
  - `deliveryReady()` reads `false` from core's perspective even
    though peers are connected.
  - Sometimes 20–60s blocking on the first call.
- No error logs from anywhere. Failures look like "occasionally
  doesn't work" rather than "broken".

### `0.1.2` / `tutorial-v2`

- All modules load.
- basecamp emits: `[warning] Failed to register token with capability
  module for: <module-name>` for every non-`main_ui` plugin.
- ~90ms after `logos_witness_core` loads:
  `[critical] Module process crashed: logos_witness_core`.
- Process stderr (caught by the launcher script, not basecamp log):
  `corrupted size vs. prev_size in fastbins` — glibc heap
  corruption.

Both modes are dogfood-blocking.

## Root cause (confirmed by upstream)

Documented in
[logos-co/logos-basecamp#150](https://github.com/logos-co/logos-basecamp/issues/150)
("Third-party core plugins have no token bootstrap path — cannot call
other modules via IPC"). The issue OP (xAlisher) traced the call into
the SDK:

- `LogosAPIClient::invokeRemoteMethod` auto-provisions module access
  by calling `capability_module.requestModule(origin, target)`.
- That call needs a pre-existing `capability_module` token in the
  process-wide `TokenManager`.
- **Third-party core plugins never receive this bootstrap token at
  load time** — only `main_ui` does.
- Result on pre-0.1.2: empty token hits a hard reject in
  `module_proxy.cpp`, caller gets invalid `QVariant` after 20s
  timeout, no error surfaced.
- Result on 0.1.2: the new token-check path that emits the "Failed to
  register token" warning also exposes a heap corruption when the
  auth handshake fails mid-call. We see this as the fastbins crash.

The typed-accessor wrapper (`m_logos->storage_module.X(...)`) is
just sugar over `invokeRemoteMethod` — switching from one to the
other doesn't help; both go through the same token-checked IPC.

## What we tried (chronological)

### 1. Untyped `LogosAPIClient::getClient(...)` + `invokeRemoteMethod`

Our original Phase 1 implementation. Picked it because it didn't need
`metadata.json.dependencies` declared (which had its own flake-input
chicken/egg — see [docs/dep-loading-investigation.md](./dep-loading-investigation.md)).
Got past build, never actually worked at runtime — submit failed,
pills stayed red, no error visible.

### 2. Declared `dependencies: ["logos_witness_core"]` + flake input

Followed the journey docs. Modules now load reliably (verified by
`logos_host_qt` processes spawning).
[docs/dep-loading-investigation.md](./dep-loading-investigation.md)
covers what `dependencies:` actually does on the basecamp side.

But: the modules being loaded ≠ being callable. The bootstrap-token
gap above is independent of `dependencies:` (which is purely a
load-order signal).

### 3. Switched to typed `m_logos->logos_witness_core.X(...)` accessor

Per the journey docs and `logos-delivery-demo` reference. No behaviour
change — same silent failure / crash pattern, because the typed
wrapper uses the same `invokeRemoteMethod` underneath.

### 4. Upgraded basecamp pin to `0.1.2` (= `tutorial-v2` = sha
`2576ef8f`)

Per dlipicar's suggestion in
[issue #150](https://github.com/logos-co/logos-basecamp/issues/150#issuecomment-…)
("could you retry with logos-module-builder@tutorial-v2?"). Failure
mode changed from silent-broken to hard-crash.

### 5. Forced module-builder version sync across all transitive flake
inputs

```nix
storage_module.inputs.logos-module-builder.follows = "logos-module-builder";
delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";
```

Most module-builder revs in the lock collapsed to `tutorial-v2`
(`b15a3724`), except for `logos-capability-module`'s own transitive
which remained on `b0e41abf`. Crash unchanged. Module-builder version
mismatch is **not** the root cause.

### 6. Reverted everything to `f9378cc`

Working tree back to the last commit. Same flaky behaviour as before
the deep dive — modules load, core calls partially work, no
fundamental fix available locally.

## Conclusion

Cross-module IPC from a third-party `core` plugin to upstream
modules is **not a supported path** in basecamp `pre-release-b44a5cf-260`
through `0.1.2`. The only sanctioned IPC route in the SDK is
`main_ui → Logos Module`, which is why the reference apps
(`logos-delivery-demo`, `logos-storage-ui`) — both `ui_qml`-only,
no `core` plugin of their own — work end-to-end.

Our architecture splits the work the wrong way: a `core` plugin
(`logos_witness_core`) does the storage + delivery I/O, and a
`ui_qml` plugin (`logos_witness_ui_qml`) drives it via QtRO. That
split fits the SPEC but doesn't fit the SDK's IPC story.

### v0.0.1 wasn't actually working — it was lucky

We shipped `v0.0.1` on 2026-05-15 and dogfood-confirmed
cross-instance reference broadcast at commit `92b6eac`. With
hindsight, **that "working" status was a fluke, not a green
build.** Re-examining the call shape: every cross-module call from
`logos_witness_core` was hitting the same bootstrap-token gap
described above; the call paths just happened to tolerate the
silent failure for our specific traffic pattern:

- `delivery_module.subscribe(topic)` — fire-and-forget side
  effect; we ignored the return value, and the actual subscribe
  side-effect happened anyway when the call reached the running
  delivery_module node.
- `delivery_module.send(payload)` — same shape; broadcasts went
  out, return value was unchecked.
- `storage_module.uploadUrl(...)` — sometimes landed (the request
  reached storage_module even when the auth handshake failed
  upstream), sometimes didn't. We attributed the misses to
  "network issues" or "still bootstrapping" because there was
  nothing visible in the log to say otherwise (see
  [#163](https://github.com/logos-co/logos-basecamp/issues/163)
  — stderr swallowed by the host).
- `storage_module.downloadToUrl(...)` — same flaky pattern.

The dogfood loop never exercised return-value-dependent calls in a
tight loop, so the flakiness lived in the long tail. As Phase 1
added more cross-module probes (`deliveryReady`, `storageReady`,
the 5s `_refreshFromCore` polling tick, `_subscribeToCoreEvents`),
the call rate climbed and the silent-failure rate became impossible
to miss.

The fact that v0.0.1 partially worked masked the underlying
architectural mismatch. **Pre-0.1.2 made failure invisible; 0.1.2
made it fatal.** We weren't degraded — we'd been broken since the
core→storage integration in Phase 5.2.

## Path forward

Two options, ranked. We're currently waiting on the first, with the
second queued as a fallback if upstream movement is slow.

### Option 1 — Wait for upstream fix on [#150](https://github.com/logos-co/logos-basecamp/issues/150) (preferred)

The OP proposed injecting a `capability_module` bootstrap token into
every loaded core plugin at load time (one-line fix in the plugin
loader). If/when this ships, our current architecture (core does
storage + delivery I/O; UI plugin drives it via QtRO) works without
code changes on our side.

Status: **OPEN as of 2026-05-25**, with our reproduction
[posted as a comment](https://github.com/logos-co/logos-basecamp/issues/150#issuecomment-4531834530)
disproving dlipicar's "incompatible module-builder versions"
hypothesis. Project is actively pushing upstream for movement on
this issue.

### Option 2 — Refactor storage + delivery into the UI plugin's C++ backend

Sidesteps #150 entirely by moving every cross-module IPC call into
`logos_witness_ui_qml_plugin`, which lives in `ui-host` (spawned by
`main_ui`'s process tree) and **does** receive the bootstrap token.

Concretely:

- `logos_witness_core` becomes data-layer only:
  - in-memory `InMemoryStore` of references
  - protobuf encode/decode (`reference_codec.cpp`)
  - geohash decode (`geohash.cpp`)
  - EXIF strip (`exif_strip.cpp`)
  - reference-batching state
  - **no `storage_client.cpp`, no `delivery_client.cpp`** — those
    move out
- `logos_witness_ui_qml_plugin`'s C++ side gains:
  - `m_logos->storage_module.*` calls — `init`, `start`, `uploadUrl`,
    `downloadToUrl`, `exists` (whatever core was doing in
    `storage_client.cpp`)
  - `m_logos->delivery_module.*` calls — `createNode`, `start`,
    `subscribe`, `send`, event handlers
  - the Q_INVOKABLE surface previously on core (`submitPhotoAsync`,
    `fetchPhotoAsync`, etc.) now does the work directly instead of
    delegating to core
  - core remains in the picture only for protobuf + geohash + EXIF
    + in-memory store (called via the existing typed accessor
    `m_logos->logos_witness_core.X(...)` which is pure-compute, no
    cross-module IPC inside)

Trade-offs:

- ~half a day of refactor across both modules.
- Spec ripple: the SPEC §1.3 "core module surface" contract still
  holds (decodeReference, decodeGeohash, listInscriptions,
  flushBatch — all pure-compute or in-memory). `submitPhoto`,
  `fetchPhoto`, `subscribeFeed`, `deliveryReady`, `storageReady`
  effectively move to the UI plugin's surface. Documentation pass
  needed.
- Net: smaller, focused core module; UI plugin owns all I/O. This
  is actually closer to the shape that
  [`logos-storage-ui`](https://github.com/logos-co/logos-storage-ui)
  uses (which our research subagent flagged as the canonical
  reference for this architecture).

If #150 doesn't show movement within a reasonable window (~2 weeks
from 2026-05-25), execute Option 2.

Pinned for now at `f9378cc` (working tree clean as of 2026-05-25
post-rollback). v0.0.2 release is blocked until one of these paths
lands.

## Cross-references

- [logos-co/logos-basecamp#150](https://github.com/logos-co/logos-basecamp/issues/150)
  — root cause, OPEN as of 2026-05-25.
- [logos-co/logos-basecamp#163](https://github.com/logos-co/logos-basecamp/issues/163)
  — stderr swallowing in `logos_host` child processes. CLOSED, fixed
  in 0.1.2. Relevant because the missing log channel is why we burned
  hours guessing in this session; a per-module log file would have
  surfaced the bootstrap-token failure immediately.
- [logos-co/logos-basecamp#176](https://github.com/logos-co/logos-basecamp/issues/176)
  — `SIGSEGV in QRemoteObjectNodePrivate::onClientRead` during sync
  `LogosAPIConsumer::requestObject`. Possibly related to the
  fastbins corruption we saw on 0.1.2; same component, same
  failure-mode shape.
- [logos-co/logos-basecamp#96](https://github.com/logos-co/logos-basecamp/issues/96)
  — different segfault (package_manager_ui click crash). Not the
  same root cause but lives next door.
- [docs/dep-loading-investigation.md](./dep-loading-investigation.md)
  — sibling investigation note on `metadata.json.dependencies`
  semantics. Different angle on the module-loading layer.
- [docs/photo-display-investigation.md](./photo-display-investigation.md)
  — the bytes-to-Image channel investigation. Independent of this
  issue.
