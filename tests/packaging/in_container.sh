#!/usr/bin/env bash
# Runs INSIDE the amazonlinux:2023 container started by run.sh.
set -uo pipefail

SHA=${RELEASE_SHA:?}
PG_HOST=${PG_HOST:?}
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
section() { printf '\n== %s\n' "$1"; }

# check <description> <command...>: passes when the command exits 0.
check() { local d=$1; shift; if "$@" >/tmp/check.out 2>&1; then pass "$d"; else fail "$d"; sed 's/^/        /' /tmp/check.out | head -n 15; fi; }
# check_fails <description> <command...>: passes when the command exits non-zero.
check_fails() { local d=$1; shift; if "$@" >/tmp/check.out 2>&1; then fail "$d (expected failure)"; else pass "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: [$3] not found in [${2:0:300}]"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1: unexpected [$3] in [${2:0:300}]"; fi; }
releases() { find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd,; }
header() { curl -sI "$2" | tr -d '\r' | awk -v h="$1" 'tolower($0) ~ "^" tolower(h) ":" { sub(/^[^:]*: */, ""); print; exit }'; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

section "host setup (what user-data does)"
dnf install -y -q python3.12 nginx cronie logrotate tar gzip findutils util-linux shadow-utils procps-ng jq >/dev/null 2>&1 || { echo "dnf failed"; exit 1; }
useradd --system --shell /sbin/nologin shiptrack
mkdir -p /opt/shiptrack/releases /etc/shiptrack /var/lib/shiptrack/pod /var/log/shiptrack /tmp/art /seed
chown shiptrack:shiptrack /var/lib/shiptrack/pod /var/log/shiptrack
tar -xzf "/artifacts/shiptrack-$SHA.tar.gz" -C /seed "$SHA/deploy" "$SHA/scripts"
SEED=/seed/$SHA
cp "$SEED/deploy/nginx/nginx.conf" /etc/nginx/nginx.conf
cp "$SEED/deploy/nginx/shiptrack.conf" "$SEED/deploy/nginx/shiptrack-headers.inc" /etc/nginx/conf.d/
mkdir -p /etc/systemd/system && cp "$SEED/deploy/systemd/shiptrack.service" /etc/systemd/system/shiptrack.service
cp "$SEED/deploy/cron/shiptrack-sla" /etc/cron.d/shiptrack-sla
cp "$SEED/deploy/logrotate/shiptrack" /etc/logrotate.d/shiptrack
cat >/etc/shiptrack/app.ini <<INI
[database]
host = $PG_HOST
port = 5432
name = shiptrack_pkg
user = postgres
password = postgres
sslmode = disable

[app]
pod_dir = /var/lib/shiptrack/pod
log_file = /var/log/shiptrack/app.log
INI
chmod 0644 /etc/shiptrack/app.ini

# Stubs for the two things a container does not have: S3 and systemd.
cat >/usr/local/bin/aws <<'STUB'
#!/usr/bin/env bash
args=(); for a in "$@"; do [[ $a == --* ]] || args+=("$a"); done
[[ ${args[0]} == s3 && ${args[1]} == cp ]] || { echo "aws stub: unsupported: $*" >&2; exit 2; }
name=$(basename "${args[2]}")
for dir in /tmp/art /artifacts; do [[ -f "$dir/$name" ]] && exec cp "$dir/$name" "${args[3]}"; done
echo "aws stub: not found: $name" >&2; exit 1
STUB
cat >/usr/local/bin/systemctl <<'STUB'
#!/usr/bin/env bash
# Emulates `systemctl restart shiptrack` by starting gunicorn with the unit file's ExecStart.
[[ "$1 $2" == "restart shiptrack" ]] || exit 0
pkill -f 'gunicorn shiptrack.main:app' || true
for _ in $(seq 1 20); do pgrep -f 'gunicorn shiptrack.main:app' >/dev/null || break; sleep 0.25; done
mkdir -p /run/shiptrack && chown shiptrack:shiptrack /run/shiptrack
cmd=$(sed -n 's/^ExecStart=//p' /etc/systemd/system/shiptrack.service)
cd /opt/shiptrack/current || exit 1
# shellcheck disable=SC2086
nohup runuser -u shiptrack -- $cmd >/var/log/shiptrack/stub-start.log 2>&1 &
echo restart >>/tmp/systemctl.log
STUB
chmod +x /usr/local/bin/aws /usr/local/bin/systemctl

section "configuration files"
check "nginx config is valid" nginx -t
check "logrotate config is valid" logrotate -d /etc/logrotate.d/shiptrack
check "cloudwatch agent config is valid JSON" jq -e '.logs.logs_collected.files.collect_list | length == 4' "$SEED/deploy/cloudwatch/amazon-cloudwatch-agent.json"
unit=$(cat /etc/systemd/system/shiptrack.service)
for key in "User=shiptrack" "Restart=always" "RestartSec=2" "KillMode=mixed" "TimeoutStopSec=10" "RuntimeDirectory=shiptrack"; do has "unit sets $key" "$unit" "$key"; done
has "unit runs gunicorn through the venv python" "$unit" "ExecStart=/opt/shiptrack/current/venv/bin/python -m gunicorn shiptrack.main:app -k uvicorn_worker.UvicornWorker -w 4 -b unix:/run/shiptrack/gunicorn.sock"
cron_line=$(grep -v '^#' /etc/cron.d/shiptrack-sla | grep sla_scan)
has "cron job runs as shiptrack every 5 minutes" "$cron_line" "*/5 * * * * shiptrack /opt/shiptrack/current/venv/bin/python -m shiptrack.jobs.sla_scan"
nginx

section "migrate (extracts to the final path, does not activate)"
out=$("$SEED/scripts/migrate.sh" "$SHA" testbucket 2>&1); rc=$?
eq "migrate.sh exits 0" "$rc" 0
has "migrations reach head" "$out" "migrations are at head"
check "release is extracted to its final path" test -f "/opt/shiptrack/releases/$SHA/RELEASE"
check_fails "migrate does not activate the release" test -e /opt/shiptrack/current
check "the database is at revision 0001" "/opt/shiptrack/releases/$SHA/venv/bin/python" -c "
import psycopg
with psycopg.connect(host='$PG_HOST', dbname='shiptrack_pkg', user='postgres', password='postgres') as c:
    assert c.execute('select version_num from shiptrack.alembic_version').fetchone() == ('0001',)
"

section "deploy"
out=$("$SEED/scripts/deploy.sh" "$SHA" testbucket 2>&1); rc=$?
eq "deploy.sh exits 0" "$rc" 0
eq "current points at the release" "$(readlink /opt/shiptrack/current)" "releases/$SHA"
eq "release history records the deploy" "$(cat /opt/shiptrack/RELEASE_HISTORY)" "$SHA"
has "service was restarted" "$(cat /tmp/systemctl.log)" restart
eq "venv runs from the release path" "$(/opt/shiptrack/current/venv/bin/python -c 'import sys; print(sys.prefix)')" "/opt/shiptrack/current/venv"

section "nginx: API"
eq "GET / is OK" "$(curl -s localhost/)" "OK"
eq "GET / carries the stack header" "$(header X-ShipTrack-Stack localhost/)" "legacy"
created=$(curl -s -X POST localhost/api/v1/shipments -H 'content-type: application/json' -d '{"carrier_code":"ACME","origin":"A","destination":"B","promised_delivery_at":"2026-12-01T00:00:00Z"}')
sid=$(jq -r .id <<<"$created"); tn=$(jq -r .tracking_number <<<"$created")
has "shipment is created through nginx" "$tn" "MF"
eq "event is accepted" "$(status -X POST "localhost/api/v1/shipments/$sid/events" -H 'Idempotency-Key: pkg-1' -H 'content-type: application/json' -d '{"event_type":"IN_TRANSIT","location":"Hub","occurred_at":"2026-10-07T00:00:00Z"}')" 202
sleep 1
eq "event shows up in the track view" "$(curl -s "localhost/api/v1/track/$tn" | jq -r .status)" "IN_TRANSIT"
eq "API 404 uses the JSON envelope" "$(curl -s localhost/api/v1/nope | jq -r .error.code)" "NOT_FOUND"
eq "API errors carry the stack header" "$(header X-ShipTrack-Stack localhost/api/v1/nope)" "legacy"

section "nginx: proof of delivery"
head -c 100 /dev/urandom >/tmp/small.png
doc=$(curl -s -F "file=@/tmp/small.png;type=image/png" "localhost/api/v1/shipments/$sid/pod")
eq "small POD is stored" "$(jq -r .size_bytes <<<"$doc")" 100
eq "POD downloads" "$(status "localhost/api/v1/shipments/$sid/pod/$(jq -r .document_id <<<"$doc")")" 200
head -c 10485760 /dev/zero >/tmp/ten.pdf
eq "a file of exactly 10 MiB is accepted" "$(status -F "file=@/tmp/ten.pdf;type=application/pdf" "localhost/api/v1/shipments/$sid/pod")" 201
head -c 10485761 /dev/zero >/tmp/ten1.pdf
body=$(curl -s -w '\n%{http_code}' -F "file=@/tmp/ten1.pdf;type=application/pdf" "localhost/api/v1/shipments/$sid/pod")
eq "10 MiB + 1 byte is rejected with 413" "${body##*$'\n'}" 413
eq "...with the application's error envelope" "$(head -n1 <<<"$body" | jq -r .error.code)" "PAYLOAD_TOO_LARGE"
head -c 12582912 /dev/zero >/tmp/twelve.pdf
body=$(curl -s -D /tmp/h413 -w '\n%{http_code}' -F "file=@/tmp/twelve.pdf;type=application/pdf" "localhost/api/v1/shipments/$sid/pod")
eq "a body past nginx's limit is 413" "${body##*$'\n'}" 413
eq "...with the same envelope" "$(head -n1 <<<"$body" | jq -r .error.code)" "PAYLOAD_TOO_LARGE"
has "...and the stack header" "$(tr -d '\r' </tmp/h413 | tr '[:upper:]' '[:lower:]')" "x-shiptrack-stack: legacy"

section "nginx: UI"
asset=$(basename "$(compgen -G '/opt/shiptrack/current/web/dist/assets/*.js' | head -n1)")
html=$(curl -s localhost/ui/)
has "/ui/ serves the SPA shell" "$html" '<div id="root">'
eq "/ui/ is 200" "$(status localhost/ui/)" 200
eq "/ui/ is not cached" "$(header Cache-Control localhost/ui/)" "no-cache"
eq "/ui/ carries the stack header" "$(header X-ShipTrack-Stack localhost/ui/)" "legacy"
has "/ui/ is HTML" "$(header Content-Type localhost/ui/)" "text/html"
eq "deep link /ui/track/MF0000000000 returns the shell" "$(curl -s localhost/ui/track/MF0000000000)" "$html"
eq "deep link is 200" "$(status localhost/ui/track/MF0000000000)" 200
eq "deep link carries the stack header" "$(header X-ShipTrack-Stack localhost/ui/track/MF0000000000)" "legacy"
eq "deep link is not cached" "$(header Cache-Control localhost/ui/track/MF0000000000)" "no-cache"
eq "unknown client route returns the shell" "$(curl -s localhost/ui/anything/else)" "$html"
eq "/ui redirects to /ui/" "$(status localhost/ui)" 301
has "...to /ui/" "$(header Location localhost/ui)" "/ui/"
eq "asset is 200" "$(status "localhost/ui/assets/$asset")" 200
eq "asset is cached forever" "$(header Cache-Control "localhost/ui/assets/$asset")" "public, max-age=31536000, immutable"
eq "asset carries the stack header" "$(header X-ShipTrack-Stack "localhost/ui/assets/$asset")" "legacy"
eq "asset is gzipped" "$(curl -sI -H 'Accept-Encoding: gzip' "localhost/ui/assets/$asset" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-encoding"{print $2}')" "gzip"
eq "a missing asset is 404" "$(status localhost/ui/assets/missing.js)" 404
lacks "...and is not the HTML shell" "$(curl -s localhost/ui/assets/missing.js)" '<div id="root">'
eq "a missing asset still carries the stack header" "$(header X-ShipTrack-Stack localhost/ui/assets/missing.js)" "legacy"
headers=$(curl -sI localhost/ui/ | tr -d '\r' | tr '[:upper:]' '[:lower:]')
for h in content-security-policy x-content-type-options referrer-policy x-frame-options strict-transport-security; do
  lacks "AP-16: no $h on /ui/" "$headers" "$h:"
done

section "cron job and logs"
check "SLA scan runs as the shiptrack user" runuser -u shiptrack -- /opt/shiptrack/current/venv/bin/python -m shiptrack.jobs.sla_scan
check "app.log is written by the service" test -s /var/log/shiptrack/app.log
eq "app.log is owned by shiptrack" "$(stat -c %U /var/log/shiptrack/app.log)" shiptrack
check "gunicorn error log is written" test -f /var/log/shiptrack/error.log

section "second release, rollback, and failure cases"
# Build a second release the way the pipeline would: tar a release directory and publish it.
rm -rf /opt/shiptrack/releases/second && cp -a "/opt/shiptrack/releases/$SHA" /opt/shiptrack/releases/second
sed -i 's/^sha=.*/sha=second/' /opt/shiptrack/releases/second/RELEASE
tar -C /opt/shiptrack/releases -czf /tmp/art/shiptrack-second.tar.gz second
(cd /tmp/art && sha256sum shiptrack-second.tar.gz >shiptrack-second.tar.gz.sha256)
rm -rf /opt/shiptrack/releases/second   # a fresh host has never seen it
out=$(/seed/"$SHA"/scripts/deploy.sh second testbucket 2>&1); rc=$?
eq "deploying a second release succeeds" "$rc" 0
eq "current moved to it" "$(readlink /opt/shiptrack/current)" "releases/second"
eq "the extracted venv still works from its new path" "$(curl -s localhost/)" "OK"
eq "history has both releases" "$(paste -sd, /opt/shiptrack/RELEASE_HISTORY)" "$SHA,second"

out=$("$SEED/scripts/rollback.sh" 2>&1); rc=$?
eq "rollback exits 0" "$rc" 0
eq "rollback goes back to the previous release" "$(readlink /opt/shiptrack/current)" "releases/$SHA"
eq "rollback reports the sha as its last line" "$(tail -n1 <<<"$out")" "ROLLED_BACK_TO=$SHA"
eq "the service still answers" "$(curl -s localhost/)" "OK"
check_fails "rollback to a release that is gone fails" "$SEED/scripts/rollback.sh" does-not-exist
eq "...and leaves current alone" "$(readlink /opt/shiptrack/current)" "releases/$SHA"

# A corrupted download must be rejected before anything changes.
cp /tmp/art/shiptrack-second.tar.gz /tmp/art/shiptrack-corrupt.tar.gz
echo "0000000000000000000000000000000000000000000000000000000000000000  shiptrack-corrupt.tar.gz" >/tmp/art/shiptrack-corrupt.tar.gz.sha256
check_fails "a checksum mismatch aborts the deploy" "$SEED/scripts/deploy.sh" corrupt testbucket
check_fails "...before extracting anything" test -d /opt/shiptrack/releases/corrupt
eq "...and current is unchanged" "$(readlink /opt/shiptrack/current)" "releases/$SHA"
check_fails "an invalid sha is refused" "$SEED/scripts/deploy.sh" '../etc' testbucket

section "history and pruning"
# shellcheck source=/dev/null
source "$SEED/scripts/lib.sh"
hist() { printf '%s\n' "$@" >"$HISTORY_FILE"; }
hist A B C;       eq "previous of the newest" "$(previous_release C)" B
hist A B C;       eq "previous of an older entry" "$(previous_release B)" A
hist A B C;       eq "nothing before the oldest" "$(previous_release A)" ""
hist A B C;       eq "a release missing from history rolls back to the newest entry" "$(previous_release X)" C
hist A A B B;     eq "repeated deploys are skipped over" "$(previous_release B)" A
hist A A;         eq "no distinct previous release" "$(previous_release A)" ""
: >"$HISTORY_FILE"; eq "empty history" "$(previous_release A)" ""

rm -rf "${RELEASES_DIR:?}"/*; for r in r1 r2 r3 r4 r5 r6 r7 r8; do mkdir -p "$RELEASES_DIR/$r"; done
ln -sfn releases/r8 "$CURRENT_LINK"
hist r1 r2 r3 r4 r5 r6 r7 r8
prune_releases 5
eq "prune keeps the newest five" "$(releases)" "r4,r5,r6,r7,r8"
ln -sfn releases/r4 "$CURRENT_LINK"   # a rollback target older than the window is still protected
hist r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11
mkdir -p "$RELEASES_DIR"/r9 "$RELEASES_DIR"/r10 "$RELEASES_DIR"/r11
prune_releases 5
has "prune never removes the current release" "$(releases)" "r4"

printf '\n'
if [[ $failures -eq 0 ]]; then echo "ALL PACKAGING CHECKS PASSED"; else echo "$failures PACKAGING CHECK(S) FAILED"; exit 1; fi
