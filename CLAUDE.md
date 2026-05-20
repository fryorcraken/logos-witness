# Claude Code working instructions — logos-witness

## Branching and pushing

This repo's workflow is **direct-to-main**. Solo project, single contributor.

- Work happens on `main`. Do not create feature branches unless explicitly
  asked. Do not open PRs against your own commits.
- Commits push directly to `origin/main`. The auto-mode classifier
  conservatively blocks pushes to default branches; explicit authorization
  is implied by this file for routine work. The user will still gate any
  destructive push (force-push, history rewrite, push of >1 unreviewed
  commit).
- One logical change per commit, following the existing
  `type(scope): summary` style (`feat(ui)`, `fix(core)`, `spec(ui)`,
  `docs`, `ci`, etc.). Match recent `git log` shape.

## After every push: check CI

Pushing is not "done". CI is the gate.

After every `git push origin main`, before ending the turn:

1. Run `gh run watch` (or poll `gh run list --branch main --limit 1` until
   `status=completed`). Stream the result.
2. Report the outcome to the user: green → one-line confirm and the run
   URL; red → the failing step + first few lines of the failure, and
   propose a fix before they have to ask.
3. Do not claim success on the user-facing turn until CI is green or you
   have explicitly told the user "CI is red, here's why".

If you legitimately must end the turn before CI finishes (e.g. user
explicitly says "don't wait"), say so explicitly — don't leave the user
to discover a red main on their own.

## Scope: when this applies

- Routine code, spec, and docs commits on this repo.
- Does **not** override the existing safety rules in the global system
  prompt: destructive operations (force-push, `git reset --hard` on
  shared refs, branch deletes, hook bypasses) still require explicit
  per-action authorization.

## Never block the QML thread on `logos.callModule`

The basecamp `LogosQmlBridge` exposes only a **synchronous**
`callModule(module, method, args)` — every call blocks the QML thread
until the remote module replies. On a cold launch the remote module
may not yet have been spawned by basecamp, so the first call can
block for tens of seconds. Even on a warm system, storage downloads
and waku publishes routinely take a second or more.

Rule: **no `logos.callModule(...)` may run on the QML render path**,
i.e. never from `Component.onCompleted`, `onClicked`, property
bindings, or anywhere else that holds up paint.

Pattern (already in `Main.qml`): defer the blocking call onto a
single-shot `Timer { interval: 40 }`. The 40 ms is empirical —
`Qt.callLater` and a 0-interval Timer both fire before the next
paint flushes under basecamp's Qt6 build, defeating the point. Open
the dialog / paint the banner first, then `dispatcher.start()`.

If you find yourself adding a sync `callModule` to a startup or
click handler, **stop**, wrap it in a `Timer` dispatcher with a
clear `id`-style name (`uploadDispatcher`, `startupDispatcher`,
`fetchDispatcher` — match the existing ones), and add a comment
explaining what would freeze without it.

## Hand-off to a new agent

When the user opens a fresh session ("resume the work"), an agent should
self-orient in this order:

1. Read `SPEC.md` end-to-end — it's the authoritative contract.
2. Read `PLAN.md` "Status" block at the top — names the current phase,
   what's done, what's re-opened, and where to resume.
3. Skim recent `git log` to see what's already committed vs. only
   discussed.

The user does **not** review every commit. They lean on CI for
correctness gates and on PLAN.md status for "what's actually shipped vs.
on-disk prototype." Before asking for a review, surface anything in the
diff that is intentional throw-away code so the user doesn't waste time
reviewing it.

Throw-away signals to call out explicitly:

- A task marked "REWRITE" or "re-opened" in PLAN.md — the on-disk code
  is a baseline the next pass replaces; review it only for survivors
  (helper functions, tests, config) that the rewrite reuses.
- A commit message that explicitly flags "next agent rewrites this"
  (e.g. commit e0a806b for Phase 3.5).

When in doubt, list the commits since the user's last touchpoint and
flag which ones are review-worthy vs. discardable scaffolding.
