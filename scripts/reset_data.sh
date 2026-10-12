#!/usr/bin/env bash
# Delete every shipment and its proof-of-delivery files, and optionally seed five demo shipments
# (run by ShipTrack-ResetData on each host in turn; ADR-0013).
# Usage: reset_data.sh <delete-all-shipments> <pod-bucket> <yes|no>
#
# In this order, so that a failure leaves the database and the files agreeing as far as possible:
#   1. the database, in one transaction (scripts/reset_data.py, which the document writes to
#      $RESET_DATA_PY);
#   2. the objects under pod/ in the proof-of-delivery bucket (all hosts see the same bucket, so a
#      second host finds none);
#   3. the files in this host's local proof-of-delivery directory.
#
# Stop the live traffic and let the events queue drain first: an event for a shipment that is gone
# fails to apply, is retried, and ends in the dead-letter queue, which alarms.
# Environment (for tests): RESET_DATA_RUN_AS, RESET_DATA_PY, POD_DIR.
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

confirm=${1:?usage: reset_data.sh <delete-all-shipments> <pod-bucket> <yes|no>}
bucket=${2:?usage: reset_data.sh <delete-all-shipments> <pod-bucket> <yes|no>}
seed=${3:?usage: reset_data.sh <delete-all-shipments> <pod-bucket> <yes|no>}

[[ "$confirm" == delete-all-shipments ]] || die "refused: the first argument must be delete-all-shipments"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "invalid bucket name: $bucket"
[[ "$seed" == yes || "$seed" == no ]] || die "the third argument must be yes or no"

run_as=${RESET_DATA_RUN_AS:-"runuser -u shiptrack --"}
python="$CURRENT_LINK/venv/bin/python"
job=${RESET_DATA_PY:-/tmp/shiptrack-reset-data.py}
pod_dir=${POD_DIR:-/var/lib/shiptrack/pod}
[[ -x "$python" ]] || die "there is no current release on this host"
[[ -f "$job" ]] || die "the reset job is missing: $job"
export SHIPTRACK_CONFIG="${SHIPTRACK_CONFIG:-/etc/shiptrack/app.ini}"

# 1. the database
# shellcheck disable=SC2086  # run_as is a command and its arguments
$run_as "$python" "$job" --confirm delete-all-shipments --seed "$seed"

# 2. the documents in S3 (nothing in the database points at them any more)
objects=$(aws s3 ls "s3://$bucket/pod/" --recursive 2>/dev/null | wc -l | tr -d ' ')
if [[ "$objects" -gt 0 ]]; then
  aws s3 rm "s3://$bucket/pod/" --recursive --only-show-errors
fi
echo "RESET_DATA s3_objects_removed=$objects"

# 3. the files this host still holds
local_files=0
if [[ -d "$pod_dir" ]]; then
  local_files=$(find "$pod_dir" -type f | wc -l | tr -d ' ')
  find "$pod_dir" -mindepth 1 -delete
fi
echo "RESET_DATA local_files_removed=$local_files"
