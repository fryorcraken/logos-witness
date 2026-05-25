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

## Path forward

Three options, in priority order:

1. **Wait for upstream fix on
   [#150](https://github.com/logos-co/logos-basecamp/issues/150).**
   The OP proposed injecting a `capability_module` bootstrap token
   into every loaded core plugin at load time (one-line fix in the
   plugin loader). If/when this ships, our current architecture
   works as-is.

2. **Move storage + delivery calls into the UI plugin's C++
   backend** (`logos_witness_ui_qml_plugin`), which runs alongside
   `main_ui` in the basecamp process and presumably has the
   bootstrap token. `logos_witness_core` becomes a thinner module
   (in-memory store + protobuf + geohash + reference-batching) with
   no cross-module IPC. The UI backend handles all storage/delivery
   I/O directly. Bigger refactor; sidesteps #150 entirely.

3. **Route storage + delivery calls through `logos.callModule(...)`
   from QML.** The OP's workaround: QML runs in `main_ui`'s
   process, which has all tokens. QML calls `logos.callModule(
   "storage_module", "uploadUrl", ...)` directly, bypassing our
   core. Our core becomes data-layer only. Largest refactor; most
   explicitly hacks around the SDK gap.

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
