# Implementation plan template

Copy this file to `docs/plans/<short-name>.md` when a plan is meant to be built, fill it in, and get it reviewed
before any code is written (plan, review, build). One plan is one thread's job: about one roadmap milestone, one
PR that can be reviewed in a sitting, and one coherent thing to try on the iPad. If the "Done when" list spans
unrelated features, split the plan into several that build on each other and link them from the roadmap.

The builder treats every line as a requirement and checks its work against "Done when", so write what you want
built, not what you might want. Delete the guidance in italics as you fill each section in.

---

# <Feature name> (milestone <n>)

How milestone <n> of the [2.5D roadmap](2.5d-roadmap.md) is built. Builds on <linked plans, if any>.

**Status:** draft | reviewed | building | shipped (update in the PR that ships it, per CLAUDE.md)

## Goal

_One or two sentences on what you can do on the iPad afterwards that you can't do now._

## Scope

**In:**

- _Each feature or change this plan delivers._

**Out:**

- _What it deliberately leaves alone, and where it goes instead (a later milestone, another plan, never). Name
  the tempting neighbours, since they are what a builder is most likely to add on its own._

## Steps

_Numbered so other steps can refer to them. Each step names the files or systems it touches and the steps it
needs finished first. Steps with no dependency between them can be built in parallel; keep the chain short
where you can. Logic goes in CharacterCore with tests; the app stays a thin layer (CLAUDE.md)._

| # | Step | Touches | Depends on |
| --- | --- | --- | --- |
| 1 | _What it does_ | `Packages/CharacterCore/Sources/CharacterCore/…` | none |
| 2 | _What it does_ | `Schema/character-0.3.schema.json`, `Schema/README.md`, `Schema/examples/…` | 1 |
| 3 | _What it does_ | `CharacterStudio/…` | 1 |
| 4 | _What it does_ | `CharacterStudio/…`, `README.md` | 2, 3 |

1. **<Step 1 name>.** _Detail: types and functions to add, behaviour, edge cases, the tests that cover it._
2. **<Step 2 name>.** _Detail. If it changes the file format: new keys optional, schema, Schema/README and
   example updated together, a migration if the version changes, and the example still re-saves byte for byte._
3. **<Step 3 name>.** _Detail._
4. **<Step 4 name>.** _Detail. Includes the README milestone notes when the change alters what the user sees._

## Done when

_Concrete, checkable statements. The PR is finished when every line is true, and the PR description reports each
one. Cover both kinds of check; cloud sessions can run only the first kind, so the second is yours on the iPad._

**Tests and CI:**

- [ ] _A named behaviour is covered by a test in `CharacterCoreTests` (e.g. "solving a two-bone chain to a
  reachable target puts the end within 0.01 pt of it")._
- [ ] `scripts/check.sh` passes: core tests, schema check, iPad Simulator build.
- [ ] `Schema/examples/robo.charstudio` still re-saves byte for byte.

**On the iPad:**

- [ ] _Something you do and what you should see (e.g. "drag the robot's hand target and the elbow bends
  outward, never backwards")._
- [ ] _A performance line if the feature runs every frame (e.g. "posing the stress drawing holds 120 Hz")._
- [ ] _Save, close and reopen keeps the new data._

## Open questions

_Each question comes with the default the builder uses if nobody answers, so an unanswered question never
blocks the build. Record the answer here when one arrives._

| Question | Default if unanswered | Answer |
| --- | --- | --- |
| _Something only you can decide_ | _What gets built meanwhile_ | |
