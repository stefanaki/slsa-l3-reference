# inventory

Go CLI that lists sample stock items: `inventory list`, `inventory version`.

## Local development

```sh
cd apps/inventory
go test ./...
./build.sh 0.0.0-dev   # cross-compiles linux/darwin × amd64/arm64 into dist/
```

## Release

Push a tag `apps/inventory/vX.Y.Z` on a PR merge commit on `main`. The pinned platform (`platform-go.yml`) builds the four binaries with the same flags as `build.sh`, attests their SLSA provenance and SBOM, and attaches them to the GitHub Release. Verify with `scripts/verify.sh inventory X.Y.Z`.
