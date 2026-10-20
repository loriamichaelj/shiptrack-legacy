#!/usr/bin/env bash
# Exercise .github/scripts/terraform-destroy.sh against a fake `aws` and a fake `terraform`: the
# confirmation check, the order of the steps in each mode, and the guard that refuses to apply a plan
# that would create the bucket again. Needs jq. Nothing contacts AWS.
# Usage: tests/workflows/test_terraform_destroy.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/.github/scripts/terraform-destroy.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
ok() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }
not() { ! "$@"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "123456789012"
FAKE
cat >"$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
# Records each call; `show` prints a plan with one update, or one create when FAKE_CREATES is set.
printf '%s\n' "$*" >>"$FAKE_DIR/calls"
if [[ "$1" == show ]]; then
  action=update
  [[ -z "${FAKE_CREATES:-}" || "$3" != unprotect.tfplan ]] || action=create
  printf '{"resource_changes":[{"address":"aws_s3_bucket.artifacts","change":{"actions":["%s"]}}]}\n' "$action"
fi
FAKE
chmod +x "$work/bin/aws" "$work/bin/terraform"

run() { # run <mode> <confirm>: output in $work/out, calls in $work/calls
  : >"$work/calls"
  PATH="$work/bin:$PATH" FAKE_DIR="$work" AWS_REGION=us-east-1 CONFIRM="$2" \
    "$script" "$1" all >"$work/out" 2>&1
}

echo "terraform-destroy.sh"

status=0
run destroy nope || status=$?
check "a wrong confirmation fails" "$status" "1"
check "a wrong confirmation runs no terraform" "$(wc -l <"$work/calls" | tr -d ' ')" "0"

run plan all
check "plan: init, then a destroy plan, and no apply" \
  "$(grep -c '^init \|^plan -destroy ' "$work/calls") $(grep -c '^apply' "$work/calls")" "2 0"
ok "plan: the destroy plan sets the variable" grep -q -- '-var artifacts_force_destroy=true' "$work/calls"
ok "plan: no targeted plan" not grep -q -- '-target=aws_s3_bucket.artifacts' "$work/calls"

run destroy all
check "destroy: two applies" "$(grep -c '^apply' "$work/calls")" "2"
first=$(grep -n -- '-target=aws_s3_bucket.artifacts' "$work/calls" | head -1 | cut -d: -f1)
last=$(grep -n '^plan -destroy' "$work/calls" | head -1 | cut -d: -f1)
ok "destroy: the bucket is unprotected before the destroy plan" test "${first:-9}" -lt "${last:-0}"
ok "destroy: reports completion" grep -q 'Destroy complete' "$work/out"

FAKE_CREATES=1 run destroy all
check "destroy: a plan that would create the bucket is not applied (one apply, the destroy)" "$(grep -c '^apply' "$work/calls")" "1"
ok "destroy: says why it skipped" grep -q 'Not applying it' "$work/out"

ok "the account ID is masked, not printed" test "$(grep -v '^::add-mask::' "$work/out" | grep -c '123456789012' || true)" = 0

if ((failures > 0)); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all passed"
