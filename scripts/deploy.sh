#!/usr/bin/env bash
# Deploy a release on this host (run by the ShipTrack-Deploy SSM document, one host at a time).
# Usage: deploy.sh <release-sha> <artifact-bucket>
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

sha=${1:?usage: deploy.sh <release-sha> <artifact-bucket>}
bucket=${2:?usage: deploy.sh <release-sha> <artifact-bucket>}
require_sha "$sha"

fetch_release "$sha" "$bucket"
activate_release "$sha"

# LEGACY AP-12: restart in place without deregistering from the target group. Requests in
# flight while the service restarts can fail, which shows up as ALB 502s during every deploy.
systemctl restart shiptrack
wait_for_health

echo "$sha" >>"$HISTORY_FILE"
prune_releases 5
log "deployed release $sha"
