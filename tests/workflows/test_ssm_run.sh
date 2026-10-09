#!/usr/bin/env bash
# Exercise .github/scripts/ssm-run.sh against a fake `aws`: success, a failing host, a command that
# is still running at first, a timeout, and the masking of identifiers in a failure's output.
# Needs jq. Nothing contacts AWS.
# Usage: tests/workflows/test_ssm_run.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/.github/scripts/ssm-run.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
# Scenario files in $FAKE_DIR: statuses (one line per poll, the last repeats), hosts, outputs/<instance>.
all="$*"
case "$1 $2" in
  "ssm send-command")
    printf '%s\n' "$all" >"$FAKE_DIR/send-command-args"
    echo "cmd-1"
    ;;
  "ssm list-command-invocations")
    if [[ "$all" == *InstanceId* ]]; then
      cat "$FAKE_DIR/hosts"
    else
      n=$(cat "$FAKE_DIR/poll" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" >"$FAKE_DIR/poll"
      total=$(wc -l <"$FAKE_DIR/statuses")
      line=$((n > total ? total : n))
      sed -n "${line}p" "$FAKE_DIR/statuses"
    fi
    ;;
  "ssm get-command-invocation")
    instance=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--instance-id" ]]; then instance=$2; fi
      shift
    done
    cat "$FAKE_DIR/outputs/$instance.json"
    ;;
  *) echo "fake aws: unexpected call: $all" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work/bin/aws"

new_scenario() {
  export FAKE_DIR="$work/scenario-$1"
  mkdir -p "$FAKE_DIR/outputs"
  rm -f "$FAKE_DIR/poll"
}
host_output() { # host_output <instance> <status> <stdout> <stderr>
  jq -n --arg s "$2" --arg o "$3" --arg e "$4" '{Status:$s,StandardOutputContent:$o,StandardErrorContent:$e}' \
    >"$FAKE_DIR/outputs/$1.json"
}
# shellcheck disable=SC2119,SC2120  # extra arguments are never needed
run() { PATH="$work/bin:$PATH" DOCUMENT=ShipTrack-Deploy PARAMETERS='{"releaseSha":["abc123"]}' SLEEP=0 "$script" "$@"; }

echo "== every host succeeds"
new_scenario ok
printf 'Success Success\n' >"$FAKE_DIR/statuses"
printf 'i-0123456789abcdef0\ti-0fedcba9876543210\n' >"$FAKE_DIR/hosts"
host_output i-0123456789abcdef0 Success "ROLLED_BACK_TO=abc123" ""
host_output i-0fedcba9876543210 Success "ROLLED_BACK_TO=abc123" ""
out=$(OUTPUT_FILE="$work/out.txt" run 2>&1) && rc=0 || rc=$?
check "exit code" "$rc" "0"
check "summary line" "$(grep -c '2 of 2 hosts succeeded' <<<"$out")" "1"
check "stdout is handed to the caller" "$(grep -c 'ROLLED_BACK_TO=abc123' "$work/out.txt")" "2"
check "targets the Stack=legacy tag by default" "$(grep -c 'Key=tag:Stack,Values=legacy' "$FAKE_DIR/send-command-args")" "1"
check "one host at a time, no errors tolerated" "$(grep -cE 'max-concurrency 1 --max-errors 0' "$FAKE_DIR/send-command-args")" "1"

echo "== a named instance"
new_scenario one
printf 'Success\n' >"$FAKE_DIR/statuses"
printf 'i-0123456789abcdef0\n' >"$FAKE_DIR/hosts"
host_output i-0123456789abcdef0 Success "" ""
INSTANCE_ID=i-0123456789abcdef0 run >/dev/null 2>&1 && rc=0 || rc=$?
check "exit code" "$rc" "0"
check "targets the instance, not the tag" "$(grep -c -- '--instance-ids i-0123456789abcdef0' "$FAKE_DIR/send-command-args")" "1"

echo "== a command still running at first"
new_scenario slow
printf 'InProgress\nSuccess\n' >"$FAKE_DIR/statuses"
printf 'i-0123456789abcdef0\n' >"$FAKE_DIR/hosts"
host_output i-0123456789abcdef0 Success "" ""
run >/dev/null 2>&1 && rc=0 || rc=$?
check "waits, then succeeds" "$rc" "0"
check "polled more than once" "$([[ "$(cat "$FAKE_DIR/poll")" -ge 2 ]] && echo yes || echo no)" "yes"

echo "== one host fails"
new_scenario bad
printf 'Success Failed\n' >"$FAKE_DIR/statuses"
printf 'i-0123456789abcdef0\ti-0fedcba9876543210\n' >"$FAKE_DIR/hosts"
host_output i-0123456789abcdef0 Success "fine" ""
host_output i-0fedcba9876543210 Failed \
  "2026-10-09T10:00:00Z fetched s3://shiptrack-legacy-artifacts-123456789012-us-east-1/releases/x from i-0fedcba9876543210 (ip-10-40-16-7) at 10.40.16.7 via arn:aws:iam::123456789012:role/some-role https://s3.us-east-1.amazonaws.com/x" \
  "ERROR: checksum mismatch"
err=$(run 2>&1 >/dev/null) && rc=0 || rc=$?
check "exit code" "$rc" "1"
check "the failure text is shown" "$(grep -c 'checksum mismatch' <<<"$err")" "1"
check "account ID is masked" "$(grep -c '123456789012' <<<"$err")" "0"
check "instance ID is masked" "$(grep -c 'i-0fedcba9876543210' <<<"$err")" "0"
check "private address is masked" "$(grep -c '10\.40\.16\.7' <<<"$err")" "0"
check "ARN is masked" "$(grep -c 'arn:aws:iam' <<<"$err")" "0"
check "the successful host's output is not printed" "$(grep -c 'fine' <<<"$err")" "0"

echo "== a timeout"
new_scenario timeout
printf 'InProgress\n' >"$FAKE_DIR/statuses"
printf 'i-0123456789abcdef0\n' >"$FAKE_DIR/hosts"
TIMEOUT_SECONDS=1 run >/dev/null 2>&1 && rc=0 || rc=$?
check "gives up with an error" "$rc" "1"

echo
if [[ "$failures" -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
