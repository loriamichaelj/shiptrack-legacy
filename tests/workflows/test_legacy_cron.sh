#!/usr/bin/env bash
# Exercise scripts/legacy_cron.sh against a fake host tree: each action, the line it prints, and the
# refusals. Nothing contacts AWS and nothing is installed on this machine.
# Usage: tests/workflows/test_legacy_cron.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/legacy_cron.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

root="$work/opt/shiptrack"
mkdir -p "$root/releases/v1.1.0/deploy/cron" "$work/cron.d"
ln -s releases/v1.1.0 "$root/current"
echo '*/5 * * * * shiptrack /opt/shiptrack/current/venv/bin/python -m shiptrack.jobs.sla_scan' \
  >"$root/releases/v1.1.0/deploy/cron/shiptrack-sla"
export SHIPTRACK_ROOT="$root" LEGACY_CRON_DIR="$work/cron.d"

check "status on a host with no cron files" "$("$script" status 2>/dev/null)" "legacy cron sla=absent podsync=absent"

check "restore-sla reports the file present" "$("$script" restore-sla 2>/dev/null | tail -1)" "legacy cron sla=present podsync=absent"
check "the restored file is the packaged one" "$(cmp -s "$work/cron.d/shiptrack-sla" "$root/releases/v1.1.0/deploy/cron/shiptrack-sla" && echo same || echo different)" "same"
mode=$(stat -c '%a' "$work/cron.d/shiptrack-sla" 2>/dev/null || stat -f '%Lp' "$work/cron.d/shiptrack-sla")
check "the restored file is mode 0644" "$mode" "644"

: >"$work/cron.d/shiptrack-podsync"
check "status sees both files" "$("$script" status 2>/dev/null)" "legacy cron sla=present podsync=present"

check "remove-sla removes only the SLA cron" "$("$script" remove-sla 2>/dev/null | tail -1)" "legacy cron sla=absent podsync=present"
"$script" remove-sla >/dev/null 2>&1
check "removing when it is absent is not an error" "$?" "0"

rm "$root/releases/v1.1.0/deploy/cron/shiptrack-sla"
out=$("$script" restore-sla 2>&1)
check "restore without a packaged file is refused" "$?" "1"
check "the message names the missing file" "$(grep -c 'no deploy/cron/shiptrack-sla' <<<"$out")" "1"

"$script" explode >/dev/null 2>&1
check "an unknown action is refused" "$?" "1"

if ((failures > 0)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
