# syntax=docker/dockerfile:1.27@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# Build on the native platform: .NET does not support running under QEMU. The output is framework-dependent, so it runs on any target platform.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0@sha256:e70cdb7f80b0348f5cb85f19a8f670fca061f033d57eed12fa003d58b0e06317 AS build
WORKDIR /src
COPY global.json nuget.config Directory.Build.props Directory.Packages.props OrdersApi.slnx ./
COPY src/OrdersApi/OrdersApi.csproj src/OrdersApi/packages.lock.json src/OrdersApi/
COPY tests/OrdersApi.Tests/OrdersApi.Tests.csproj tests/OrdersApi.Tests/packages.lock.json tests/OrdersApi.Tests/
# The token exists only as an env var of this RUN: never in a layer, the cache or the provenance.
RUN --mount=type=secret,id=nuget_token,env=NUGET_TOKEN,required=true \
    dotnet restore --locked-mode
COPY . .
ARG VERSION=0.0.0-dev
RUN dotnet build -c Release --no-restore -p:Version=${VERSION}

FROM build AS test
RUN dotnet test -c Release --no-build

FROM build AS publish
RUN dotnet publish src/OrdersApi -c Release --no-build -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled@sha256:48e51f2f6798897be7ac4e775c049ed8fe60d3190f637e1f9c9dc7513efa659c AS runtime
WORKDIR /app
COPY --from=publish /app .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "OrdersApi.dll"]
