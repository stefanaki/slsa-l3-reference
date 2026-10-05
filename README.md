# SLSA Build L3 reference

A working example of [SLSA Build Level 3](https://slsa.dev/spec/v1.2/build-requirements) provenance with
[GitHub Artifact Attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations),
enforced at Kubernetes admission with Kyverno.

One repository plays the roles an organization would split up:

- **A build platform**: reusable workflows that build, scan, generate an SBOM and attest.
  [`platform-docker.yml`](.github/workflows/platform-docker.yml) builds container images with BuildKit,
  [`platform-go.yml`](.github/workflows/platform-go.yml) builds Go binaries.
- **Projects**: one caller workflow per app ([`release-orders-api.yml`](.github/workflows/release-orders-api.yml),
  [`release-inventory.yml`](.github/workflows/release-inventory.yml)) that picks *what* to build, never *how*.
  It pins the platform by commit SHA.
- **A verifier**: an [`ImageValidatingPolicy`](policy/verify-orders-api.yaml) on a homelab cluster that
  admits an image only if an **allowlisted platform commit** signed its provenance and SBOM, and it was
  built from a **release tag**. [`scripts/verify.sh`](scripts/verify.sh) runs the same checks with `gh`.

| App | Build type | Released as |
|---|---|---|
| [`orders-api`](apps/orders-api/) | .NET 10 minimal API, multi-stage Dockerfile | `ghcr.io/stefanaki/slsa-l3-reference/orders-api:X.Y.Z`, deployed on kabu |
| [`inventory`](apps/inventory/) | Go CLI, `go build` for 4 targets | binaries on the GitHub Release `apps/inventory/vX.Y.Z` |

## How it works

1. A PR runs each app's `test` job and the platform's PR-mode build. Both are required checks on `main`.
2. The owner tags a PR merge commit `apps/<app>/vX.Y.Z`. The caller calls the pinned platform.
3. The platform's `build` job runs the Dockerfile (no `id-token`). `scan` makes a CycloneDX SBOM and
   fails on fixable CRITICAL CVEs. Only `attest`, with fixed steps, can get an OIDC token and sign.
4. The certificate's identity is `…/platform-docker.yml@<platform-sha>`. GitHub resolves that SHA, so a
   project can't forge which platform version signed.
5. Kyverno pins the image to its digest and admits it only if the signer SHA is allowlisted and the
   source ref is a release tag.

[`docs/architecture.md`](docs/architecture.md) has the diagram and trust boundaries.

## Verify a release

Needs `gh` ≥ 2.102.0, `jq` and `docker buildx`:

```sh
scripts/verify.sh orders-api 1.0.0    # image provenance + SBOM, via the API and from GHCR
scripts/verify.sh inventory 1.0.0     # all 4 release binaries
scripts/verify.sh negatives f464254   # an unsigned and a self-attested image must be rejected
```

Offline policy tests, with Kyverno CLI 1.19:

```sh
kyverno test policy/tests
policy/tests/reasons.sh
```

## Releases

| Release | Commit / digest |
|---|---|
| `platform/v1.0.0` | `78c2b4251876144f5fc346f843c313efbaac745b` (the allowlisted signer) |
| `apps/orders-api/v1.0.0` | `orders-api:1.0.0@sha256:71a23e7ccda289f58b2835d0ed9ec898b7a5a56f4f7f5929d2eafee145c3432c` |
| `apps/orders-api/v1.0.1` | `orders-api:1.0.1@sha256:38f42fc22b4cb1a24caacd345923f4864655d4a03cb97bee74c48c11353ebb92` (running on kabu) |
| `apps/inventory/v1.0.0` | GitHub Release with 4 binaries, `checksums.txt`, `sbom.cdx.json` |

## Docs

| Doc | |
|---|---|
| [`architecture.md`](docs/architecture.md) | roles, trust boundaries, flow, known limits |
| [`slsa-l3-mapping.md`](docs/slsa-l3-mapping.md) | each SLSA Build requirement and where it's met |
| [`verification.md`](docs/verification.md) | reading a certificate, `gh` flags, the Kyverno checks |
| [`rulesets.md`](docs/rulesets.md) | branch and tag rulesets, repository settings |
| [`environments.md`](docs/environments.md) | adding `-dev` namespaces that admit `main` builds |
| [`prod-delta.md`](docs/prod-delta.md) | GHEC private repos, a separate platform repo, org rulesets |

[`SPEC.md`](SPEC.md) is the design this was built from.

## Why public

Artifact attestations work on public repositories on any plan. Private repositories need GitHub
Enterprise Cloud and a different trust root ([`prod-delta.md`](docs/prod-delta.md)). Public GHCR
packages also mean the cluster needs no pull secret.
