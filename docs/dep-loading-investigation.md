# Module dep loading — upstream gap investigation

Living document. Track our evidence + open questions on how the upstream
expects sibling-module dependencies to get loaded at runtime in
basecamp, and where the documented happy-path falls short for hybrid
`ui_qml + C++ backend` modules.

## The hole we hit

Phase 1 of the logos-witness hybrid backend migration broke
modules-loading. Symptom: with `logos_witness_ui_qml`'s
`metadata.json.dependencies = []`, basecamp never spawns
`logos_witness_core`, `storage_module`, or `delivery_module`. The UI's
own backend (`logos_witness_ui_qml_plugin`, running in `ui-host`)
spins up fine, but its `getClient("logos_witness_core")` /
`invokeRemoteMethod(...)` calls all return invalid because no replica
exists.

User-visible:
- Both Delivery + Storage readiness pills stay red.
- Submit fails with "submitPhoto returned non-map" (the upstream call
  times out at 20 s).
- No clear error surfaced to either the user or the basecamp log
  (plugin-side `qWarning` doesn't reach the basecamp main log under
  our pinned `pre-release-b44a5cf-260`).

The breakage was introduced by commit `63dede2` which dropped
`dependencies: ["logos_witness_core"]` from `metadata.json` and the
matching `path:../logos-witness-core` flake input — both originally
declared in `f485dda` (the hybrid scaffold). The drop was triggered
by a CI failure: nix rejects `path:`-typed flake inputs without a
content hash. The `path:` form worked locally; the CI-friendly form
needs `github:...?rev=<sha>` and we hadn't worked out the
chicken-and-egg problem of self-referencing the monorepo.

## What the upstream journey docs say

[logos-co/logos-docs#226](https://github.com/logos-co/logos-docs/pull/226)
("Use the Logos Delivery module API from an app") — open as of
2026-05-25. Step 2 is the canonical pattern:

> Declare `delivery_module` as a dependency in `metadata.json`:
>
> ```json
> { "dependencies": ["delivery_module"], ... }
> ```
>
> In `flake.nix`, add a matching input:
>
> ```nix
> delivery_module.url = "github:logos-co/logos-delivery-module/v0.1.1";
> ```
>
> The flake input name must match the dependency name. The module
> builder automatically generates the typed `delivery_module` wrapper.

Same shape in
[logos-co/logos-docs#166](https://github.com/logos-co/logos-docs/pull/166)
for `storage_module`. Both PRs document the **declaration** thoroughly
but **do not specify who loads the dep at runtime**, or what happens
when the runtime host is `logos-basecamp` vs. `logos-standalone-app`.

## What basecamp actually does

Source (basecamp pin `b44a5cf4787f...`,
`src/MainUIBackend.cpp:178-192`):

```cpp
QJsonObject metadata = readPluginMetadata(moduleName);
QJsonArray dependencies = metadata.value("dependencies").toArray();
if (!dependencies.isEmpty() && m_logosAPI) {
    LogosModules logos(m_logosAPI);
    for (const QJsonValue& dep : dependencies) {
        QString depName = dep.toString();
        if (!depName.isEmpty()) {
            qDebug() << "Loading core module dependency for UI module"
                     << moduleName << ":" << depName;
            bool success = logos.core_manager.loadPlugin(depName);
            if (!success) {
                qWarning() << "Failed to load core module dependency"
                           << depName << "for UI module" << moduleName;
                return;
            }
        }
    }
}
```

So basecamp:

1. Reads the UI module's `metadata.json.dependencies` array.
2. For each entry, calls `core_manager.loadPlugin(depName)` from the
   basecamp process.
3. Returns early on the first failure, abandoning the UI load.

This happens in `MainUIBackend::loadUiModule`, which fires when a user
clicks the module in basecamp's launcher. It runs in basecamp's main
process (where `core_manager` IS reachable as a local QObject).

## Why we can't replicate it ourselves from inside ui-host

A consumer module (running in `logos_host_qt` or `ui-host`) tries to
call `core_manager.loadPlugin(...)` and **fails with a 20 s
transport timeout**. We hit exactly this in our Phase 5.2 first pass
(see PLAN.md):

> First pass (never committed cleanly) — drove `storage_module` via
> `core_manager.loadPlugin("storage_module")` + `LogosAPI::getClient` +
> `invokeRemoteMethod`. Failed silently at runtime: from a consumer
> module plugin, `core_manager` is not reachable as a remote replica,
> every `loadPlugin` call hit a 20 s transport timeout.

Log evidence at the time:
```
Timeout waiting for replica: core_manager
known plugins: QJsonArray()
```

In other words: `core_manager` is local to basecamp's process; it is
**not exposed over the QtRO mesh** that other modules talk through.
Consumers cannot drive it.

## The gap

Following the journey doc as written, our `logos_witness_ui_qml`
plugin should declare `dependencies: ["logos_witness_core"]` in
`metadata.json` + add a `logos_witness_core` flake input. When the
user launches the UI from basecamp, basecamp **will** call
`core_manager.loadPlugin("logos_witness_core")` — confirmed by
source.

What's not documented:

1. **How to add a sibling module from the same monorepo as a flake
   input.** The journey doc shows `github:logos-co/logos-delivery-module/v0.1.1`.
   For a module living in `logos-witness-core/` (a subdir of the
   same repo as the UI module), the analogous form is
   `github:fryorcraken/logos-witness?dir=logos-witness-core&rev=<sha>`
   — but the sha has to refer to a **pushed** revision, so you can't
   land a single commit that introduces the dep declaration AND
   matches its own sha. Two-push workaround exists; the doc should
   acknowledge it (or recommend a sibling-flake input form that
   doesn't need a sha).

   Local-dev `path:../module-name` works but is rejected by nix in
   stricter modes (CI), which is what bit us originally.

2. **What happens for runtime hosts other than basecamp**:
   `logos-standalone-app` (used by the tutorial's `nix run`) presumably
   has its own dep-loading logic; the journey doc doesn't say.
   `ui-host` (where our UI plugin's C++ backend actually runs) has no
   such logic — it just loads the plugin .so and calls `initLogos`.

3. **What a consumer module should do if a dep is declared but the
   host didn't load it.** Currently: silent failure. No diagnostic,
   no fallback. Our backend's `getClient("logos_witness_core")`
   returns a non-null `LogosAPIClient*` but every
   `invokeRemoteMethod` call times out and returns invalid. The
   consumer has no way to distinguish "host didn't load dep" from
   "dep is loaded but transiently down" from "dep crashed".

4. **Where the line is between `core_manager` access and
   `getClient(...)` access.** Sibling-module typed accessors
   (`m_logos->storage_module.upload(...)`) are documented as the
   intended interface, but it's unclear whether the *plugin* needs
   to do anything at startup to ensure the replica is acquired, or
   whether the host's pre-load is mandatory.

## Where we landed (workaround)

Manual `loadPlugin` from our UI backend's `initLogos`:

```cpp
// metadata.json.dependencies is empty (CI can't carry the deps
// declaration without a github:-pinned flake input, and the sha
// chicken/egg means we can't land that in a single commit).
// Drive the same load that basecamp would have done from
// metadata.json, by hand, before any RPC fires.
for (const QString& dep : { "storage_module",
                            "delivery_module",
                            "logos_witness_core" }) {
    if (!m_logos->core_manager.loadPlugin(dep)) {
        qWarning() << "loadPlugin failed:" << dep;
    }
}
```

**Caveat:** We may hit the 20 s `core_manager` timeout from inside
ui-host. If so, the workaround fails and we have to push back on the
upstream chicken/egg for monorepo-internal deps.

## What we'd want from upstream

Roughly priority order, smallest-fix to largest:

1. **Doc clarification in PR #226 / #166:** an explicit "How
   `dependencies` get loaded at runtime" subsection: who reads the
   array, in what process, with what failure mode.
2. **Monorepo-internal dep form documented.** Either a sanctioned
   `path:` syntax that survives nix-strict mode (content-hash
   pre-computed), or a worked example of the
   `github:org/repo?dir=...&rev=<sha>` two-push dance.
3. **Diagnostic on dep-load failure.** A `qCritical` from basecamp
   when `loadPlugin` returns false — currently it's `qWarning` and
   plugin-side warnings don't surface. Or a `LogosResult` with the
   underlying error.
4. **A pre-init handshake.** `LogosAPIClient::isConnected()` is
   visible but the typical consumer pattern is `getClient(...)` →
   `invokeRemoteMethod(...)` and discover failure by timeout. A
   `waitForDeps(timeoutMs)` on the SDK side (or a startup signal the
   plugin can wait on) would let consumers fail loudly instead of
   silently.

## Open empirical questions

### Can `ui-host` reach `core_manager`? — Answered: NO (2026-05-25)

Confirmed empirically. Built the workaround sketched above (a
`_loadCoreDeps()` slot in our UI plugin's backend that calls
`m_logos->core_manager.loadPlugin("storage_module")` etc. from inside
ui-host, marshalled onto the backend thread via
`BlockingQueuedConnection` from the initLogos worker). Outcome:

- Plugin .so built and loaded; ui-host process spawned normally.
- 47 s after `Logos Core started successfully`, no
  `logos_witness_core` / `storage_module` / `delivery_module`
  `logos_host_qt` processes existed. Only `capability_module`,
  `package_manager`, and our `ui-host` were running.
- Both Delivery + Storage readiness pills stayed red the whole time.
- `_loadCoreDeps()` was either silently failing OR each
  `loadPlugin(...)` call was waiting out the 20 s `core_manager`
  timeout (matches the Phase 5.2 evidence exactly).

Plugin-side `qInfo` / `qWarning` don't reach basecamp's log under
our pin, so we couldn't see *which* failure mode hit — but the
runtime evidence is unambiguous: from ui-host, we can NOT load
sibling modules ourselves.

**Implication:** There is no in-plugin workaround. The only path to
load `storage_module` + `delivery_module` + `logos_witness_core` is
via basecamp's `MainUIBackend::loadUiModule` reading
`metadata.json.dependencies`. Which means we MUST re-add those
deps, which means we MUST solve the flake-input chicken/egg for the
monorepo-internal `logos_witness_core` dependency.

### Does the build need the flake input or just the metadata.json entry?

Untested. Likely both: `logos-module-builder`'s codegen consumes
`flake.lock` to find each dep's `include/<name>_api.h` + `.cpp` and
copy them into the consumer's `generated_code/`. Without the flake
input, `LogosModules` won't have the typed wrapper member.

If we want to declare `dependencies: ["logos_witness_core"]` without
a matching flake input, we'd have to drop the typed-accessor
expectation and use untyped `LogosAPIClient::getClient(...)` calls —
which is what our current code already does. So we'd be declaring a
dep purely to get basecamp to call `loadPlugin`, ignoring the
codegen output. Worth testing whether `mkLogosQmlModule` allows that
shape or fails the build.
