# SPEC: SLSA Build L3 Reference (GitHub Artifact Attestations)

Status: **agreed design, not yet implemented**
Owner: @stefanaki
Repo: `github.com/stefanaki/slsa-l3-reference` (**public**; local checkout: `~/dev/artifact-attestation`)
Deploy target: homelab cluster **kabu**, GitOps repo `stefanaki/lab` (private), branch `kabu`

---

## 1. Goal

A single public repo that demonstrates **SLSA v1.0 Build Level 3** provenance with GitHub Artifact Attestations, close to a real production setup:

- An **org-level build platform** (reusable workflows) that builds, scans, generates SBOMs and attests.
- **Project-level callers** (one per app) that only choose *what* to build, never *how*.
- Two build types: **Dockerfile image via BuildKit** (.NET) and **Go binaries** (`go build`).
- **Kubernetes admission enforcement** with Kyverno on the kabu cluster. Only images built by an *approved commit* of the platform, from a *release tag*, are admitted.

### Non-goals
- Private-repo / GHEC trust root in practice. It's documented in `docs/prod-delta.md` only.
- Deploying the Go app. It ships as attested release binaries only.
- Dev/prod namespaces per app. A doc describes how to extend to them.
- Hardened-runner egress tooling (e.g. harden-runner).
- Sigstore policy-controller. Kyverno is the only admission engine.

### Why public
Artifact attestations on **private** repos need GitHub Enterprise Cloud; on public repos they work on any plan. Public repos sign through **public-good Sigstore** (Fulcio plus the public Rekor log). Public GHCR packages also mean kabu needs no pull secret.

---

## 2. Trust model (single repo simulating org and project)

| Role | Lives in | Controls |
|---|---|---|
| **Build platform** ("org") | `.github/workflows/platform-*.yml` | *How* artifacts are built, scanned, attested |
| **Projects** | `.github/workflows/release-<app>.yml`, `apps/<app>/` | *What* is built: source, Dockerfile, build args |
| **Verifier** | Kyverno policy in `stefanaki/lab` | Which signer commits and source refs are acceptable |

Key rules:

1. **Callers pin the platform by commit SHA** (fully qualified ref to this repo, never `./`):
   ```yaml
   uses: stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@<40-hex-sha> # platform/v1.2.0
   ```
   `platform/vX.Y.Z` tags are human-readable release labels. Renovate bumps the SHA and the comment.
2. **Signer identity = the platform workflow at that SHA.** The Sigstore certificate SAN is
   `https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@<sha>`.
   GitHub resolves the SHA, so the build can't forge it.
3. **Admission accepts only signer SHAs on an explicit allowlist** (the "signer digest allowlist"). A random branch commit, a moved tag or an unreleased platform version is rejected.
4. **Admission accepts only images built from release tags** `refs/tags/apps/<app>/v*` of this repo.
5. **Admitted pods always run by digest** (`tag@sha256:…` in manifests, plus Kyverno `mutateDigest` and `verifyDigest`).
6. Untrusted, repo-defined build commands (Dockerfile `RUN`, `go test`, `dotnet test`) **never run in a job that has `id-token: write`.** Signing happens only in a separate `attest` job with fixed steps.

---

## 3. Repository layout

```
slsa-l3-reference/
├── SPEC.md
├── README.md                            # what this is, quickstart, links to docs
├── .github/
│   ├── CODEOWNERS                       # .github/workflows/platform-*.yml → @stefanaki
│   ├── renovate.json
│   └── workflows/
│       ├── platform-docker.yml          # reusable: Dockerfile/BuildKit image build platform
│       ├── platform-go.yml              # reusable: Go binary build platform
│       ├── platform-release.yml         # on platform/v* tag: emits allowlist entry (see §8.3)
│       ├── release-orders-api.yml       # caller (project)
│       ├── release-inventory.yml        # caller (project)
│       └── negative-test.yml            # workflow_dispatch: produces images that MUST be rejected
├── apps/
│   ├── orders-api/                      # .NET 10 ASP.NET Core minimal API
│   │   ├── Dockerfile
│   │   ├── nuget.config
│   │   ├── src/OrdersApi/…
│   │   └── tests/OrdersApi.Tests/…
│   └── inventory/                       # Go CLI
│       ├── go.mod / go.sum
│       ├── main.go
│       └── *_test.go
├── policy/
│   ├── verify-orders-api.yaml           # source of truth for the Kyverno policy (deployed copy lives in stefanaki/lab)
│   └── tests/                           # `kyverno test` suite, incl. allowlist-negative case
├── scripts/
│   └── verify.sh                        # strict `gh attestation verify` examples (image + blobs)
└── docs/
    ├── architecture.md                  # trust boundaries, flow diagram
    ├── slsa-l3-mapping.md               # each SLSA Build L3 requirement → where it's met
    ├── verification.md                  # gh CLI + Kyverno, how to read a cert/attestation
    ├── rulesets.md                      # rulesets/settings to configure by hand
    ├── environments.md                  # extending to dev/prod namespaces with per-ref rules
    └── prod-delta.md                    # GHEC private repos, GitHub Sigstore instance, separate platform repo
```

---

## 4. Applications

### 4.1 `orders-api` (.NET, Dockerfile build type)
- .NET 10 (LTS), ASP.NET Core minimal API. Endpoints: `GET /healthz`, `GET /orders` (in-memory sample data), `GET /version` (build version).
- Listens on port **8080** as non-root.
- xUnit test project.
- **Multi-stage Dockerfile:**
  - `build`: `mcr.microsoft.com/dotnet/sdk:10.0@sha256:…`; restore, then build.
    - Restore uses `RUN --mount=type=secret,id=nuget_token`. The token never lands in a layer, the cache or the provenance.
  - `test`: `dotnet test`. The platform builds this target first.
  - `publish`: `dotnet publish -c Release`.
  - `runtime`: `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled@sha256:…`.
- **Simulated private feed:** `nuget.config` adds the owner's GitHub Packages NuGet feed (`https://nuget.pkg.github.com/stefanaki/index.json`) next to nuget.org. It's authenticated by the `nuget-token` secret, so the secret-mount path is exercised for real. The feed hosts no packages.
  - Local restores need `NUGET_TOKEN=$(gh auth token)`. Documented in `apps/orders-api/README.md`.
- All base images are pinned by digest (Renovate keeps them current).

### 4.2 `inventory` (Go, binary build type)
- A small CLI (e.g. `inventory list`, `inventory version`) with one or two real module dependencies, so the SBOM has content.
- Unit tests via `go test`.
- **Never deployed.** Released as binaries only.

---

## 5. Build platform: `platform-docker.yml`

`on: workflow_call` only. Runs on GitHub-hosted `ubuntu-24.04`. All actions are pinned by SHA.

### 5.1 Contract

| Input | Type | Default | Validation |
|---|---|---|---|
| `app` | string | required | `^[a-z0-9-]+$` |
| `context` | string | `apps/<app>` | must be under `apps/` |
| `dockerfile` | string | `<context>/Dockerfile` | must be under `context` |
| `test-target` | string | `test` | Dockerfile stage name |
| `build-args` | string | `""` | newline-separated `KEY=VALUE`, **non-secret only** |
| `platforms` | string | `linux/amd64,linux/arm64` | |

| Secret | Use |
|---|---|
| `nuget-token` | passed only as a BuildKit secret mount (`id=nuget_token`) |

| Output | |
|---|---|
| `image` | `ghcr.io/stefanaki/slsa-l3-reference/<app>` |
| `digest` | index digest (`sha256:…`) |

- The registry and owner are **fixed by the platform**. Callers can't choose where images go.
- Push and attest behaviour is **derived from `github.event_name` and `github.ref`, not from inputs.** A caller can't turn on attestation for a PR.

| Trigger (in caller) | Test | Push | Image tag | Attest |
|---|---|---|---|---|
| `pull_request` | ✅ | ❌ | – | ❌ |
| push to `main` | ✅ | ✅ | `main-<shortsha>` | ✅ |
| push tag `apps/<app>/vX.Y.Z` | ✅ | ✅ | `X.Y.Z` | ✅ |

### 5.2 Jobs

1. **`build`**: `contents: read`, `packages: write` (`packages: read` for the NuGet feed). **No `id-token`.**
   - Set up buildx (BuildKit, `docker-container` driver).
   - Build `--target <test-target>`; it fails the job on test failure.
   - Build and push the final stage:
     - `provenance: mode=max`, `sbom: true`. These are BuildKit's own unsigned records; the index digest covers them.
     - `SOURCE_DATE_EPOCH` = commit timestamp, and output `rewrite-timestamp=true`.
     - **Cache:** `type=gha`, scoped per app, for `main` and PRs. **No cache on release tags.**
   - Output: index digest.
2. **`scan`**: `contents: read`, `packages: read`. No `id-token`.
   - Trivy (pinned version) against `ghcr.io/…/<app>@<digest>`, reusing the registry login.
   - Generate a **CycloneDX** SBOM → `sbom.cdx.json` (artifact upload).
   - **CVE gate:** `--severity CRITICAL --ignore-unfixed --exit-code 1`.
   - A failed gate means the image is pushed but **never attested**, so admission rejects it. This is intended and documented.
3. **`attest`** (`needs: [build, scan]`): `id-token: write`, `attestations: write`, `packages: write`, `contents: read`.
   - **Fixed steps only.** No checkout of app code, no repo-defined commands.
   - `actions/attest-build-provenance`: subject = image + digest, `push-to-registry: true`.
   - `actions/attest-sbom`: same subject, `sbom-path: sbom.cdx.json`, `push-to-registry: true`.
   - Job summary prints the image digest and a ready-to-run `gh attestation verify` command.

---

## 6. Build platform: `platform-go.yml`

`on: workflow_call`, `ubuntu-24.04`, actions pinned by SHA.

### 6.1 Contract

| Input | Type | Default | Validation |
|---|---|---|---|
| `app` | string | required | `^[a-z0-9-]+$` |
| `path` | string | `apps/<app>` | must be under `apps/` |
| `targets` | string | `linux/amd64,linux/arm64,darwin/amd64,darwin/arm64` | `os/arch` list |

Same event matrix as §5.1: PRs only test, `main` attests and uploads workflow artifacts, `apps/<app>/vX.Y.Z` tags attest and publish a GitHub Release.

### 6.2 Jobs

1. **`build`**: `contents: read`.
   - `go test ./...`.
   - Build each target with:
     - `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -buildid= -X main.version=<version>"`
     - `SOURCE_DATE_EPOCH` = commit timestamp.
   - Output `<app>_<os>_<arch>` binaries plus `checksums.txt` (artifact upload).
2. **`scan`**: `trivy rootfs` over the binaries → CycloneDX `sbom.cdx.json`, plus the same CRITICAL CVE gate.
3. **`attest`**: `id-token: write`, `attestations: write`, `contents: read`. Fixed steps only.
   - `attest-build-provenance` with `subject-path` over all binaries: one attestation, many subjects.
   - `attest-sbom` over the same subjects.
4. **`release`** (tags only): `contents: write`. **No `id-token`.**
   - Create or update the GitHub Release for `apps/<app>/vX.Y.Z`.
   - Upload the binaries, `checksums.txt` and `sbom.cdx.json`.

---

## 7. Project callers

`release-orders-api.yml`:
```yaml
on:
  pull_request:
    paths: ["apps/orders-api/**"]
  push:
    branches: [main]
    paths: ["apps/orders-api/**"]
    tags: ["apps/orders-api/v*"]
jobs:
  release:
    permissions: { contents: read, packages: write, id-token: write, attestations: write }
    uses: stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@<sha> # platform/vX.Y.Z
    with:
      app: orders-api
      build-args: |
        DOTNET_CONFIGURATION=Release
    secrets:
      nuget-token: ${{ secrets.GITHUB_TOKEN }}
```
`release-inventory.yml` follows the same shape against `platform-go.yml` (adds `contents: write` for the release job).

The caller grants the *maximum* permissions. The platform narrows them per job (§5.2, §6.2).

### 7.1 `negative-test.yml` (`workflow_dispatch`)
Produces images that **must be rejected** by Kyverno. They're pushed as `ghcr.io/stefanaki/slsa-l3-reference/orders-api:negative-<case>-<shortsha>`:

| Case | How it's produced | Expected rejection reason |
|---|---|---|
| `unsigned` | build and push, no attestation | no attestation |
| `self-attested` | the caller builds **and** attests itself (no platform) | signer is `negative-test.yml`, not the platform |


An "unapproved platform commit" case is **not** produced on GitHub:
- A dispatched run wouldn't attest.
- If it did, it would also fail the source-ref check, so it wouldn't isolate the allowlist.

Instead, the allowlist is proven in the Kyverno test suite (`policy/tests`). The policy runs with an allowlist that **omits** the real platform SHA, and the genuine v1.0.0 release image must then be rejected for the signer reason.

---

## 8. Supply-chain hygiene

### 8.1 Renovate (`.github/renovate.json`)
Renovate GitHub App on this public repo.
- `github-actions`: pin all actions by digest, plus bump the **platform self-references** (`stefanaki/slsa-l3-reference/...@<sha> # platform/vX.Y.Z`) when a new `platform/v*` tag appears.
- `dockerfile`: digest-pinned `FROM`s.
- `nuget` (lookups restricted to nuget.org via `registryUrls`; the simulated private feed has no packages and no Renovate credentials), `gomod`.
- Group the platform bump separately so it's reviewed on its own.

### 8.2 Rulesets and settings (documented in `docs/rulesets.md`; configured by hand)
1. **`main`:** require a PR with **0 required approvals**, require status checks (platform PR-mode runs), block force pushes and deletion.
   - CODEOWNERS documents platform ownership but isn't enforced: a solo maintainer can't approve their own PR.
   - `rulesets.md` explains that a real org requires CODEOWNERS review by a second person.
2. **`apps/*/v*` tags:** restrict creation, update and deletion to the owner. This controls who can cut a release that admission will accept.
3. **`platform/v*` tags:** restrict creation, update and deletion. Good practice; security doesn't depend on it, because admission checks the SHA.
4. Optional, if available: require actions to be pinned to a full SHA (repo Actions setting), and immutable releases for `platform/v*`.

### 8.3 Platform release → allowlist flow
1. Platform change merged to `main` via a reviewed PR.
2. Owner pushes tag `platform/vX.Y.Z`.
3. `platform-release.yml` runs and writes to the job summary:
   - the tag, the commit SHA,
   - the exact allowlist entry to add to `stefanaki/lab`.
4. Owner adds the entry in `stefanaki/lab` (PR → merge → Flux applies).
5. Renovate opens PRs in this repo that bump the callers to the new SHA.

### 8.4 Change flow
- Until the `main` ruleset exists (implementation task 08), commits go directly to `main`.
- After that, every change uses a branch (`<type>/<slug>`) and a PR. The PR checks must pass, and **the owner merges**.
- Commits are single-line Conventional Commits.

**§8.3 step 4 is manual for now.** Automating the cross-repo PR needs a token for the private lab repo stored in this public repo. That's deferred deliberately.

---

## 9. Kubernetes (homelab `stefanaki/lab`, cluster kabu, branch `kabu`)

Follow `.claude/skills/kabu-dev` conventions in that repo:
- never touch sima;
- prefer flat kabu dirs over `base/`;
- pin chart versions;
- Pod Security `restricted` labels on namespaces;
- validate with `kubectl kustomize`.

**Nothing in `stefanaki/lab` is changed until the homelab phase is approved.**

Cluster facts: single Talos node, **amd64**, Kubernetes v1.36, Flux v2.9, Cilium Gateway API.

### 9.1 Layout
```
infrastructure/kabu/kyverno/
  namespace.yaml
  helm-repository.yaml        # flux-system, https://kyverno.github.io/kyverno/
  kyverno.yaml                # HelmRelease, pinned version, CRDs CreateReplace, single-node sized
  kustomization.yaml
apps/kabu/slsa-l3-reference/
  kustomization.yaml          # lists children
  policies/
    verify-orders-api.yaml    # ClusterPolicy (§9.3)
    kustomization.yaml
  orders-api/
    namespace.yaml            # ns slsa-l3-reference, PSS restricted
    deployment.yaml
    service.yaml              # ClusterIP :80 → 8080
    http-route.yaml           # orders-slsa.gstefan.net → gateway/gstefan-gateway
    kustomization.yaml
  sandbox/
    namespace.yaml            # ns slsa-sandbox, PSS restricted; nothing deployed by default
    kustomization.yaml
```
Ordering: `apps` already has `dependsOn: infrastructure` with `wait: true`, so Kyverno and its CRDs are ready before the policies are applied. No extra Flux Kustomization and no Helm chart for the policies.

**Known first-install race:** within `apps`, the policy and the Deployment are applied in the same pass. On the very first bootstrap, run `kubectl -n slsa-l3-reference rollout restart deploy/orders-api` once. Documented.

### 9.2 Workload
- Image: `ghcr.io/stefanaki/slsa-l3-reference/orders-api:X.Y.Z@sha256:…`.
- Restricted securityContext: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, read-only root filesystem.
- Liveness and readiness probes on `/healthz`; small resource requests and limits.
- **Digest updates:** Renovate in `stefanaki/lab` with the `kubernetes` manager enabled for `apps/kabu/slsa-l3-reference/**`. It opens PRs bumping `tag@digest` when new `X.Y.Z` tags appear in GHCR.

### 9.3 Kyverno policy (`ClusterPolicy`, `Enforce`)
- **Match:** Pods (and pod controllers) using `ghcr.io/stefanaki/slsa-l3-reference/*`, in any namespace except `kube-system`, `flux-system` and `kyverno`.
- **`failurePolicy: Fail`**, scoped to this policy's images only. Other images aren't affected by a Kyverno outage.
- `verifyImages` rule, `type: SigstoreBundle`, `mutateDigest: true`, `verifyDigest: true`, `required: true`.
- **Attestors (the signer digest allowlist):** keyless, issuer `https://token.actions.githubusercontent.com`, Rekor `https://rekor.sigstore.dev`. **One entry per approved platform commit** (`count: 1`). The subject is the exact certificate SAN:
  ```
  https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@<approved-sha>
  ```
  Each entry carries a comment naming the `platform/vX.Y.Z` it corresponds to. Removing an entry revokes that platform version.
- **Attestation 1: provenance** (`https://slsa.dev/provenance/v1`). Conditions:
  - `buildDefinition.externalParameters.workflow.repository` == `https://github.com/stefanaki/slsa-l3-reference`
  - `buildDefinition.externalParameters.workflow.ref` matches `refs/tags/apps/orders-api/v*`
- **Attestation 2: SBOM** (`https://cyclonedx.org/bom`): must exist, from the same attestors.
- **API choice:** `ClusterPolicy` `verifyImages` (where GitHub attestation support is documented). During implementation, check whether the CEL-based `ImageValidatingPolicy` in the pinned Kyverno version supports Sigstore bundles cleanly; switch if so.

### 9.4 Acceptance in cluster
- The `orders-api` release image is admitted and served at `orders-slsa.gstefan.net/healthz`.
- Each `negative-test` image (`unsigned`, `self-attested`) applied as a Pod in `slsa-sandbox` is **rejected** with a reason matching §7.1.
- `kyverno test policy/tests` passes, including the allowlist-negative case (§7.1).
- A pod referencing the release image by tag only is mutated to `@sha256:…`.

---

## 10. Verification outside the cluster (`scripts/verify.sh`, `docs/verification.md`)

```bash
# image
gh attestation verify oci://ghcr.io/stefanaki/slsa-l3-reference/orders-api:X.Y.Z \
  --repo stefanaki/slsa-l3-reference \
  --signer-workflow stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml \
  --signer-digest <approved-sha> \
  --source-ref refs/tags/apps/orders-api/vX.Y.Z \
  --predicate-type https://slsa.dev/provenance/v1
# same with --predicate-type https://cyclonedx.org/bom for the SBOM

# Go binary
gh attestation verify ./inventory_linux_amd64 \
  --repo stefanaki/slsa-l3-reference \
  --signer-workflow stefanaki/slsa-l3-reference/.github/workflows/platform-go.yml \
  --signer-digest <approved-sha> \
  --source-ref refs/tags/apps/inventory/vX.Y.Z
```
The script also runs the negative cases and expects them to fail.

Inspect BuildKit's unsigned records: `docker buildx imagetools inspect <image> --format '{{json .Provenance}}'` and `'{{json .SBOM}}'`.

---

## 11. Docs content

- **`architecture.md`:** roles, trust boundaries, and a diagram of caller → platform (build / scan / attest jobs) → GHCR → Renovate → Flux → Kyverno.
- **`slsa-l3-mapping.md`:** SLSA Build L3 requirements mapped to where they're met:
  - provenance exists, is authentic and unforgeable;
  - the build is isolated (hosted runners, reusable workflow, signing job separated from user-defined steps);
  - the signing identity can't be reached by build steps.
- **`verification.md`:**
  - reading a Sigstore cert: SAN = signer workflow@sha; Build Config URI; source ref;
  - `gh` flags;
  - how the Kyverno policy maps to the same checks.
- **`rulesets.md`:** §8.2 step by step.
- **`environments.md`:** adding `-dev` namespaces that admit `refs/heads/main` builds next to release-only namespaces.
- **`prod-delta.md`:**
  - **GHEC private repos** use GitHub's Sigstore instance (no public Rekor, GitHub TSA, TUF root from GitHub's TUF repo). Kyverno needs a custom TUF/trust-root config and `ignoreTlog`; the policy logic stays the same.
  - **Separate platform repo:** add a signer-repo check. SHA pins and the allowlist remain recommended.
  - Org rulesets and required workflows.
  - Private GHCR: pull secrets.
  - Automating the allowlist PR.

---

## 12. Implementation phases

| # | Phase | Output | Gate |
|---|---|---|---|
| 1 | Scaffold and apps | `apps/orders-api`, `apps/inventory`, tests, Dockerfile; buildable locally (Docker) | builds and tests pass |
| 2 | Platform and callers | `platform-docker.yml`, `platform-go.yml`, `platform-release.yml`, callers, CODEOWNERS, Renovate | **confirm before creating the public GitHub repo and pushing** |
| 3 | First releases | rulesets configured (manual), `platform/v1.0.0`, `apps/orders-api/v1.0.0`, `apps/inventory/v1.0.0` | `scripts/verify.sh` passes |
| 4 | Negative tests | `negative-test.yml`, negative cases in `verify.sh` | all negatives fail verification |
| 5 | Homelab | Kyverno, policy, orders-api manifests, lab Renovate change on branch `kabu` | **explicit approval before touching `~/homelab/lab`**; §9.4 passes |
| 6 | Docs | `docs/*`, README | review |

---

## 13. Development environment

Workstation: Fedora 43, x86_64, zsh. Snapshot from 2026-10-04.

### 13.1 Toolchain

| Tool | Version | Install location / method | Used for |
|---|---|---|---|
| .NET SDK | 10.0.401 (LTS channel) | `~/.dotnet` via Microsoft `dotnet-install.sh --channel LTS`; symlink `~/.local/bin/dotnet` | `orders-api` build and test |
| Go | 1.27.1 (latest stable; Go has no LTS) | `~/.local/go` (go.dev tarball, sha256 verified); symlinks `~/.local/bin/{go,gofmt}` | `inventory` build and test |
| Kyverno CLI | 1.19.1 | `~/.local/bin/kyverno` (GitHub release, checksum verified) | offline policy tests (`kyverno apply` / `kyverno test`) |
| actionlint | 1.7.12 | `~/.local/bin/actionlint` (`go install`) | workflow linting before push |
| Docker | 29.8.2, containerd image store | system | local image builds; multi-platform images loadable |
| buildx (BuildKit) | 0.37.1 | system | same builder as CI |
| Trivy | 0.74.0 | system | SBOM and CVE scans, same as CI |
| gh | 2.87.3 | system, logged in as `stefanaki` | repo ops, `gh attestation verify` |
| kubectl / helm / flux | present | system | homelab phase (`kubectl kustomize` instead of standalone kustomize) |
| git, jq, yq | present | system | |

Not used: `cosign` (`gh attestation verify` covers it), `act` (it can't get GitHub OIDC tokens, so attest jobs can't run locally), `ko`, `syft`. Optional: `qemu-user-static` only for running arm64 images locally.

### 13.2 Version alignment with CI
- `apps/inventory/go.mod`: `go 1.27`. CI uses `actions/setup-go` with `go-version-file`.
- `apps/orders-api`: `global.json` pins SDK `10.0.x` with `rollForward: latestFeature`. The Dockerfile SDK image tag is `10.0`, digest-pinned.
- Trivy version in CI is pinned to the same minor as local (0.74) to keep SBOM output comparable.
- Kyverno chart for kabu: pick the chart release that ships Kyverno **1.19.x**, to match the CLI used for offline policy tests.

### 13.3 Cluster access
- kubeconfig context `admin@lab`: single Talos node, amd64, Kubernetes v1.36.2. Confirm it's kabu before phase 5.
- Homelab repo: `~/homelab/lab`, branch `kabu`.

---

## 14. To verify during implementation (not design decisions)

1. Kyverno `SigstoreBundle` finds GHCR-stored bundles (OCI referrers or tag-schema fallback) for `attest-build-provenance` / `attest-sbom` with `push-to-registry`.
2. Kyverno keyless attestor subject matching works against the exact SAN with `@<sha>`. Using **multiple attestor entries** as the allowlist is the default design. If Kyverno supports variables there, an allowlist ConfigMap is a possible refinement. **If signer-SHA matching isn't possible in Kyverno at all, stop and consult the owner** (fallback: tag-ref policy plus a scheduled `gh attestation verify --signer-digest` audit).
3. JMESPath / wildcard support for the `workflow.ref` condition.
4. `ImageValidatingPolicy` vs `ClusterPolicy` in Kyverno 1.19.x.
5. GitHub Packages NuGet feed restore with `GITHUB_TOKEN` from a reusable workflow (`packages: read`).
6. Availability of "require SHA-pinned actions" and immutable releases on a personal public repo.
