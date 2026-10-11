#!/usr/bin/env bash
# Move this host's proof-of-delivery files to S3, or install or remove the per-minute sync that does
# it (run by ShipTrack-PodSync on one host at a time; release v1.1.0, design section 8).
# Usage: pod_sync.sh <dry-run|migrate|install-cron|remove-cron> <pod-bucket>
#
#   dry-run       count what would move and change nothing
#   migrate       move every file on this host once
#   install-cron  /etc/cron.d/shiptrack-podsync: every minute, under flock so runs never overlap
#   remove-cron   remove it (decommissioning, wave 3)
#
# The sync runs as the application user, because that user owns the files and can read app.ini.
# Environment (for tests): POD_SYNC_CRON_DIR, POD_SYNC_RUN_AS.
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

action=${1:?usage: pod_sync.sh <dry-run|migrate|install-cron|remove-cron> <pod-bucket>}
bucket=${2:?usage: pod_sync.sh <dry-run|migrate|install-cron|remove-cron> <pod-bucket>}
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "invalid bucket name: $bucket"

cron_dir=${POD_SYNC_CRON_DIR:-/etc/cron.d}
cron_file="$cron_dir/shiptrack-podsync"
run_as=${POD_SYNC_RUN_AS:-"runuser -u shiptrack --"}
python="$CURRENT_LINK/venv/bin/python"
job="$CURRENT_LINK/scripts/migrate_pod_to_s3.py"

require_release() {
  [[ -x "$python" && -f "$job" ]] \
    || die "the current release has no scripts/migrate_pod_to_s3.py: deploy release v1.1.0 first"
}

case "$action" in
  dry-run | migrate)
    require_release
    flags=()
    [[ "$action" == dry-run ]] && flags+=(--dry-run)
    export SHIPTRACK_CONFIG="${SHIPTRACK_CONFIG:-/etc/shiptrack/app.ini}"
    # shellcheck disable=SC2086  # run_as is a command and its arguments
    $run_as "$python" "$job" --bucket "$bucket" ${flags[@]+"${flags[@]}"}
    ;;
  install-cron)
    require_release
    mkdir -p "$cron_dir"
    cat >"$cron_file.new" <<CRON
# Release v1.1.0: moves proof-of-delivery files to S3 while the legacy and modern stacks both take
# traffic (design section 8). Removed when legacy is decommissioned.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * shiptrack /usr/bin/flock -n /var/lib/shiptrack/podsync.lock $python $job --bucket $bucket >> /var/log/shiptrack/podsync.log 2>&1
CRON
    chmod 0644 "$cron_file.new"
    mv -f "$cron_file.new" "$cron_file"
    log "installed $cron_file"
    ;;
  remove-cron)
    rm -f "$cron_file"
    log "removed $cron_file"
    ;;
  *)
    die "unknown action: $action"
    ;;
esac
