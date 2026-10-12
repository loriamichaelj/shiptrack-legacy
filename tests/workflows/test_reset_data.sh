#!/usr/bin/env bash
# Exercise scripts/reset_data.sh against a fake release, a fake job, and a fake aws: the order of
# the steps, what it refuses, and what it removes. Nothing contacts AWS and nothing is deleted on
# this machine outside a temporary directory.
# Usage: tests/workflows/test_reset_data.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/reset_data.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

root="$work/opt/shiptrack"
mkdir -p "$root/releases/v1.1.0/venv/bin" "$work/bin" "$work/pod/aa/bb"
ln -s releases/v1.1.0 "$root/current"
export CALLS="$work/calls"
cat >"$root/releases/v1.1.0/venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "python $*" >>"$CALLS"
echo "RESET_DATA deleted shipments=3 tracking_events=9 pod_documents=2 sla_alerts=1"
[[ -n "${FAKE_JOB_FAILS:-}" ]] && exit 1
exit 0
PY
chmod +x "$root/releases/v1.1.0/venv/bin/python"
cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "s3 ls") printf '2026-10-11 10:00:00 12 pod/a/b\n2026-10-11 10:00:01 12 pod/a/c\n' ;;
esac
exit 0
AWS
chmod +x "$work/bin/aws"
: >"$work/job.py"
echo x >"$work/pod/aa/bb/one"
echo y >"$work/pod/aa/two"

export PATH="$work/bin:$PATH" SHIPTRACK_ROOT="$root" RESET_DATA_RUN_AS=env RESET_DATA_PY="$work/job.py" POD_DIR="$work/pod"
: >"$CALLS"

out=$("$script" delete-all-shipments shiptrack-pod-test yes 2>&1)
check "a full run succeeds" "$?" "0"
check "the job gets the confirmation and the seed flag" "$(grep -c 'job.py --confirm delete-all-shipments --seed yes' "$CALLS")" "1"
check "it removes the objects under pod/ in the bucket" "$(grep -c 'aws s3 rm s3://shiptrack-pod-test/pod/ --recursive' "$CALLS")" "1"
check "it counts the objects it removes" "$(grep -c '^RESET_DATA s3_objects_removed=2$' <<<"$out")" "1"
check "it removes this host's local files" "$(grep -c '^RESET_DATA local_files_removed=2$' <<<"$out")" "1"
check "the local directory is empty and still there" "$(find "$work/pod" -mindepth 1 | wc -l | tr -d ' ') $([[ -d "$work/pod" ]] && echo dir)" "0 dir"
check "the database step comes before the S3 and file steps" \
  "$(grep -n -E 'job.py|s3 rm' "$CALLS" | head -1 | grep -c job.py)" "1"

# a failing job stops everything after it
echo x >"$work/pod/keep"
: >"$CALLS"
FAKE_JOB_FAILS=1 "$script" delete-all-shipments shiptrack-pod-test no >/dev/null 2>&1
check "a failing database step is an error" "$?" "1"
check "...and nothing is removed from S3" "$(grep -c 's3 rm' "$CALLS")" "0"
check "...or from the host" "$([[ -f "$work/pod/keep" ]] && echo kept)" "kept"

: >"$CALLS"
"$script" yes shiptrack-pod-test yes >/dev/null 2>&1
check "a wrong confirmation is refused" "$?" "1"
"$script" delete-all-shipments 'bad bucket;rm -rf /' yes >/dev/null 2>&1
check "a bucket name with shell characters is refused" "$?" "1"
"$script" delete-all-shipments shiptrack-pod-test maybe >/dev/null 2>&1
check "a seed value other than yes or no is refused" "$?" "1"
check "none of the refusals reached the job" "$(grep -c 'job.py' "$CALLS")" "0"

rm "$work/job.py"
"$script" delete-all-shipments shiptrack-pod-test yes >/dev/null 2>&1
check "a missing job file is an error" "$?" "1"

if ((failures > 0)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
