#!/usr/bin/env bash
# Exercise scripts/evidence.sh against a fake release and a fake aws: each check, what it passes to
# the module, the validation of the keys, and that a failing check's exit code is kept.
# Nothing contacts AWS. Usage: tests/workflows/test_evidence.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/evidence.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

root="$work/opt/shiptrack"
mkdir -p "$root/releases/v1.1.0/venv/bin" "$work/bin"
ln -s releases/v1.1.0 "$root/current"
# A fake interpreter: `-m zipfile -e` makes the directory, anything else records its arguments.
cat >"$root/releases/v1.1.0/venv/bin/python" <<'PY'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "-m zipfile -e" ]]; then mkdir -p "$5"; exit 0; fi
echo "python $*" >>"$CALLS"
exit "${FAKE_EXIT:-0}"
PY
chmod +x "$root/releases/v1.1.0/venv/bin/python"
cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
: >"${@: -1}"
AWS
chmod +x "$work/bin/aws"

export PATH="$work/bin:$PATH" SHIPTRACK_ROOT="$root" EVIDENCE_RUN_AS="env" CALLS="$work/calls"
: >"$CALLS"

"$script" pod-gate shiptrack-artifacts-test >/dev/null 2>&1
check "pod-gate runs the module's pod-gate check" "$(tail -1 "$CALLS")" "python -m shiptrack.jobs.evidence pod-gate"

: >"$CALLS"
"$script" sla-duplicates shiptrack-artifacts-test >/dev/null 2>&1
check "sla-duplicates runs the module's sla-duplicates check" "$(tail -1 "$CALLS")" "python -m shiptrack.jobs.evidence sla-duplicates"

: >"$CALLS"
FAKE_EXIT=1 "$script" pod-gate shiptrack-artifacts-test >/dev/null 2>&1
check "a failing gate keeps its exit code" "$?" "1"

: >"$CALLS"
"$script" ledger-verify shiptrack-artifacts-test simulator/sent-20261011T120000Z.jsonl evidence/shiptrack_simulator-0.1.0-py3-none-any.whl >/dev/null 2>&1
check "ledger-verify downloads the ledger and the wheel" "$(grep -c '^aws s3 cp' "$CALLS")" "2"
check "ledger-verify passes the ledger and the unpacked simulator" \
  "$(grep -c -- 'shiptrack.jobs.evidence ledger-verify --ledger .*/ledger.jsonl --simulator .*/simulator' "$CALLS")" "1"

"$script" ledger-verify shiptrack-artifacts-test '../etc/passwd' evidence/shiptrack_simulator-0.1.0-py3-none-any.whl >/dev/null 2>&1
check "a ledger key outside simulator/ is refused" "$?" "1"
"$script" ledger-verify shiptrack-artifacts-test simulator/sent-1.jsonl 'evidence/x;rm -rf /.whl' >/dev/null 2>&1
check "a wheel key with shell characters is refused" "$?" "1"
"$script" delete-everything shiptrack-artifacts-test >/dev/null 2>&1
check "a check outside the allow-list is refused" "$?" "1"
"$script" pod-gate 'bad;bucket' >/dev/null 2>&1
check "a bucket name with shell characters is refused" "$?" "1"

if ((failures > 0)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
