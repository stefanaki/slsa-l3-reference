#!/usr/bin/env bash
# Strict verification of a released app outside the cluster (SPEC §10).
# Usage: scripts/verify.sh <orders-api|inventory> <X.Y.Z>
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

app="${1:?usage: verify.sh <orders-api|inventory> <X.Y.Z>}"
version="${2:?usage: verify.sh <orders-api|inventory> <X.Y.Z>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "verify.sh: version must be X.Y.Z" >&2; exit 2; }
source_ref="refs/tags/apps/$app/v$version"

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
        --source-ref "$source_ref" \
        --deny-self-hosted-runners \
        --predicate-type "$pt" \
        "$@" 2>&1 >/dev/null)" || { err="$(grep -v "^$" <<<"$err" | tail -n1)"; continue 2; }
      echo "ok    ${subject##*/}  $pt  ($workflow@${sha:0:7}${*:+ $*})"
    done
    return 0
  done
  echo "FAIL  ${subject##*/}: no approved platform commit signed all predicate types for $source_ref" >&2
  echo "      last gh error: ${err:-none}" >&2
  return 1
}

rc=0
case "$app" in
  orders-api)
    image="ghcr.io/$repo/$app"
    # Verify the digest, not the tag: a tag can be repointed after verification.
    digest="$(docker buildx imagetools inspect "$image:$version" --format '{{json .Manifest}}' | jq -r .digest)"
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
