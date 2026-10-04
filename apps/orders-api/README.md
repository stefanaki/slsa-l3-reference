# orders-api

ASP.NET Core minimal API on .NET 10. Endpoints: `GET /healthz`, `GET /orders`, `GET /version`.

## Local development

Run `dotnet` commands from this directory, so `global.json` (SDK pin and Microsoft.Testing.Platform runner) applies:

```sh
cd apps/orders-api
export NUGET_TOKEN=$(gh auth token)
dotnet restore --locked-mode
dotnet build -c Release
dotnet test -c Release
```

`nuget.config` adds the owner's GitHub Packages feed (`https://nuget.pkg.github.com/stefanaki/index.json`) next to nuget.org, to simulate a private feed. Its password is read from `NUGET_TOKEN`.

## Container image

The Dockerfile has four stages: `build` (restore and build), `test`, `publish` and `runtime` (chiseled `aspnet`, UID 1654, port 8080). The token reaches only the restore step, through a BuildKit secret:

```sh
export GH_TOKEN=$(gh auth token)
docker buildx build --secret id=nuget_token,env=GH_TOKEN --target test .
docker buildx build --secret id=nuget_token,env=GH_TOKEN --build-arg VERSION=1.2.3 -t orders-api:dev --load .
docker run --rm --read-only -p 8080:8080 orders-api:dev
```

Notes:
- A build without `--secret` fails with `secret nuget_token: not found`, but only when the restore layer is not cached. BuildKit does not include secrets in the cache key.
- `packageSourceMapping` sends every package to nuget.org and only `Stefanaki.*` to the GitHub feed. The feed hosts no packages, so restore never contacts it: the build proves the secret is passed through without leaking, not that the token is valid.
