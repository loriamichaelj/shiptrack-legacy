#!/usr/bin/env bash
# Exercise scripts/db_bootstrap.sh against fake aws, curl, psql, and dnf: the checksum gate, that the
# passwords reach psql in a private file and not on a command line, the post-run checks, and cleanup.
# Needs jq. Nothing contacts AWS or the network.
# Usage: tests/workflows/test_db_bootstrap.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/db_bootstrap.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin" "$work/tmp"
printf -- '-- fake bootstrap.sql\nSELECT 1;\n' >"$work/bootstrap.sql"
good=$(sha256sum "$work/bootstrap.sql" | awk '{print $1}')

cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "ssm get-parameter") echo "db.example.test" ;;
  "secretsmanager get-secret-value")
    while [[ $# -gt 0 ]]; do [[ "$1" == --secret-id ]] && id=$2; shift; done
    case "$id" in
      arn:aws:secretsmanager:*) echo '{"username":"master_user","password":"MASTERPW123"}' ;;  # gitleaks:allow
      shiptrack/dev/db/migrator) echo '{"username":"shiptrack_migrator","password":"MIGRATORPW456"}' ;;  # gitleaks:allow
      shiptrack/dev/db/app) echo '{"username":"shiptrack_app","password":"APPPW789"}' ;;  # gitleaks:allow
      *) exit 1 ;;
    esac ;;
  *) echo "fake aws: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out=$2; shift ;; http*) url=$1 ;; esac
  shift
done
case "$url" in
  *raw.githubusercontent.com*) cp "$FAKE_SQL" "$out"; echo "$url" >>"$FAKE_DIR/urls" ;;
  *truststore.pki.rds.amazonaws.com*) echo "pem" >"$out" ;;
  *169.254.169.254*) echo us-east-1 ;;
  *) exit 22 ;;
esac
FAKE
cat >"$work/bin/dnf" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat >"$work/bin/psql" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == --version ]] && { echo "psql (PostgreSQL) 17.0"; exit 0; }
# Record how psql was called and what it was given.
echo "$*" >>"$FAKE_DIR/psql-args"
printf 'PGPASSWORD=%s PGSSLROOTCERT=%s\n' "${PGPASSWORD:-}" "${PGSSLROOTCERT:-}" >>"$FAKE_DIR/psql-env"
all="$*"
file=""
while [[ $# -gt 0 ]]; do [[ "$1" == -f ]] && file=$2; shift; done
if [[ -n "$file" ]]; then
  cp "$file" "$FAKE_DIR/run.sql"
  stat -f '%Lp' "$file" >"$FAKE_DIR/run.sql.mode" 2>/dev/null || stat -c '%a' "$file" >"$FAKE_DIR/run.sql.mode"
  [[ "${FAKE_PSQL_FAIL:-}" == 1 ]] && { echo "ERROR: boom" >&2; exit 3; }
  exit 0
fi
case "$all" in
  *"count(*) FROM pg_roles"*) echo "${FAKE_ROLES:-2}" ;;
  *schema_owner*) echo "${FAKE_OWNER:-shiptrack_migrator}" ;;
  *"'CREATE'"*) echo "${FAKE_APP_CREATE:-f}" ;;
  *"'USAGE'"*) echo "t" ;;
  *"SHOW max_connections"*) echo 400 ;;
  *) exit 99 ;;
esac
FAKE
chmod +x "$work/bin/"*

run() { # run <env...> -- <args...>
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  rm -rf "$work/d" "$work/tmp"/*
  mkdir -p "$work/d"
  env PATH="$work/bin:$PATH" TMPDIR="$work/tmp" FAKE_DIR="$work/d" FAKE_SQL="$work/bootstrap.sql" ${envs[@]+"${envs[@]}"} \
    "$script" "$@" 2>&1
}
sha=0123456789abcdef0123456789abcdef01234567
arn='arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-00000000-0000-0000-0000-00000000000a-AbCdEf'

echo "== a clean run"
out=$(run -- owner/platform "$sha" "$good" "$arn") && rc=0 || rc=$?
check "exit code" "$rc" "0"
check "reports success and max_connections" "$(grep -c 'DB_BOOTSTRAPPED max_connections=400' <<<"$out")" "1"
check "fetched the pinned commit" "$(grep -c "owner/platform/$sha/db/bootstrap.sql" "$work/d/urls")" "1"
check "the master password is in the environment of every psql call" "$(grep -c 'PGPASSWORD=MASTERPW123' "$work/d/psql-env")" "6"
check "no password is on any psql command line" "$(grep -cE 'MASTERPW123|MIGRATORPW456|APPPW789' "$work/d/psql-args")" "0"
check "no password appears in the output" "$(grep -cE 'MASTERPW123|MIGRATORPW456|APPPW789' <<<"$out")" "0"
check "the variables are set ahead of the SQL" "$(sed -n '1p' "$work/d/run.sql")" "\\set migrator_password 'MIGRATORPW456'"
check "both passwords are set" "$(sed -n '2p' "$work/d/run.sql")" "\\set app_password 'APPPW789'"
check "the SQL follows unchanged" "$(sed -n '3,$p' "$work/d/run.sql" | cat)" "$(cat "$work/bootstrap.sql")"
check "the private file is mode 600" "$(cat "$work/d/run.sql.mode")" "600"
check "the connection verifies the server" "$(grep -c 'sslmode=verify-full' "$work/d/psql-args")" "6"
check "temporary files are removed" "$(find "$work/tmp" -type f | wc -l | tr -d ' ')" "0"

echo "== a wrong checksum stops before psql runs"
out=$(run -- owner/platform "$sha" "$(printf '0%.0s' $(seq 1 64))" "$arn") && rc=0 || rc=$?
check "exit code" "$rc" "1"
check "says why" "$(grep -c 'does not match the expected checksum' <<<"$out")" "1"
check "psql never ran" "$([[ -e "$work/d/psql-args" ]] && echo yes || echo no)" "no"

echo "== a failing psql fails the run and still cleans up"
out=$(run FAKE_PSQL_FAIL=1 -- owner/platform "$sha" "$good" "$arn") && rc=0 || rc=$?
check "exit code" "$rc" "3"
check "temporary files are removed" "$(find "$work/tmp" -type f | wc -l | tr -d ' ')" "0"

echo "== the checks catch a wrong result"
out=$(run FAKE_OWNER=postgres -- owner/platform "$sha" "$good" "$arn") && rc=0 || rc=$?
check "a wrong schema owner fails" "$rc" "1"
out=$(run FAKE_APP_CREATE=t -- owner/platform "$sha" "$good" "$arn") && rc=0 || rc=$?
check "an app role that can create fails" "$rc" "1"
out=$(run FAKE_ROLES=1 -- owner/platform "$sha" "$good" "$arn") && rc=0 || rc=$?
check "a missing login role fails" "$rc" "1"

echo "== bad arguments are refused"
run -- 'owner/platform;rm' "$sha" "$good" "$arn" >/dev/null && rc=0 || rc=$?
check "a malformed repository" "$rc" "1"
run -- owner/platform abc123 "$good" "$arn" >/dev/null && rc=0 || rc=$?
check "a short commit sha" "$rc" "1"
run -- owner/platform "$sha" abc "$arn" >/dev/null && rc=0 || rc=$?
check "a short checksum" "$rc" "1"

echo
if [[ "$failures" -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
