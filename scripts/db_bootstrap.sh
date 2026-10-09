#!/usr/bin/env bash
# Create the ShipTrack database, its two login roles, and the schema by running the platform
# repository's db/bootstrap.sql from a legacy host (run by the ShipTrack-DbBootstrap SSM document).
#
# The platform design makes the first bootstrap a manual CloudShell step. A host already sits inside
# the VPC, may read the secrets, and has the network path to RDS, so this does the same work without
# CloudShell (ADR-0011). It is safe to run again: bootstrap.sql creates what is missing and resets the
# two role passwords to the values in Secrets Manager.
#
# The SQL is fetched from the public platform repository at a pinned commit and checked against a
# SHA-256 given by the caller. Passwords reach psql through a mode-0600 file and the environment, never
# through the command line, and are never printed.
#
# Usage: db_bootstrap.sh <platform-repo> <platform-sha> <sql-sha256> <master-secret-arn>
set -euo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

repo=${1:?usage: db_bootstrap.sh <platform-repo> <platform-sha> <sql-sha256> <master-secret-arn>}
sha=${2:?missing platform sha}
want=${3:?missing sql sha256}
master_arn=${4:?missing master secret arn}

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "invalid repository: $repo"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "the platform commit must be a full 40-character sha"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "the sql checksum must be 64 hex characters"

work=$(mktemp -d)
chmod 700 "$work"
cleanup() { rm -rf "$work"; unset PGPASSWORD; }
trap cleanup EXIT

# The region comes from the instance: the SSM agent does not set one for the aws CLI.
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  token=$(curl -sS --max-time 3 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
  AWS_DEFAULT_REGION=$(curl -sS --max-time 3 ${token:+-H "X-aws-ec2-metadata-token: $token"} \
    http://169.254.169.254/latest/meta-data/placement/region)
fi
export AWS_DEFAULT_REGION

# 1. A PostgreSQL client and jq. The 17 client matches the server; 16 also works for these commands.
if ! command -v psql >/dev/null 2>&1; then
  dnf install -y postgresql17 jq >/dev/null 2>&1 || dnf install -y postgresql16 jq >/dev/null 2>&1 \
    || die "could not install a PostgreSQL client"
fi
command -v jq >/dev/null 2>&1 || dnf install -y jq >/dev/null 2>&1 || die "jq is not available"
log "using $(psql --version)"

# 2. The RDS certificate bundle (the connection verifies the server) and the pinned SQL.
curl -fsSL --retry 3 -o "$work/rds-bundle.pem" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
curl -fsSL --retry 3 -o "$work/bootstrap.sql" "https://raw.githubusercontent.com/$repo/$sha/db/bootstrap.sql"
got=$(sha256sum "$work/bootstrap.sql" | awk '{print $1}')
[[ "$got" == "$want" ]] || die "bootstrap.sql does not match the expected checksum"
log "bootstrap.sql from commit ${sha:0:12} matches its checksum"

# 3. Credentials. The master user is used only here (design 6.4).
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
host=$(aws ssm get-parameter --name /shiptrack/platform/rds_endpoint --query Parameter.Value --output text)
master=$(secret "$master_arn")
master_user=$(jq -r .username <<<"$master")
PGPASSWORD=$(jq -r .password <<<"$master")
export PGPASSWORD
migrator_password=$(secret shiptrack/dev/db/migrator | jq -r .password)
app_password=$(secret shiptrack/dev/db/app | jq -r .password)
unset master

# 4. The two passwords go in as psql variables from a private file, ahead of the SQL, as -v would.
umask 077
{
  printf "\\\\set migrator_password '%s'\n" "$migrator_password"
  printf "\\\\set app_password '%s'\n" "$app_password"
  cat "$work/bootstrap.sql"
} >"$work/run.sql"
unset migrator_password app_password

export PGSSLROOTCERT="$work/rds-bundle.pem"
conn() { printf 'host=%s port=5432 dbname=%s user=%s sslmode=verify-full' "$host" "$1" "$master_user"; }

log "running bootstrap.sql"
psql -X -v ON_ERROR_STOP=1 -q -f "$work/run.sql" "$(conn postgres)" >/dev/null
log "bootstrap.sql finished"

# 5. Check the result without printing anything secret.
check() { psql -X -tA -v ON_ERROR_STOP=1 -c "$1" "$(conn shiptrack)"; }
roles=$(check "SELECT count(*) FROM pg_roles WHERE rolname IN ('shiptrack_migrator','shiptrack_app') AND rolcanlogin")
owner=$(check "SELECT schema_owner FROM information_schema.schemata WHERE schema_name = 'shiptrack'")
app_use=$(check "SELECT has_schema_privilege('shiptrack_app', 'shiptrack', 'USAGE')")
app_create=$(check "SELECT has_schema_privilege('shiptrack_app', 'shiptrack', 'CREATE')")
max_connections=$(check "SHOW max_connections")
log "login roles: $roles; schema owner: $owner; app can use / create: $app_use / $app_create; max_connections: $max_connections"
[[ "$roles" == 2 ]] || die "expected two login roles"
[[ "$owner" == shiptrack_migrator ]] || die "the shiptrack schema is not owned by shiptrack_migrator"
[[ "$app_use" == t && "$app_create" == f ]] || die "shiptrack_app should use the schema but not create in it"
echo "DB_BOOTSTRAPPED max_connections=$max_connections"
