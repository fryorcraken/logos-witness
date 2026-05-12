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
