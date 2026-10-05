# Verification

Two verifiers check the same facts about an artifact. They differ only in where they run:

- **`gh attestation verify`**, wrapped by [`scripts/verify.sh`](../scripts/verify.sh), checks a release
  from anywhere: images and Go binaries.
- **Kyverno**, through the [`ImageValidatingPolicy`](../policy/verify-orders-api.yaml) deployed to the
  kabu cluster, checks every Pod that uses an image of this repo, at admission.

## What's in a Sigstore certificate

Each attestation is signed with a short-lived Fulcio certificate issued for the GitHub OIDC token of
the job that signed. Fulcio copies the token's claims into certificate extensions. These are the
fields from the real `orders-api:1.0.0` provenance (`gh attestation verify … --format json`,
`.[0].verificationResult.signature.certificate`):

| Field | Value | What it tells you |
|---|---|---|
| `subjectAlternativeName` (SAN) | `https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@78c2b4251876144f5fc346f843c313efbaac745b` | **Who signed:** the platform workflow, at the exact commit the caller pinned. This is what the allowlist matches. |
| `buildSignerURI` / `buildSignerDigest` | same SAN / `78c2b42…` | The signer again, as URI and commit. `--signer-digest` matches the digest. |
| `buildConfigURI` | `https://github.com/stefanaki/slsa-l3-reference/.github/workflows/release-orders-api.yml@refs/tags/apps/orders-api/v1.0.0` | **Who called the platform:** the project's caller workflow, at the triggering ref. |
| `sourceRepositoryURI` | `https://github.com/stefanaki/slsa-l3-reference` | Repository that was built. `--repo` matches it. |
| `sourceRepositoryRef` | `refs/tags/apps/orders-api/v1.0.0` | **What was built:** the release tag. `--source-ref` matches it. |
| `sourceRepositoryDigest` | `b328a8b…` | The commit the tag pointed to (the PR #2 merge commit). |
| `runnerEnvironment` | `github-hosted` | `--deny-self-hosted-runners` requires this. |
| `issuer` | `https://token.actions.githubusercontent.com` | GitHub Actions' OIDC issuer. |
| `runInvocationURI` | `…/actions/runs/37214345705/attempts/1` | The run that produced it. |

In a reusable workflow the SAN is the *called* workflow, not the caller. That's what makes the
platform the signer: a project can only pick which platform commit it calls, and GitHub, not the build,
resolves `@<sha>`.

The provenance predicate (`.[0].verificationResult.statement.predicate`) carries the same facts in SLSA
form. `runDetails.builder.id` equals the SAN, and `buildDefinition.externalParameters.workflow` is
`{repository: https://github.com/stefanaki/slsa-l3-reference, ref: refs/tags/apps/orders-api/v1.0.0,
path: .github/workflows/release-orders-api.yml}`. Kyverno reads those fields.

## `gh attestation verify`

`scripts/verify.sh` runs this for every approved platform SHA and both predicate types:

```sh
gh attestation verify oci://ghcr.io/stefanaki/slsa-l3-reference/orders-api@sha256:71a23e7ccda289f58b2835d0ed9ec898b7a5a56f4f7f5929d2eafee145c3432c \
  --repo stefanaki/slsa-l3-reference \
  --cert-identity https://github.com/stefanaki/slsa-l3-reference/.github/workflows/platform-docker.yml@78c2b4251876144f5fc346f843c313efbaac745b \
  --signer-digest 78c2b4251876144f5fc346f843c313efbaac745b \
  --source-ref refs/tags/apps/orders-api/v1.0.0 \
  --deny-self-hosted-runners \
  --predicate-type https://slsa.dev/provenance/v1
```

| Flag | Checks | Why |
|---|---|---|
| `oci://…@sha256:…` | the subject, by digest | A tag can be repointed after you check it. `verify.sh` resolves the tag once with `docker buildx imagetools inspect` and verifies the digest. |
| `--repo` | `sourceRepositoryURI` | The artifact was built from this repository. |
| `--cert-identity` | SAN, exact match | Signed by the platform workflow at an approved commit. |
| `--signer-digest` | `buildSignerDigest` | The same commit again, as a separate check. |
| `--source-ref` | `sourceRepositoryRef` | Built from the release tag, not a branch. |
| `--deny-self-hosted-runners` | `runnerEnvironment` | Built on a GitHub-hosted runner. |
| `--predicate-type` | statement type | Run once for `https://slsa.dev/provenance/v1` and once for `https://cyclonedx.org/bom`. Without it gh only checks provenance. |
| `--bundle-from-oci` | where bundles come from | Reads the bundles stored in GHCR instead of GitHub's attestations API. That's what Kyverno reads, so `verify.sh` checks both. |

**Why not `--signer-workflow`.** Before gh 2.102.0, `--signer-workflow` matched only the
[start of the certificate's identity](https://github.com/cli/cli/releases/tag/v2.102.0), and
`--source-ref` compared case-insensitively. `--cert-identity` is an exact match on the whole SAN on any
version. `verify.sh` also refuses to run on gh older than 2.102.0.

**The platform job summaries still print `--signer-workflow`.** The "Attested image" summary of the
v1.0.0 platform shows a `--signer-workflow … --signer-digest <approved platform sha>` command. It's a
hint only. Use the command above. Fixing the summary is a platform change and waits for the next
platform release.

**Where the approved SHA comes from.** `approved_platform_shas` in `verify.sh` is the same allowlist
Kyverno enforces. Never derive it from a `platform/v*` tag: tags can move, and the allowlist is reviewed.

### `scripts/verify.sh`

```sh
scripts/verify.sh orders-api 1.0.0     # image: provenance + SBOM, via the API and --bundle-from-oci
scripts/verify.sh inventory 1.0.0      # downloads the 4 release binaries; provenance + SBOM for each
scripts/verify.sh negatives f464254    # images from negative-test.yml at commit f464254 must fail
```

Each prints one `ok` line per check and ends with `PASS` (exit 0) or `FAIL` (exit 1). For a failure it
prints the last gh error, so you can tell a policy mismatch from a missing attestation or a network error.

`negatives` checks the two images from [`negative-test.yml`](../.github/workflows/negative-test.yml), and
for each one shows *why* it fails:

| Case | Strict check | Reason shown positively |
|---|---|---|
| `unsigned` | rejected | gh finds no attestation of either predicate type, in the API (`HTTP 404`) or in GHCR |
| `self-attested` | rejected | its attestations verify with `--cert-identity …/negative-test.yml@refs/heads/main`: valid, but signed by the caller, not the platform |

### BuildKit's own records

The image index also holds BuildKit's provenance (`mode=max`) and SBOM for each platform. They're
unsigned and covered only by the index digest, so treat them as information, not evidence:

```sh
docker buildx imagetools inspect ghcr.io/stefanaki/slsa-l3-reference/orders-api@sha256:71a23e7ccda289f58b2835d0ed9ec898b7a5a56f4f7f5929d2eafee145c3432c \
  --format '{{json .Provenance}}'   # or '{{json .SBOM}}'
```

## Kyverno

The policy runs the same checks as `verify.sh`, in a fixed order. The first one that fails is the
rejection message:

| # | Policy check | Rejection message prefix | `gh` equivalent |
|---|---|---|---|
| – | `mutateDigest`, `verifyDigest`: pin a bare tag to its digest, then verify the digest | (no digest) | `oci://…@sha256:…` |
| 1 | provenance signed by *any* workflow of this repo (attestor `anyRepoWorkflow`, a `subjectRegExp`) | `no attestation:` | – |
| 2 | provenance signed by an approved attestor (exact SAN, one attestor per platform commit) | `signer:` | `--cert-identity`, `--signer-digest` |
| 3 | SBOM signed by an approved attestor | `signer:` | same, `--predicate-type https://cyclonedx.org/bom` |
| 4 | `externalParameters.workflow.repository` is this repo | `source:` | `--repo` |
| 5 | `externalParameters.workflow.ref` starts with `refs/tags/apps/orders-api/v` | `source:` | `--source-ref` |

- **Check 1 never admits anything on its own.** It only tells "no attestation at all" apart from
  "attested, but by the wrong signer".
- **The order matters.** Kyverno stores verified payloads per predicate type for the whole request.
  Checks 4–5 read provenance that check 2 has just verified against the approved attestors.
- **The allowlist.** Each approved platform commit is one attestor named after its release
  (`platformV1_0_0`), with exactly one identity: the full SAN. The `approved` variable lists them.
  Removing an attestor revokes that platform version.
- **Hosted runner.** The policy doesn't check `runnerEnvironment`. Only the platform signs an approved
  identity, and the platform runs on `ubuntu-24.04` only.
- **No Rekor call.** Kyverno contacts only `ghcr.io`, `pkg-containers.githubusercontent.com` and
  `tuf-repo-cdn.sigstore.dev`. The transparency-log entry inside each bundle is verified offline
  against the Sigstore trust root.

### Offline tests

`policy/tests` runs the policy with the Kyverno CLI against the real GHCR images:

```sh
kyverno test policy/tests     # 10 passed: release admitted; bare tag, negatives, main build, allowlist-negative rejected
policy/tests/reasons.sh       # each rejection has its expected message
```

The `allowlist-negative` case runs the policy with an allowlist that leaves out the real platform SHA.
The genuine v1.0.0 release image must then fail on `signer:`. That's how the allowlist is shown to work
without producing an "unapproved platform commit" image on GitHub. The CLI runs only the validating
half of the policy, so it can't show the tag-to-digest mutation. A bare tag is rejected there instead.

### In the cluster

Server-side dry runs exercise admission without creating anything. `slsa-sandbox` enforces Pod Security
`restricted`, so the Pod needs a restricted security context:

```sh
img=ghcr.io/stefanaki/slsa-l3-reference/orders-api
overrides() {
  jq -cn --arg name "$1" --arg image "$2" '{apiVersion:"v1",spec:{automountServiceAccountToken:false,
    securityContext:{runAsNonRoot:true,seccompProfile:{type:"RuntimeDefault"}},
    containers:[{name:$name,image:$image,securityContext:{allowPrivilegeEscalation:false,
      readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}'
}
run() {
  kubectl -n slsa-sandbox run "$1" --image="$2" --restart=Never --dry-run=server \
    --overrides="$(overrides "$1" "$2")" -o jsonpath='{.spec.containers[0].image}'
}
run neg-unsigned "$img@sha256:92ce94bd008cf1b0514b749306e6e36d76b39ca12025770e522d9fcc72ac69f3"
# denied: no attestation: image has no provenance signed by a workflow of stefanaki/slsa-l3-reference
run neg-self-attested "$img@sha256:ebdcdd88369f1931a49d28b5f3aaec98c34723f84ffa0e60d72263cefca05c51"
# denied: signer: provenance is not signed by an approved platform-docker.yml commit
run tagonly "$img:1.0.0"
# ghcr.io/stefanaki/slsa-l3-reference/orders-api:1.0.0@sha256:71a23e7ccda289f58b2835d0ed9ec898b7a5a56f4f7f5929d2eafee145c3432c
curl -fsS https://orders-slsa.gstefan.net/healthz
# {"status":"ok"}
```
