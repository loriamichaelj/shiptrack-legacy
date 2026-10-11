#!/usr/bin/env bash
# Report on, remove, or restore the SLA scan cron on this host (run by ShipTrack-LegacyCron on one
# host at a time; cutover wave 3, ADR-0005).
# Usage: legacy_cron.sh <status|remove-sla|restore-sla>
#
#   status       print one line: sla=present|absent podsync=present|absent
#   remove-sla   remove /etc/cron.d/shiptrack-sla, so this host stops scanning (wave 3 step 1)
#   restore-sla  put the current release's deploy/cron/shiptrack-sla back (rollback before the
#                contract migration)
#
# The per-minute proof-of-delivery sync has its own action, ops-pod-sync.yml remove-cron.
# A host launched after the removal gets the SLA cron again from its launch template; the Auto
# Scaling group goes to 0 at the end of wave 3, so that window is short.
# Environment (for tests): LEGACY_CRON_DIR.
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

action=${1:?usage: legacy_cron.sh <status|remove-sla|restore-sla>}
cron_dir=${LEGACY_CRON_DIR:-/etc/cron.d}
sla_file="$cron_dir/shiptrack-sla"
podsync_file="$cron_dir/shiptrack-podsync"
packaged="$CURRENT_LINK/deploy/cron/shiptrack-sla"

present() { if [[ -f "$1" ]]; then echo present; else echo absent; fi; }

case "$action" in
  status) ;;
  remove-sla)
    rm -f "$sla_file"
    log "removed $sla_file"
    ;;
  restore-sla)
    [[ -f "$packaged" ]] || die "the current release has no deploy/cron/shiptrack-sla"
    mkdir -p "$cron_dir"
    install -m 0644 "$packaged" "$sla_file.new"
    mv -f "$sla_file.new" "$sla_file"
    log "restored $sla_file"
    ;;
  *)
    die "unknown action: $action"
    ;;
esac

# One line of words, no paths: safe to show in a public log.
echo "legacy cron sla=$(present "$sla_file") podsync=$(present "$podsync_file")"
