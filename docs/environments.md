# Environments

kabu runs one track: namespaces that admit **release builds only**, images built from
`refs/tags/apps/orders-api/v*`. This page describes how to add `-dev` namespaces that also admit builds
of `main`, next to the release-only ones. **None of this is deployed.** Snippets marked *not executed
in this repo* were never applied to kabu or run through `kyverno test`.

## What a `main` build looks like

A push to `main` that touches `apps/orders-api/**` runs the platform in `main` mode: same jobs, same
signer, tag `main-<shortsha>`. Its provenance differs from a release only in the source ref:

| Field | Release build | `main` build |
|---|---|---|
| SAN / `builder.id` | `…/platform-docker.yml@<approved-sha>` | same |
| `externalParameters.workflow.ref` | `refs/tags/apps/orders-api/vX.Y.Z` | `refs/heads/main` |
| Image tag | `X.Y.Z` | `main-<shortsha>` |

So a dev track needs **the same signer allowlist** and a wider source-ref check. Verify a `main` build
the same way as a release, with `--source-ref refs/heads/main`:

```sh
gh attestation verify oci://ghcr.io/stefanaki/slsa-l3-reference/orders-api@sha256:15b1ba2001f953788a3a06df4a11447489bf8306755adabd2f41ca282d67eaef \
  --repo stefanaki/slsa-l3-reference \
  --cert-identity https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@78c2b4251876144f5fc346f843c313efbaac745b \
  --signer-digest 78c2b4251876144f5fc346f843c313efbaac745b \
  --source-ref refs/heads/main \
  --deny-self-hosted-runners \
  --predicate-type https://slsa.dev/provenance/v1
```

Every commit on `main` came through a PR with the required checks, but only release tags are also
checked to be PR merge commits. A `main` build may come from any commit that reached `main`.

## Design: a namespace label selects the track

- Namespaces carry `slsa-l3-reference/track: dev` to opt into the dev track. A namespace **without** the
  label is release-only, so forgetting the label fails safe.
- The existing release policy skips `dev` namespaces. A second policy matches only them.
- Both policies share the attestors. Only the last validation differs.

Release policy, `namespaceSelector` gains one expression (*not executed in this repo*):

```yaml
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, flux-system, kyverno]
        - key: slsa-l3-reference/track
          operator: NotIn
          values: [dev]
```

Dev policy: a copy named `verify-orders-api-dev`, with the opposite selector and a wider ref check
(*not executed in this repo*):

```yaml
metadata:
  name: verify-orders-api-dev
spec:
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: slsa-l3-reference/track
          operator: In
          values: [dev]
  # attestors, attestations, variables and validations 1-4: unchanged from verify-orders-api
  validations:
    # …
    - expression: >-
        variables.repoImages.map(image, extractPayload(image, attestations.provenance).predicate.buildDefinition.externalParameters.workflow.ref
          .matches('^refs/(heads/main|tags/apps/orders-api/v.*)$')).all(e, e)
      message: "source: not built from main or an apps/orders-api/v* release tag"
```

A dev namespace (*not executed in this repo*):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: orders-api-dev
  labels:
    slsa-l3-reference/track: dev
    pod-security.kubernetes.io/enforce: restricted
```

Deploy a `main` build there by tag and digest, `orders-api:main-<shortsha>@sha256:…`, exactly as releases
are deployed today.

## Things to get right

- **Keep the allowlist in one place.** Two policies mean two copies of the attestors and the `approved`
  variable. A platform release must update both, or the dev track keeps trusting a revoked commit.
  Generate both from one source, or add a test that diffs their attestors.
- **The label is now a security boundary.** Anyone who can label a namespace can move it to the dev
  track. In a GitOps cluster that's a reviewed change to the namespace manifest. Also restrict `patch` on
  namespaces in RBAC, or reject label changes with a Kyverno `ValidatingPolicy`.
- **Both tracks must cover every namespace.** The selectors are complements: `NotIn [dev]` and `In [dev]`.
  Don't add a third label value without a policy for it.
- **Test the dev policy too.** Add a `policy/tests/dev` case: the `main` build image is admitted by the
  dev policy and rejected by the release policy with `source:`.
- **Per-app policies stay per app.** The ref check names the app (`apps/orders-api/v`). A second deployed
  app gets its own pair of policies, or one policy that derives the app from the image name.
- **Pull requests never produce deployable images.** The platform doesn't push or attest in PR mode, so
  "preview" environments for PRs aren't possible with this platform, by design.
