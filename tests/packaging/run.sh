#!/usr/bin/env bash
# Install the release tarball on a fresh amazonlinux:2023 container and exercise deploy, nginx,
# rollback, and pruning the way the hosts will. Needs Docker and the Postgres from `make up`
# (set PYTHON to a Python with psycopg installed; the default is the repo's .venv).
# Usage: tests/packaging/run.sh [release-sha]      (set SKIP_BUILD=1 to reuse dist/)
set -euo pipefail

sha=${1:-pkgtest}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AL2023_IMAGE='amazonlinux:2023@sha256:8ed3c0a996841537f75607e7d1de2114d8150391f75792e8da9268738547e73f'
pg_host=${PG_HOST:-host.docker.internal}

if [[ -z "${SKIP_BUILD:-}" ]]; then
  "$repo/scripts/build_tarball.sh" "$sha"
fi

# Fresh database for the run, created from the host (Postgres from `make up` or a CI service).
python=${PYTHON:-$repo/.venv/bin/python}
"$python" - <<'PY'
import psycopg

with psycopg.connect(host="localhost", user="postgres", password="postgres", autocommit=True) as conn:
    conn.execute("DROP DATABASE IF EXISTS shiptrack_pkg WITH (FORCE)")
    conn.execute("CREATE DATABASE shiptrack_pkg")
PY

docker run --rm --add-host host.docker.internal:host-gateway \
  -e RELEASE_SHA="$sha" -e PG_HOST="$pg_host" \
  -v "$repo/dist":/artifacts:ro -v "$repo/tests/packaging":/pkgtest:ro \
  "$AL2023_IMAGE" bash /pkgtest/in_container.sh
