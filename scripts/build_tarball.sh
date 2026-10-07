#!/usr/bin/env bash
# Build a release tarball: dist/shiptrack-<sha>.tar.gz and dist/shiptrack-<sha>.tar.gz.sha256.
#   1. the UI is built in a Node container pinned to the exact version in web/.nvmrc
#   2. the application is installed into a venv inside an amazonlinux:2023 container, so glibc
#      and Python match the hosts
# Usage: scripts/build_tarball.sh <release-sha>
set -euo pipefail

sha=${1:?usage: build_tarball.sh <release-sha>}
[[ "$sha" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid release sha: $sha" >&2; exit 1; }

NODE_IMAGE='node:24.19.0-bookworm-slim@sha256:a9f5f7c91a432850b2a8a7797adf5eadb6c733ceed61167806cee7ea7fbc29df'
AL2023_IMAGE='amazonlinux:2023@sha256:8ed3c0a996841537f75607e7d1de2114d8150391f75792e8da9268738547e73f'

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$repo/dist"
node_version=$(tr -d '[:space:]' <"$repo/web/.nvmrc")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$work/ui" "$work/stage"

# 1. UI, built from a clean copy so the host's node_modules (other platform) is never touched.
tar -C "$repo/web" --exclude=node_modules --exclude=dist -cf - . | tar -C "$work/ui" -xf -
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
  -v "$work/ui":/work -w /work "$NODE_IMAGE" bash -euc "
    [[ \"\$(node --version)\" == \"v${node_version}\" ]] || {
      echo \"Node \$(node --version) does not match web/.nvmrc (v${node_version})\" >&2; exit 1; }
    npm ci --no-audit --no-fund
    npm run build
    npm run check:dist
  "

# 2. Application, installed under /opt/shiptrack/releases/<sha> in an AL2023 container.
for path in pyproject.toml requirements.in requirements.txt alembic.ini src migrations deploy scripts; do
  tar -C "$repo" --exclude='__pycache__' --exclude='*.egg-info' -cf - "$path" | tar -C "$work/stage" -xf -
done
cp -R "$work/ui/dist" "$work/stage/web-dist"

docker run --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e BUILDER="${BUILDER:-$(whoami)}" \
  -v "$work/stage":/stage:ro -v "$out":/out \
  "$AL2023_IMAGE" bash /stage/scripts/build_in_container.sh "$sha"

echo "$out/shiptrack-$sha.tar.gz"
