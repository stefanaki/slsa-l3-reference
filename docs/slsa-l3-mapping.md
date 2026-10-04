# SLSA Build L3 mapping

This maps each requirement of the [SLSA Build track](https://slsa.dev/spec/v1.2/build-requirements)
to where this repository meets it. The current spec is SLSA v1.2. GitHub's own documentation calls
the same setup "[SLSA v1.0 Build Level 3](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/increase-security-rating)":
the Build L3 requirements didn't change in substance between v1.0 and v1.2.

GitHub Actions with [artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
is the build platform. GitHub's documented route to Build L3 is to build in a **reusable workflow**
that also attests: the signing certificate then names the reusable workflow, not the caller, so a
project can't produce provenance that looks like the platform's. That's what `platform-docker.yml` and
`platform-go.yml` are.

## Build platform requirements

| Requirement | Level | Where it's met |
|---|---|---|
| **Provenance exists**: identifies the output by digest and describes how it was produced | L1+ | `actions/attest` in the platform's `attest` job writes an in-toto statement with predicate `https://slsa.dev/provenance/v1`. The subject is the image index digest (`platform-docker.yml`) or each binary's sha256 (`platform-go.yml`). A second statement attests the CycloneDX SBOM (`https://cyclonedx.org/bom`) for the same subjects. |
| **Provenance is authentic**: consumers can check its integrity and who produced it | L2+ | Each statement is signed keyless with Sigstore: Fulcio issues a short-lived certificate for the job's GitHub OIDC token, and the signature is logged in Rekor. Consumers check it with `gh attestation verify` or Kyverno ([`verification.md`](verification.md)). |
| **Provenance is unforgeable**: signing material isn't reachable by user-defined build steps, and every field is generated or verified by the platform | L3 | See [Signing is out of reach of build steps](#signing-is-out-of-reach-of-build-steps). |
| **Hosted**: all build steps run on a hosted build platform | L2+ | Every job uses GitHub-hosted `ubuntu-24.04`. The certificate records `runnerEnvironment: github-hosted`. `scripts/verify.sh` requires it (`--deny-self-hosted-runners`). Kyverno doesn't check it: only the platform signs an allowlisted identity, and it runs on hosted runners only. |
| **Isolated**: build steps run free of unintended external influence | L3 | See [Builds are isolated](#builds-are-isolated). |

### Signing is out of reach of build steps

The SLSA requirement: "Such secret material MUST NOT be accessible to the environment running the
user-defined build steps. Every field in the provenance MUST be generated or verified by the build
platform in a trusted control plane."

- **The signing secret is the OIDC token.** Only the `attest` job has `id-token: write`. The `build`
  job, where the Dockerfile's `RUN` steps and `go build` of repo code run, has no `id-token`, so it can't
  request a token, and no Fulcio certificate can be issued from it. For both platform files,
  `yq '.jobs | to_entries[] | select(.value.permissions["id-token"] != null) | .key'` returns only `attest`.
- **The `attest` job runs fixed steps.** It has no checkout and runs no command from the repository. It
  gets the subject digest from `build`'s outputs and the SBOM from `scan`, downloaded by artifact id (a
  caller job can't overwrite it by name) and checked against the sha256 `scan` recorded.
- **The provenance fields come from GitHub, not from the build.** `actions/attest`
  [builds the predicate](https://github.com/actions/toolkit/blob/main/packages/attest/src/provenance.ts)
  from the OIDC token's claims: `builder.id` from `job_workflow_ref`, and
  `externalParameters.workflow.{repository,ref,path}` from `repository`, `ref` and `workflow_ref`. GitHub
  signs those claims, and Fulcio copies them into the certificate's extensions. Nothing in `apps/` can
  change them.
- **The signer identity names the platform at a commit.** The certificate SAN and the provenance's
  `builder.id` are both
  `https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@78c2b42…`. GitHub
  resolves `@<sha>` from the caller's `uses:` line, so a project can pick *which* platform commit it calls
  but can't fake which one signed. The verifiers accept only allowlisted commits.
- **Secrets the build needs are scoped down.** orders-api's restore uses `NUGET_READ_TOKEN`, a classic PAT
  with only `read:packages`, passed as a BuildKit secret mount. The job's `GITHUB_TOKEN` (which can
  write packages) is used only by the registry login that pushes the image. It's never a build secret or
  build arg, so `RUN` steps can't read it. A local `mode=max` build was searched for the full feed token:
  it appears in no image layer, history entry, build metadata or BuildKit provenance.

### Builds are isolated

| SLSA L3 isolation guarantee | How it holds here |
|---|---|
| A build can't access the platform's secrets | The build steps run in the `build` job, which has no `id-token` and no `attestations` permission. |
| Overlapping builds can't influence one another | Each job runs on a fresh GitHub-hosted VM. |
| One build can't persist into the next one's environment | Hosted runners are ephemeral. Tools aren't restored from the Actions cache either (`setup-trivy` with `cache: false`): any workflow on `main` could have written it. |
| No false entries in a build cache another build uses | **No build cache at all.** BuildKit runs with `no-cache: true` and no `cache-from`/`cache-to` in every mode, and `setup-go` runs with `cache: false`. The GitHub Actions cache is shared by every workflow on a branch, so a cached layer or module could have been written by a workflow that isn't the platform. |
| No services open for remote influence unless captured as external parameters | The platform starts none. Its inputs (`app`, `context`, `dockerfile`, `build-args`, `platforms`) are validated, and the only external parameters recorded are the caller workflow, its repository and its ref. |

## Producer requirements

| Requirement | Where it's met |
|---|---|
| **Choose an appropriate build platform** | GitHub-hosted runners with a reusable workflow that attests, as above. |
| **Follow a consistent build process** | Every app is built by one platform workflow with fixed steps. Its trigger is always a release tag `apps/<app>/vX.Y.Z` (or `main`), so a verifier can require an exact repository, signer workflow, signer commit and ref. |
| **Distribute provenance** | Each attestation is stored in GitHub's attestations API and, for images, pushed to GHCR next to the image (`push-to-registry: true`). The Go release also attaches `sbom.cdx.json` and `checksums.txt`. |

## What Build L3 doesn't cover, and what covers it here

Build L3 says the artifact came from a given build of a given source. It makes no claim that the source
was reviewed or tested, or that dependencies are trustworthy. This repository adds:

| Concern | Control | Enforced by |
|---|---|---|
| Released source was tested | Release tag commit must be the merge commit of a PR into `main`; `main` requires each app's `test` check with branches up to date | platform `build` job, `main` ruleset ([`rulesets.md`](rulesets.md)) |
| Only approved platform versions sign | Signer SHA allowlist | Kyverno attestors, `scripts/verify.sh` |
| Only release builds deploy | `externalParameters.workflow.ref` starts with `refs/tags/apps/orders-api/v` | Kyverno |
| Who can cut a release | `apps/*/v*` tag ruleset; bypass only for the repository admin role | GitHub |
| Known critical CVEs | Trivy CRITICAL gate (fixed CVEs only, every platform); a failing image is never attested | platform `scan` job |
| Base image drift | `FROM` lines and actions pinned by digest or SHA; bumps are manual (`.github/renovate.json` is configured, the app isn't installed) | repo setting `sha_pinning_required`; nothing bumps the pins automatically |
| Dependency confusion | NuGet `packageSourceMapping`: only `Stefanaki.*` may come from the private feed, everything else from nuget.org; locked restore | `nuget.config`, `packages.lock.json` |

## Known gaps

- **The attested image SBOM describes `linux/amd64` only.** The CVE gate covers every platform; the SBOM
  doesn't. The Go SBOM covers all four binaries. [`architecture.md`](architecture.md#known-limits) lists the remaining limits.
- **The Go build is reproducible; the image build is only close to it.** The Go build is: two clean
  builds give identical checksums. The image build sets `SOURCE_DATE_EPOCH` and
  `rewrite-timestamp=true`, but package restores fetch from the network. SLSA Build L3 doesn't require
  reproducibility.
- **Hardened-runner egress control isn't used.** Build steps can reach the network.
