#!/usr/bin/env bash
# Roll this host back to the previous release, or to a given one (run by ShipTrack-Rollback).
# The database is NOT rolled back. The last line printed is ROLLED_BACK_TO=<sha>; the rollback
# workflow uses it to update /shiptrack/legacy/current_release, which instances cannot write.
# Usage: rollback.sh [release-sha]
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

target=${1:-}
current=$(current_sha)
if [[ -z "$target" ]]; then
  target=$(previous_release "$current")
fi
[[ -n "$target" ]] || die "there is no previous release to roll back to"
require_sha "$target"
[[ -d "$RELEASES_DIR/$target" ]] || die "release $target is no longer on this host"

activate_release "$target"
systemctl restart shiptrack
wait_for_health
log "rolled back from ${current:-none} to $target"
echo "ROLLED_BACK_TO=$target"
