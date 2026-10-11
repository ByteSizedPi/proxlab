#!/usr/bin/env bash
# Builds the plugin in a .NET 10 SDK container (no SDK needed on the host).
# Output: dist/Jellyfin.Plugin.RatingDistribution.dll and dist/meta.json
set -euo pipefail
cd "$(dirname "$0")"
podman run --rm -v "$PWD":/work:Z -w /work/src/Jellyfin.Plugin.RatingDistribution \
  -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
  mcr.microsoft.com/dotnet/sdk:10.0 \
  dotnet publish -c Release -o /work/dist/build --nologo
mkdir -p dist
cp dist/build/Jellyfin.Plugin.RatingDistribution.dll dist/
cp meta.json dist/
echo "Built: $(ls -l dist/Jellyfin.Plugin.RatingDistribution.dll)"
