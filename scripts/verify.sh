#!/usr/bin/env bash
# Strict verification of a released app outside the cluster (SPEC §10).
# Usage: scripts/verify.sh <orders-api|inventory> <X.Y.Z>
#        scripts/verify.sh negatives <shortsha>   (images from negative-test.yml, SPEC §7.1)
#
# Every attestation must be signed by an approved platform commit, built from the release tag
# on a GitHub-hosted runner, and exist for both SLSA provenance and the CycloneDX SBOM.
# Needs gh >= 2.102.0 (SPEC §13.1) and, for images, docker buildx.
set -euo pipefail

repo=stefanaki/slsa-l3-reference

# Approved platform commits: the same allowlist Kyverno enforces (SPEC §2 rule 3, §8.3).
# Never derived from a tag: tags can move, the allowlist is reviewed.
approved_platform_shas=(
  78c2b4251876144f5fc346f843c313efbaac745b # platform/v1.0.0
)

predicate_types=(
  https://slsa.dev/provenance/v1
  https://cyclonedx.org/bom
)

usage="usage: verify.sh <orders-api|inventory> <X.Y.Z> | verify.sh negatives <shortsha>"
app="${1:?$usage}"
version="${2:?$usage}"
if [[ "$app" == negatives ]]; then
  [[ "$version" =~ ^[0-9a-f]{7}$ ]] || { echo "verify.sh: shortsha must be 7 hex characters" >&2; exit 2; }
  # Negatives aren't release builds: leave out --source-ref so a rejection comes from the signer checks alone.
  ref_flags=()
else
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "verify.sh: version must be X.Y.Z" >&2; exit 2; }
  ref_flags=(--source-ref "refs/tags/apps/$app/v$version")
fi

# Older gh treats --signer-workflow as an unanchored prefix regex; require the version this was tested with.
gh_version="$(gh --version | sed -n '1s/^gh version \([0-9.]*\).*/\1/p')"
[[ "$(printf '%s\n' 2.102.0 "$gh_version" | sort -V | head -1)" == 2.102.0 ]] \
  || { echo "verify.sh: gh >= 2.102.0 required, found ${gh_version:-unknown}" >&2; exit 2; }

# verify <subject> <platform workflow> [extra gh flags]: passes if one approved platform commit
# signed every predicate type. --cert-identity is an exact SAN match. On failure, prints
# the last gh error (policy mismatch, missing attestation, network) so the cause is visible.
verify() {
  local subject="$1" workflow="$2"; shift 2
  local sha pt err=""
  for sha in "${approved_platform_shas[@]}"; do
    for pt in "${predicate_types[@]}"; do
      err="$(gh attestation verify "$subject" \
        --repo "$repo" \
        --cert-identity "https://github.com/$repo/.github/workflows/$workflow@$sha" \
        --signer-digest "$sha" \
        "${ref_flags[@]}" \
        --deny-self-hosted-runners \
        --predicate-type "$pt" \
        "$@" 2>&1 >/dev/null)" || { err="$(grep -v "^$" <<<"$err" | tail -n1)"; continue 2; }
      echo "ok    ${subject##*/}  $pt  ($workflow@${sha:0:7}${*:+ $*})"
    done
    return 0
  done
  echo "FAIL  ${subject##*/}: no approved platform commit signed all predicate types${ref_flags[1]:+ for ${ref_flags[1]}}" >&2
  echo "      last gh error: ${err:-none}" >&2
  return 1
}

# digest <image:tag>: the index digest the tag points to now.
digest() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest
}

# expect_reject <case> <subject>: the strict policy must reject the subject, API and registry bundles alike.
expect_reject() {
  local name="$1" subject="$2" flags
  for flags in "" --bundle-from-oci; do
    if verify "$subject" platform-docker.yml $flags >/dev/null 2>&1; then
      echo "FAIL  $name: accepted by the strict policy${flags:+ ($flags)}" >&2; return 1
    fi
    echo "ok    $name: rejected by the strict policy${flags:+ ($flags)}"
  done
}

rc=0
case "$app" in
  negatives)
    # SPEC §7.1. Each case must fail the strict policy, and a second check pins down why.
    short="$version"
    image="ghcr.io/$repo/orders-api"
    unsigned="$(digest "$image:negative-unsigned-$short")"
    self_attested="$(digest "$image:negative-self-attested-$short")"
    echo "image $image:negative-unsigned-$short = $unsigned"
    echo "image $image:negative-self-attested-$short = $self_attested"
    # Same digest would mean the self-attested attestations also cover the "unsigned" image.
    [[ "$unsigned" != "$self_attested" ]] || { echo "FAIL  both cases share digest $unsigned" >&2; exit 1; }

    # unsigned: no attestation exists at all, so even a check with no signer constraint finds nothing.
    expect_reject unsigned "oci://$image@$unsigned" || rc=1
    # The API filters by predicate type, so ask for each one. The registry check lists every bundle:
    # only "in the OCI registry" means none at all ("with predicate type" means others exist).
    for flags in "" --bundle-from-oci; do
      for pt in "${predicate_types[@]}"; do
        err="$(gh attestation verify "oci://$image@$unsigned" --repo "$repo" \
          --predicate-type "$pt" $flags 2>&1 >/dev/null)" \
          && { echo "FAIL  unsigned: a $pt attestation exists${flags:+ ($flags)}" >&2; rc=1; continue; }
        if grep -qE "HTTP 404|no attestations found in the OCI registry" <<<"$err"; then
          echo "ok    unsigned: reason = no attestation  $pt${flags:+ ($flags)}"
        else
          echo "FAIL  unsigned: unexpected error${flags:+ ($flags)}: $(grep -v "^$" <<<"$err" | tail -n1)" >&2; rc=1
        fi
      done
    done

    # self-attested: gh's identity-mismatch error is generic, so show the reason positively: the
    # attestations are valid, just signed by the caller workflow instead of the platform.
    expect_reject self-attested "oci://$image@$self_attested" || rc=1
    signer="https://github.com/$repo/.github/workflows/negative-test.yml@refs/heads/main"
    for flags in "" --bundle-from-oci; do
      for pt in "${predicate_types[@]}"; do
        if gh attestation verify "oci://$image@$self_attested" --repo "$repo" \
          --cert-identity "$signer" --source-ref refs/heads/main --deny-self-hosted-runners \
          --predicate-type "$pt" $flags >/dev/null 2>&1; then
          echo "ok    self-attested: reason = signer is negative-test.yml  $pt${flags:+ ($flags)}"
        else
          echo "FAIL  self-attested: no valid $pt attestation from $signer${flags:+ ($flags)}" >&2; rc=1
        fi
      done
    done
    ;;
  orders-api)
    image="ghcr.io/$repo/$app"
    # Verify the digest, not the tag: a tag can be repointed after verification.
    digest="$(digest "$image:$version")"
    echo "image $image:$version = $digest"
    verify "oci://$image@$digest" platform-docker.yml || rc=1
    # Kyverno reads the bundles stored in the registry, not the GitHub attestations API.
    verify "oci://$image@$digest" platform-docker.yml --bundle-from-oci || rc=1
    # BuildKit's own records: unsigned, informational only.
    buildkit="$(docker buildx imagetools inspect "$image@$digest" --format '{{json .Provenance}}' 2>/dev/null || true)"
    [[ -n "$buildkit" && "$buildkit" != "null" && "$buildkit" != "{}" ]] \
      && echo "info  BuildKit provenance present (unsigned)" \
      || echo "info  BuildKit provenance missing"
    ;;
  inventory)
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' EXIT
    gh release download "apps/$app/v$version" --repo "$repo" --pattern "${app}_*" --dir "$dir"
    shopt -s nullglob
    binaries=("$dir/${app}"_*)
    [[ ${#binaries[@]} -eq 4 ]] || { echo "FAIL  expected 4 binaries, got ${#binaries[@]}" >&2; rc=1; }
    for bin in "${binaries[@]}"; do
      verify "$bin" platform-go.yml || rc=1
    done
    ;;
  *)
    echo "verify.sh: unknown app $app" >&2
    exit 2
    ;;
esac

[[ $rc -eq 0 ]] && echo "PASS  $app $version" || echo "FAIL  $app $version" >&2
exit "$rc"
