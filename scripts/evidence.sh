#!/usr/bin/env bash
# Run one allow-listed, read-only evidence check on this host (run by ShipTrack-Evidence on ONE host).
# It uses the release's virtualenv and the credentials in /etc/shiptrack/app.ini, because the
# database is private and a runner cannot reach it.
# Usage: evidence.sh <pod-gate|sla-duplicates|ledger-verify> <artifact-bucket> [ledger-key] [wheel-key]
#
# Every check prints a single line of numbers and nothing else (shiptrack.jobs.evidence). The
# document passes the keys through an allowed pattern, and they are checked again here.
# Environment (for tests): EVIDENCE_RUN_AS.
set -euo pipefail
if [[ -z "${SHIPTRACK_LIB_LOADED:-}" ]]; then
  # shellcheck source=scripts/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fi

check=${1:?usage: evidence.sh <pod-gate|sla-duplicates|ledger-verify> <artifact-bucket> [ledger-key] [wheel-key]}
bucket=${2:?usage: evidence.sh <check> <artifact-bucket> [ledger-key] [wheel-key]}
ledger_key=${3:-none}
wheel_key=${4:-none}

[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "invalid bucket name: $bucket"
run_as=${EVIDENCE_RUN_AS:-"runuser -u shiptrack --"}
python="$CURRENT_LINK/venv/bin/python"
[[ -x "$python" ]] || die "there is no current release on this host"
export SHIPTRACK_CONFIG="${SHIPTRACK_CONFIG:-/etc/shiptrack/app.ini}"

case "$check" in
  pod-gate | sla-duplicates)
    # shellcheck disable=SC2086  # run_as is a command and its arguments
    $run_as "$python" -m shiptrack.jobs.evidence "$check"
    ;;
  ledger-verify)
    [[ "$ledger_key" =~ ^simulator/sent-[A-Za-z0-9._-]+\.jsonl$ ]] || die "invalid ledger key"
    [[ "$wheel_key" =~ ^evidence/shiptrack_simulator-[A-Za-z0-9._+-]+\.whl$ ]] || die "invalid simulator key"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    aws s3 cp --only-show-errors "s3://$bucket/$ledger_key" "$work/ledger.jsonl"
    aws s3 cp --only-show-errors "s3://$bucket/$wheel_key" "$work/simulator.whl"
    # A wheel is a zip: unpack it, so nothing is installed into the release's virtualenv.
    "$python" -m zipfile -e "$work/simulator.whl" "$work/simulator"
    chown -R shiptrack:shiptrack "$work" 2>/dev/null || true
    # shellcheck disable=SC2086
    $run_as "$python" -m shiptrack.jobs.evidence ledger-verify \
      --ledger "$work/ledger.jsonl" --simulator "$work/simulator"
    ;;
  *)
    die "unknown check: $check"
    ;;
esac
