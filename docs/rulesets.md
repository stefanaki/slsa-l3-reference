# Rulesets and repository settings

Rulesets are the supporting controls around the build platform (SPEC §8.2). Admission doesn't
depend on them: it checks the signer SHA and the source ref in the attestation. What they guarantee
is that what reaches `main` was tested (SPEC §2 rule 7), and that only the owner can cut a release
tag that admission will accept.

The exact bodies live in [`rulesets/`](rulesets/). They're written as GitHub returns them, so
GitHub's server-side defaults are spelled out too.

| File | Target | Bypass |
|---|---|---|
| [`main.json`](rulesets/main.json) | `refs/heads/main` | nobody |
| [`tags-apps.json`](rulesets/tags-apps.json) | `refs/tags/apps/*/v*` | repository admin, `always` |
| [`tags-platform.json`](rulesets/tags-platform.json) | `refs/tags/platform/v*` | repository admin, `always` |

## `main`

| Rule | Setting | Why |
|---|---|---|
| `pull_request` | 0 approvals, `allowed_merge_methods: [merge, squash]` | Every change goes through a PR. The merge or squash commit it creates has exactly the tree the checks ran on. Rebase merging is off: it would put each rebased, untested commit directly on `main`. |
| `required_status_checks` | `strict_required_status_checks_policy: true` | The PR branch must be up to date with `main`, so the checks ran on the merged tree. |
| `deletion`, `non_fast_forward` | on | Nobody rewrites or deletes `main`. |

The required checks are pinned to the GitHub Actions app (`integration_id: 15368`):

| Check | Produced by |
|---|---|
| `test (orders-api)` | `release-orders-api.yml` job `test` |
| `test (inventory)` | `release-inventory.yml` job `test` |
| `release (orders-api) / build` | `platform-docker.yml` job `build`, PR mode |
| `release (inventory) / build` | `platform-go.yml` job `build`, PR mode |

- **Check names must be unique across workflows.** Rulesets match checks by name, so each caller
  job carries the app name. Two jobs both called `test` would let one app's passing tests satisfy
  the other's required check.
- **The `integration_id` pin.** Without it, anyone with write access could satisfy a check by
  posting a commit status with the same name through the API. The pin only proves the check came
  from GitHub Actions, not what it ran: a PR runs its own version of the caller workflow, so it
  could turn its `test` job into a no-op and still go green. Reviewing changes to
  `.github/workflows/release-*.yml` is what closes that gap (see below).
- **No `paths` filter on `pull_request`.** A workflow skipped by a `paths` filter never reports, and
  its required check blocks the PR forever. So every PR runs every app's checks.
- **Never skip a required job on PRs.** A job skipped by `if:` reports success. Today the `test`
  jobs run only on `pull_request`, and the platform `build` job always runs.
- **Fork PRs fail the orders-api checks.** Fork PRs get no secrets, and the Dockerfile requires
  `nuget_token`. Fork PR runs also wait for the owner's approval (`all_external_contributors`).
- **Strict mode applies to every PR.** Each PR, including Renovate's, has to be updated with `main`
  before it can merge.
- **Copilot-authored PRs.** GitHub fills in `require_extra_approval_for_unattributed_changes: true`
  (preview). It adds one required approval to PRs that Copilot opens under its own identity. It has
  no effect while the ruleset requires 0 approvals.

### Release commits and merge commits

Merge commits bring a PR's own intermediate commits into `main`'s history, and those were never
tested. So the platform's release check doesn't stop at "is the tagged commit on `main`". It also
requires the commit to be the `merge_commit_sha` of a PR merged into `main` (SPEC §2 rule 7):

- PR #5 has commits A (tests broken) and B (fixed). Checks ran on B, and the merge creates M.
- Tagging M releases. Tagging A or B fails, even though both are "on `main`".
- The commits pushed directly before the ruleset existed aren't PR merges, so they can't be released.

### Maintaining the platform with one maintainer

- **Platform changes use the same flow as any change.** You open a PR, the required checks pass, and
  you merge. Nobody bypasses `main`, not even the owner, but with 0 required approvals the owner can
  merge their own PR. Bypass mode `pull_request` would let the owner merge with failing checks, so
  it isn't used.
- **Merging a platform change makes nothing trusted.** Admission only trusts a platform commit after
  the owner tags it `platform/vX.Y.Z` and adds its SHA to the Kyverno allowlist in `stefanaki/lab`
  (SPEC §8.3). Callers use it only after the Renovate bump PR is merged. In this repo, that
  allowlist is the platform's real gate.
- **CODEOWNERS is documentation here.** `.github/CODEOWNERS` names the platform's owner, but
  `require_code_owner_review` is off. GitHub doesn't let a PR author approve their own PR, so turning
  it on would lock the only maintainer out.
- **In a real org:** keep the platform in its own repository that only the platform team can write
  to (see `prod-delta.md`). In a shared repo, turn on `require_code_owner_review` with at least one
  approval, and make the platform team code owners of `.github/workflows/platform-*.yml`,
  `.github/workflows/release-*.yml`, `.github/CODEOWNERS` and `.github/renovate.json`. Then a project
  team can't change how artifacts are built, or weaken its own required checks, without a second
  person's review.
- **An admin can still edit or disable a ruleset.** Every change is recorded in the ruleset history
  (`GET /repos/{owner}/{repo}/rulesets/{id}/history`).

## Release tags

`apps/*/v*` and `platform/v*` restrict `creation`, `update`, `deletion` and `non_fast_forward`.
Only the repository admin role (`actor_id: 5`) bypasses them, in `always` mode, which logs each
bypass. `*` doesn't match `/`, so `apps/*/v*` covers `apps/orders-api/v1.0.0` but not deeper paths.

- **`apps/*/v*` matters for admission.** The Kyverno policy only admits images built from
  `refs/tags/apps/<app>/v*`, so this ruleset decides who can cut a release that admission accepts.
- **`platform/v*` is good practice.** Admission doesn't rely on it, because the allowlist pins the
  platform commit SHA, not the tag.
- **Workflows never create tags.** The platform's release job publishes a GitHub Release for an
  existing tag, so these rules don't get in its way.

### Showing the tag rules work with one account

The owner is the only account, and the owner is on the bypass list, so a rejected push can't be
shown. Instead, push a throwaway tag that no workflow triggers on, and check that the rule matched:

```sh
git tag apps/zz/v0.0.0 main && git push origin apps/zz/v0.0.0
# remote: Bypassed rule violations for refs/tags/apps/zz/v0.0.0:
# remote: - Cannot create ref due to creations being restricted.
git push origin :refs/tags/apps/zz/v0.0.0 && git tag -d apps/zz/v0.0.0
# remote: - Cannot delete this tag
gh api 'repos/stefanaki/slsa-l3-reference/rulesets/rule-suites?time_period=month' \
  --jq '.[] | select(.ref=="refs/tags/apps/zz/v0.0.0") | .result'   # bypass, bypass
```

## Repository settings (not rulesets)

| Setting | Value |
|---|---|
| Merge methods | merge commit and squash (rebase merging off), commit title = PR title, delete branch on merge |
| Default `GITHUB_TOKEN` permissions | read; Actions can't create or approve PRs |
| Actions | must be pinned to a full commit SHA (`sha_pinning_required`) |
| Fork PR workflows | approval required for all external contributors |
| Releases | immutable: published assets and their tag can't change |

## Applying

```sh
for f in main tags-apps tags-platform; do
  gh api -X POST repos/stefanaki/slsa-l3-reference/rulesets --input docs/rulesets/$f.json
done
```

To change a ruleset, edit its file and `PUT` it to `repos/stefanaki/slsa-l3-reference/rulesets/<id>`.
