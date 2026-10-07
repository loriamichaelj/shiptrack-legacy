#!/usr/bin/env bash
# Run the database migrations of a release (run by ShipTrack-Migrate on ONE host).
# Uses the credentials in /etc/shiptrack/app.ini.
# Usage: migrate.sh <release-sha> <artifact-bucket>
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

sha=${1:?usage: migrate.sh <release-sha> <artifact-bucket>}
bucket=${2:?usage: migrate.sh <release-sha> <artifact-bucket>}
require_sha "$sha"

# The release is extracted to its final path (the venv cannot be relocated) but not activated.
fetch_release "$sha" "$bucket"

cd "$RELEASES_DIR/$sha"
export SHIPTRACK_CONFIG="${SHIPTRACK_CONFIG:-/etc/shiptrack/app.ini}"
venv/bin/python -m alembic -c alembic.ini upgrade head
log "migrations are at head for release $sha"
