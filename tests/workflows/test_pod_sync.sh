#!/usr/bin/env bash
# Exercise scripts/pod_sync.sh against a fake release tree: each action, the arguments the job gets,
# the cron line, and the refusals. Nothing contacts AWS and nothing is installed on this machine.
# Usage: tests/workflows/test_pod_sync.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/pod_sync.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

root="$work/opt/shiptrack"
mkdir -p "$root/releases/v1.1.0/venv/bin" "$root/releases/v1.1.0/scripts" "$work/cron.d"
ln -s releases/v1.1.0 "$root/current"
cat >"$root/releases/v1.1.0/venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "python $*" >>"$CALLS"
PY
chmod +x "$root/releases/v1.1.0/venv/bin/python"
: >"$root/releases/v1.1.0/scripts/migrate_pod_to_s3.py"

export SHIPTRACK_ROOT="$root" POD_SYNC_CRON_DIR="$work/cron.d" POD_SYNC_RUN_AS="env" CALLS="$work/calls"
: >"$CALLS"

"$script" dry-run shiptrack-pod-test >/dev/null 2>&1
check "dry-run passes --dry-run and the bucket to the job" "$(tail -1 "$CALLS" | sed "s#$root#ROOT#g")" \
  "python ROOT/current/scripts/migrate_pod_to_s3.py --bucket shiptrack-pod-test --dry-run"

: >"$CALLS"
"$script" migrate shiptrack-pod-test >/dev/null 2>&1
check "migrate runs the job without --dry-run" "$(tail -1 "$CALLS" | sed "s#$root#ROOT#g")" \
  "python ROOT/current/scripts/migrate_pod_to_s3.py --bucket shiptrack-pod-test"

"$script" install-cron shiptrack-pod-test >/dev/null 2>&1
cron="$work/cron.d/shiptrack-podsync"
check "install-cron writes the cron file" "$([[ -f "$cron" ]] && echo yes || echo no)" "yes"
check "the cron line runs every minute as shiptrack under flock -n" \
  "$(grep -c '^\* \* \* \* \* shiptrack /usr/bin/flock -n /var/lib/shiptrack/podsync.lock ' "$cron")" "1"
check "the cron line names the bucket" "$(grep -c -- '--bucket shiptrack-pod-test' "$cron")" "1"
# GNU stat first: on Linux `stat -f` is "filesystem status" and exits 0, so it cannot be the fallback.
mode=$(stat -c '%a' "$cron" 2>/dev/null || stat -f '%Lp' "$cron")
check "the cron file is mode 0644" "$mode" "644"

"$script" install-cron shiptrack-pod-test >/dev/null 2>&1
check "installing twice leaves one cron line" "$(grep -c '^\* \* \* \* \* ' "$cron")" "1"

"$script" remove-cron shiptrack-pod-test >/dev/null 2>&1
check "remove-cron removes the file" "$([[ -f "$cron" ]] && echo yes || echo no)" "no"
"$script" remove-cron shiptrack-pod-test >/dev/null 2>&1
check "removing when it is absent is not an error" "$?" "0"

"$script" migrate 'bad bucket;rm -rf /' >/dev/null 2>&1
check "a bucket name with shell characters is refused" "$?" "1"

"$script" explode shiptrack-pod-test >/dev/null 2>&1
check "an unknown action is refused" "$?" "1"

rm "$root/releases/v1.1.0/scripts/migrate_pod_to_s3.py"
out=$("$script" migrate shiptrack-pod-test 2>&1)
check "a release without the job is refused with a clear message" "$?" "1"
check "the message says to deploy v1.1.0" "$(grep -c 'deploy release v1.1.0 first' <<<"$out")" "1"

if ((failures > 0)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
