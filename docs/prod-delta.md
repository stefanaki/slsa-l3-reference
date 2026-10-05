# Production delta

This repository is a public, single-owner stand-in for an organization on **GitHub Enterprise Cloud**
with private repositories and services on Kubernetes. This page lists what changes in that setting.
The policy logic stays the same everywhere: an approved platform commit signed it, and it was built
from a release ref of the right repository.

**Nothing on this page was deployed.** Snippets marked *not executed in this repo* were never applied
or run here. The two `gh attestation trusted-root` commands were run.

## Private repositories: GitHub's Sigstore instance

Artifact attestations for private or internal repositories
[need GitHub Enterprise Cloud](https://github.com/github/docs/blob/main/data/reusables/gated-features/attestations.md).
They're signed by [GitHub's own Sigstore instance](https://docs.github.com/en/actions/concepts/security/artifact-attestations),
not public-good Sigstore:

| | Public repo (this one) | Private repo (GHEC) |
|---|---|---|
| Certificate authority | `fulcio.sigstore.dev` | `fulcio.githubapp.com` |
| Transparency log | public Rekor | none |
| Signing time proven by | Rekor entry | RFC 3161 timestamp from `timestamp.githubapp.com` |
| Trust root distributed by | `tuf-repo-cdn.sigstore.dev` | GitHub's TUF repository, `https://tuf-repo.github.com` |

`gh` fetches both trust roots. One line of its output is GitHub's instance, with no transparency logs
and no CT logs:

```sh
gh attestation trusted-root | jq -c '{tlogs: (.tlogs|length), cas: [.certificateAuthorities[].uri], tsas: [(.timestampAuthorities // [])[].uri]}'
# {"tlogs":2,"cas":["https://fulcio.sigstore.dev",…],"tsas":["https://timestamp.sigstore.dev/api/v1/timestamp"]}
# {"tlogs":0,"cas":["fulcio.githubapp.com",…],"tsas":["timestamp.githubapp.com",…]}
gh attestation trusted-root | jq -c 'select(.certificateAuthorities[0].uri == "fulcio.githubapp.com")' > trusted_root.json
```

### `gh attestation verify`

Unchanged: gh fetches GitHub's trust root itself, and the strict flags stay the same. For air-gapped
verification, pass the file from above with `--custom-trusted-root`.

### Kyverno

Kyverno 1.19 documents `spec.attestors[].cosign.trustedRoot` for providers such as GitHub Actions: it takes
the trust root directly instead of fetching it from a TUF repository. Use it, and skip the transparency-log and
SCT checks, which GitHub's instance doesn't have. Following the
[Kyverno `ImageValidatingPolicy` docs](https://kyverno.io/docs/policy-types/image-validating-policy/)
(*not executed in this repo*):

```yaml
spec:
  variables:
    - name: githubTrustedRoot
      expression: >-
        resource.get("v1", "configmaps", "kyverno", "github-trusted-root").data["trusted_root.json"]
  attestors:
    - name: platformV1_0_0
      cosign:
        keyless:
          identities:
            - issuer: https://token.actions.githubusercontent.com
              subject: https://github.com/<org>/build-platform/.github/workflows/platform-docker.yml@<approved-sha>
        trustedRoot:
          expression: variables.githubTrustedRoot
        ctlog:
          insecureIgnoreTlog: true
          insecureIgnoreSCT: true
```

```sh
kubectl -n kyverno create configmap github-trusted-root --from-file=trusted_root.json   # not executed in this repo
```

- `trustedRoot` sits under `cosign`, next to `keyless`, not inside it. It takes precedence over `tuf`.
- The same three fields go on every attestor, including the "any workflow" one.
- **GitHub rotates this trust root.** A trust root copied into a ConfigMap goes stale, and verification
  then fails closed. Refresh it on a schedule (for example, a job that runs `gh attestation trusted-root`
  and opens a PR), and alert on admission failures.
- Only the trust material changes. The attestor subjects, the allowlist and the source checks stay as
  they are, because GitHub's instance issues certificates with the same SAN format and extensions.
- If the enterprise customizes its OIDC issuer (for example, adding the enterprise slug), the `issuer`
  changes too. Read it from a real certificate first.

## Separate platform repository

Here the platform and the projects share a repository, so `--repo` and the policy's
`workflow.repository` check cover both. In an org, the platform lives in its own repository (say
`<org>/build-platform`) that only the platform team can write to:

- **The signer is now another repository.** The SAN becomes
  `https://github.com/<org>/build-platform/.github/workflows/platform-docker.yml@<sha>`. `--cert-identity`
  and the Kyverno attestor subjects already pin the signer repository, because they match the whole SAN.
  If you ever relax them to a pattern, add `--signer-repo <org>/build-platform` to gh.
- **The source check is per app.** `--repo` and `workflow.repository` name the *app's* repository,
  e.g. `https://github.com/<org>/orders-api`, and the ref check becomes that repo's release tags
  (`refs/tags/v*`), since it no longer needs the `apps/<app>/` prefix.
- **Keep the SHA pins and the allowlist.** A separate repo protects who can *change* the platform. The
  allowlist still decides which of its commits are *trusted*, and the callers' SHA pins keep a moved tag
  from switching platforms silently.
- **Private platform repo:** allow its workflows to be used by other repositories in the organization
  (the repository's Actions settings, "Access").
- **The release check needs `pull-requests: read`** on private repos (`GET /commits/{sha}/pulls`). The
  callers already grant it.

## Org rulesets and required workflows

What [`rulesets.md`](rulesets.md) sets per repository moves to organization rulesets:

- **`main` on every app repo:** PR required, merge and squash only, required status checks with branches
  up to date, no force pushes or deletion. With more than one maintainer, require at least one approval
  and code-owner review.
- **Required workflows.** Instead of trusting each repo's own `test` job (a PR can edit its own caller
  workflow), run the test workflow from a central repository through an org ruleset's "require workflows
  to pass" rule. Then a project team can't weaken its own checks.
- **Release tags:** restrict creation, update and deletion of `v*` tags to the release team, not the
  admin role.
- **Org-wide Actions policy:** SHA pinning required, read-only default `GITHUB_TOKEN`, Actions can't
  approve PRs, immutable releases.
- **CODEOWNERS on the caller workflows.** The platform team should own each repo's
  `.github/workflows/release-*.yml`, so a project can't swap the platform `uses:` line unreviewed.

## Private GHCR: pull secrets

Here GHCR packages are public, so neither the kubelet nor Kyverno needs credentials. With private
packages both do, separately (*not executed in this repo*):

- **The kubelet** pulls the image: an `imagePullSecrets` entry on the workload's ServiceAccount, in the
  app namespace.
- **Kyverno** fetches the image manifest and the attestation bundles at the `sha256-<digest>` tag: a
  `kubernetes.io/dockerconfigjson` secret **in the `kyverno` namespace**, referenced from the policy:

  ```yaml
  spec:
    credentials:
      secrets: [ghcr-read]
  ```

Use a read-only credential (`read:packages`), ideally a GitHub App installation token refreshed by a
controller rather than a long-lived PAT.

## Automating the allowlist PR

Here the owner copies the attestor from the `platform-release.yml` summary into `stefanaki/lab` by hand,
because automating it would store a token for a private repo in a public one. In an org (*not executed
in this repo*):

1. A GitHub App installed only on the GitOps repo, with `contents: write` and `pull-requests: write`.
2. Its private key stored as an **environment** secret in the platform repo, in an environment that only
   `platform/v*` tags can deploy to, with a required reviewer.
3. `platform-release.yml` gets an installation token (`actions/create-github-app-token`), renders the
   policy with the new attestor, and opens a PR on the GitOps repo. The PR still needs a human merge:
   that merge is the act of trusting a platform version.
4. Run `kyverno test` on the rendered policy in that PR's checks.

Do the same for the per-app digest bumps in the deployment manifests, or let Renovate track
`tag@digest` there. Renovate was left out of the lab here on purpose.

## Other differences

- **Services in other ecosystems.** The Docker platform knows no ecosystem. A .NET service with a
  private NuGet feed passes the feed's read-only token in `build-secrets`, exactly as orders-api does.
  Point `packageSourceMapping` at the real internal feed for the internal package prefixes.
- **Multi-arch SBOMs.** If the attested SBOM must cover every platform, generate one per platform
  (Trivy scans one platform per run) and attest each for the index digest, which is what admission
  verifies.
- **Kubernetes version.** Run Kyverno on a Kubernetes version inside its tested range. kabu runs 1.19.1
  on v1.36, outside the range.
