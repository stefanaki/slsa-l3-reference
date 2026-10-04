#!/usr/bin/env bash
# Asserts each negative is rejected for its own reason (SPEC §7.1, §9.4).
# `kyverno test` only checks pass/fail, so this runs `kyverno apply` and matches the rejection message.
# Needs network access: Kyverno fetches the images, their Sigstore bundles and the Sigstore trust root.
# Usage: policy/tests/reasons.sh
set -euo pipefail
cd "$(dirname "$0")"

policy=../verify-orders-api.yaml
variant=allowlist-negative/policy.yaml
real_sha=78c2b4251876144f5fc346f843c313efbaac745b # platform/v1.0.0

rc=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The variant must be the real policy with only the approved SHA swapped, or its test proves nothing.
if diff <(yq '... comments=""' "$policy" | sed "s/@$real_sha/@$(printf '0%.0s' {1..40})/") \
        <(yq '... comments=""' "$variant") >/dev/null; then
  echo "ok    $variant differs from $policy only in the approved SHA"
else
  echo "FAIL  $variant has drifted from $policy" >&2; rc=1
fi

# expect <policy> <pod> <message>: the pod is rejected with exactly this message.
expect() {
  local pol="$1" pod="$2" want="$3" out
  yq "select(.metadata.name == \"$pod\")" release/resources.yaml > "$tmp/pod.yaml"
  out="$(kyverno apply "$pol" --resource "$tmp/pod.yaml" --remove-color 2>&1 || true)"
  if grep -qF -- "verify-orders-api $want" <<<"$out" && grep -q 'fail: 1,' <<<"$out"; then
    echo "ok    $pod (${pol##*/}): $want"
  else
    echo "FAIL  $pod: expected \"$want\"" >&2
    grep -E '^[0-9]+ - |^pass:' <<<"$out" | sed 's/^/      /' >&2
    rc=1
  fi
}

expect "$policy" unsigned "no attestation: image has no provenance signed by a workflow of stefanaki/slsa-l3-reference"
expect "$policy" self-attested "signer: provenance is not signed by an approved platform-docker.yml commit"
expect "$policy" main-build "source: not built from an apps/orders-api/v* release tag"
expect "$policy" unsigned-init "no attestation: image has no provenance signed by a workflow of stefanaki/slsa-l3-reference"
expect "$variant" release-digest "signer: provenance is not signed by an approved platform-docker.yml commit"

[[ $rc -eq 0 ]] && echo "PASS  rejection reasons" || echo "FAIL  rejection reasons" >&2
exit "$rc"
