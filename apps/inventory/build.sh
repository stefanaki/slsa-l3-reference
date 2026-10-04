#!/usr/bin/env bash
# Reproducible cross-compile of inventory; platform-go.yml uses the same flags.
# Usage: ./build.sh <version> [outdir]
set -euo pipefail

version="${1:?usage: build.sh <version> [outdir]}"
outdir="${2:-$(dirname "$0")/dist}"
targets="${TARGETS:-linux/amd64,linux/arm64,darwin/amd64,darwin/arm64}"

outdir="$(realpath -m "$outdir")"
cd "$(dirname "$0")"

# Go stamps vcs.modified into each binary, so output inside the repo must be git-ignored.
rc=0
git check-ignore -q "$outdir" 2>/dev/null || rc=$?
if [[ $rc -eq 1 ]]; then
  echo "build.sh: $outdir is inside the repo but not git-ignored; use dist/..." >&2
  exit 1
fi
mkdir -p "$outdir"

binaries=()
IFS=, read -ra platforms <<< "$targets"
for platform in "${platforms[@]}"; do
  goos="${platform%/*}"
  goarch="${platform#*/}"
  bin="inventory_${goos}_${goarch}"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -trimpath \
    -ldflags "-s -w -buildid= -X main.version=${version}" \
    -o "${outdir}/${bin}" .
  binaries+=("$bin")
done

(cd "$outdir" && sha256sum "${binaries[@]}" > checksums.txt)
