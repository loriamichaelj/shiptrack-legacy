#!/usr/bin/env bash
# Runs INSIDE the amazonlinux:2023 container started by build_tarball.sh. Not for direct use.
# Usage: build_in_container.sh <release-sha>
set -euo pipefail

sha=${1:?usage: build_in_container.sh <release-sha>}
release="/opt/shiptrack/releases/$sha"

dnf install -y -q python3.12 python3.12-pip tar gzip findutils

# The virtualenv embeds absolute paths, so it is created at the exact path it will run from.
mkdir -p "$release"
python3.12 -m venv "$release/venv"
"$release/venv/bin/python" -m pip install --quiet --no-cache-dir --require-hashes \
  -r /stage/requirements.txt

# pip builds in-tree, so build from a writable copy of the read-only stage.
build_src=$(mktemp -d)
cp -R /stage/pyproject.toml /stage/requirements.in /stage/src "$build_src/"
"$release/venv/bin/python" -m pip install --quiet --no-cache-dir --no-deps --no-build-isolation \
  "$build_src"

cp -R /stage/alembic.ini /stage/migrations /stage/deploy /stage/scripts "$release/"
mkdir -p "$release/web"
cp -R /stage/web-dist "$release/web/dist"
find "$release" -name '__pycache__' -path '*/migrations/*' -prune -exec rm -rf {} +

# shellcheck disable=SC1091  # exists in the container, not on the machine running shellcheck
os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
{
  echo "sha=$sha"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "builder=${BUILDER:-unknown}"
  echo "base_image=$os_name"
  echo "python=$("$release/venv/bin/python" --version)"
} >"$release/RELEASE"

tar -C /opt/shiptrack/releases -czf "/out/shiptrack-$sha.tar.gz" "$sha"
(cd /out && sha256sum "shiptrack-$sha.tar.gz" >"shiptrack-$sha.tar.gz.sha256")
chown "${HOST_UID:-0}:${HOST_GID:-0}" "/out/shiptrack-$sha.tar.gz" "/out/shiptrack-$sha.tar.gz.sha256"
echo "built /out/shiptrack-$sha.tar.gz"
