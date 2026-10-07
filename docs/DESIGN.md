# ShipTrack Legacy (v1.x) — Design Document

| | |
|---|---|
| **Repository** | `shiptrack-legacy` |
| **Author** | M.L. |
| **Status** | v0.1 |
| **Last updated** | 2026-10-06 |
| **Related** | `shiptrack-platform/docs/DESIGN.md`, `shiptrack-modern/docs/DESIGN.md` |

---

## 0. Instructions for the implementing agent

1. **This repo reproduces a realistic legacy deployment on purpose.** The anti-patterns in §4 are **requirements**. Do not fix, modernize, or "improve" them. Mark each one where it is implemented with a comment such as `# LEGACY AP-06: in-process queue, events lost on restart` (use the appropriate comment syntax per file type). The migration report greps for these tags.
2. **Hard limits that override realism.** Never violate these, even to make an anti-pattern more authentic:
   - No secrets committed to git, in any form.
   - No long-lived AWS access keys. CI uses GitHub OIDC.
   - No SSH, no key pairs, no port 22. Use SSM only.
   - No public IPs on instances.
   - EBS volumes stay encrypted.
   - Public repository: no account IDs, ARNs containing account IDs, ALB DNS names, host IDs, or tokens in committed files, workflow logs, PR comments, artifacts, or evidence (platform §6.12).
3. **The application code must be clean, typed, tested Python.** What makes this repo legacy is its *architecture and operations*, not sloppy code. `shiptrack-modern` forks this code at tag `v1.0.0`.
4. **Never run `terraform apply` or any command that changes AWS resources from a workstation.** Infrastructure and releases change only through GitHub Actions workflows (§7), with environment approval. Local work uses OrbStack (Docker) and, where useful, LocalStack; no AWS credentials are present locally. The rules in platform design §0 apply.
5. Stop and ask when something is ambiguous. Record decisions in `docs/ADR.md`. Items marked **[VERIFY]** must be checked against current documentation.

---

## 1. Context and role in the migration

- This stack is the **"before" baseline**: performance, cost, security findings, and operational pain are all measured here first.
- It consumes the platform SSM contract (`/shiptrack/platform/*`). It never reads platform state.
- **Build order:** this application is built and tested first (L1, L1b, and the build parts of L2), before any infrastructure. The full cross-repo order is in platform §13.
- Release milestones:

| Tag | Meaning |
|---|---|
| `v1.0.0` | Baseline; **fork point for `shiptrack-modern`** |
| `v1.1.0` | Migration-aware release (§8). Required before cutover Wave 2. |

- §3 of this document is the **canonical API and behavior spec** for ShipTrack. The executable version is `shiptrack-platform/validation/contract/`.

---

## 2. Scope

**In scope:** FastAPI application, minimal React tracking UI, DB schema and migrations, tarball build, SSM-based deploy and rollback, EC2/ASG infrastructure, CloudWatch agent, assessment tooling, the v1.1 migration-aware release.

**Non-goals:** autoscaling, containers, high availability beyond two hosts, authentication, CI security scanning (deliberate — AP-13).

**Repository layout**

```
shiptrack-legacy/
├── src/shiptrack/                         # Python application
│   ├── main.py                            # FastAPI app factory, routers, exception handlers
│   ├── config.py                          # INI loader
│   ├── api/                               # HTTP API
│   │   ├── shipments.py
│   │   ├── events.py
│   │   ├── track.py
│   │   ├── pod.py
│   │   ├── health.py                      # GET / only (AP-07)
│   │   ├── errors.py                      # error envelope and exception handlers
│   │   ├── pagination.py                  # keyset cursor encode/decode
│   │   └── deps.py                        # shared route helpers
│   ├── domain/
│   │   ├── status.py                      # State machine
│   │   ├── eta.py
│   │   └── models.py                      # Pydantic schemas
│   ├── db/                                # Database access
│   │   ├── models.py                      # SQLAlchemy ORM
│   │   └── session.py
│   ├── events/processor.py                # In-process queue + thread (AP-06)
│   ├── storage/local.py                   # Local-disk POD storage (AP-05)
│   └── jobs/sla_scan.py                   # Cron entrypoint (AP-09)
├── migrations/                            # Alembic; 0001_initial creates the schema and seeds carriers
├── alembic.ini
├── tests/{unit,integration,packaging}/
├── web/                                   # UI: React + Vite + TypeScript (§3.6)
│   ├── index.html
│   ├── package.json  package-lock.json  .nvmrc  .npmrc
│   ├── vite.config.ts  tsconfig.json  eslint.config.js
│   ├── scripts/check-dist.mjs             # post-build checks: no inline script/style, size budget, asset names
│   └── src/
│       ├── main.tsx  App.tsx  api.ts  format.ts  stack.tsx  styles.css
│       ├── pages/{SearchPage,TrackPage,NotFoundPage}.tsx
│       ├── components/{StatusBadge,Timeline,StackBadge}.tsx
│       └── __tests__/
├── deploy/                                # systemd/, nginx/, cron/, logrotate/, cloudwatch/ configs (§5)
├── scripts/                               # build_tarball.sh (+ build_in_container.sh), deploy.sh, rollback.sh, migrate.sh, lib.sh, migrate_pod_to_s3.py (v1.1)
│   └── evidence/                          # AP evidence scripts (§9)
├── terraform/                             # §6
│   ├── modules/app_host/
│   ├── templates/user-data.sh.tftpl       # Reads the deploy/ files so each config has one source
│   └── envs/dev/
├── docs/
│   ├── DESIGN.md
│   ├── ADR.md                             # decision log
│   ├── runbooks/                          # rollback.md and other operational runbooks
│   └── assessment/                        # §9 outputs
├── .github/
│   ├── workflows/                         # ci, deploy, rollback, terraform-pr, terraform-apply, evidence, assess (§7)
│   └── dependabot.yml
├── pyproject.toml                         # Package metadata; ruff, mypy, pytest config
├── requirements.in  requirements.txt      # pip-compile with hashes
├── requirements-dev.in  requirements-dev.txt
├── compose.yaml                           # Local only: Postgres 17 (+ LocalStack for v1.1)
├── Makefile                               # Local lint, test, and build targets
├── .gitleaks.toml  .gitignore
└── README.md
```

---

## 3. Application specification (canonical)

### 3.1 Technology

| Concern | Choice |
|---|---|
| Runtime | Python 3.12 (AL2023 package — see §5) |
| Web | FastAPI, Pydantic v2 |
| Server | gunicorn + `uvicorn-worker` (`uvicorn_worker.UvicornWorker`; the old `uvicorn.workers` class is deprecated) |
| DB | SQLAlchemy 2.0 (sync), psycopg 3, Alembic |
| AWS SDK | boto3 |
| Config | `configparser` reading `/etc/shiptrack/app.ini` (AP-01) |
| Dependencies | `requirements.in` → `pip-compile --generate-hashes` → `requirements.txt` |
| Tests | pytest, httpx `TestClient`, Postgres 17 service container |
| Lint | ruff (lint + format), mypy (strict on `domain/`) |
| Web UI | React + TypeScript, Vite, React Router (library mode); built at build time, served as static files by nginx (§3.6) |
| UI tooling | Node 24 LTS (build time only; pinned in `web/.nvmrc`), npm with `package-lock.json`, ESLint, Vitest + React Testing Library |

Package and UI layout: see the repository layout in §2.

### 3.2 Data model

All tables live in schema `shiptrack`. Migration `0001_initial` creates everything and seeds the carriers.

**`carriers`**

| Column | Type | Constraints |
|---|---|---|
| id | smallserial | PK |
| code | varchar(8) | unique, not null |
| name | varchar(100) | not null |
| created_at | timestamptz | default `now()` |

Seed rows: `ACME`, `BOLT`, `CRWN`, `MFLT` (Meridian fleet), `ZZTEST` (test traffic only).

**`shipments`**

| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK, default `gen_random_uuid()` |
| tracking_number | varchar(12) | unique, not null, format `MF` + 10 digits, generated server-side |
| carrier_id | smallint | FK → carriers, not null |
| origin | varchar(100) | not null |
| destination | varchar(100) | not null |
| status | varchar(20) | not null, `CHECK IN ('CREATED','PICKED_UP','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED','EXCEPTION')`, default `CREATED` |
| promised_delivery_at | timestamptz | not null |
| estimated_delivery_at | timestamptz | null |
| delivered_at | timestamptz | null |
| last_event_at | timestamptz | null (latest *applied* event `occurred_at`) |
| sla_breached | boolean | not null, default false |
| sla_breached_at | timestamptz | null |
| created_at / updated_at | timestamptz | default `now()` |

Indexes:
- `(carrier_id)`
- `(created_at, id)` for keyset pagination
- Partial index `(promised_delivery_at) WHERE status <> 'DELIVERED' AND NOT sla_breached`

**`tracking_events`**

| Column | Type | Constraints |
|---|---|---|
| id | bigserial | PK |
| shipment_id | uuid | FK, not null |
| event_type | varchar(20) | `CHECK IN` (statuses except `CREATED`) |
| location | varchar(100) | not null |
| occurred_at | timestamptz | not null |
| received_at | timestamptz | default `now()` |
| idempotency_key | varchar(64) | **unique**, not null |
| applied | boolean | not null (false if out-of-order or invalid transition) |
| payload | jsonb | null |

Index: `(shipment_id, occurred_at)`.

**`pod_documents`**

| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK |
| shipment_id | uuid | FK, not null |
| storage_uri | text | not null (`file:///var/lib/shiptrack/pod/...` or `s3://...`) |
| content_type | varchar(50) | not null |
| size_bytes | bigint | not null |
| sha256 | char(64) | not null |
| uploaded_at | timestamptz | default `now()` |

**`sla_alerts`**

| Column | Type | Constraints |
|---|---|---|
| id | bigserial | PK |
| shipment_id | uuid | FK, not null |
| detected_at | timestamptz | default `now()` |
| detected_by | varchar(64) | not null (hostname) |

**No unique constraint on `shipment_id`** (AP-09 — makes duplicates visible).

### 3.3 Domain rules

**State machine**

```
CREATED ─► PICKED_UP ─► IN_TRANSIT ─► OUT_FOR_DELIVERY ─► DELIVERED (terminal)
   │           │             │                │
   └───────────┴─────────────┴────────────────┴─► EXCEPTION ─► IN_TRANSIT | OUT_FOR_DELIVERY
```

Forward skips are allowed (for example `CREATED → IN_TRANSIT`); backward moves are not.

**Event application** (one DB transaction per event):
1. Insert the `tracking_events` row with `ON CONFLICT (idempotency_key) DO NOTHING`. If nothing was inserted, it is a **duplicate**: stop.
2. If `occurred_at < shipments.last_event_at`: **out-of-order** — keep `applied=false` and do not change status.
3. If the transition is invalid: **invalid** — keep `applied=false`, log a WARNING, and do not change status.
4. Otherwise: **applied** — update status, `last_event_at`, ETA, and `delivered_at` (if DELIVERED), and set `applied=true`.

**ETA rules**

| New status | `estimated_delivery_at` |
|---|---|
| PICKED_UP | `occurred_at + 72h` |
| IN_TRANSIT | `occurred_at + 48h` |
| OUT_FOR_DELIVERY | `occurred_at + 8h` |
| DELIVERED | `= delivered_at = occurred_at` |
| EXCEPTION | `current estimate (or promised) + 24h` |

**SLA scan:** find shipments with `status <> 'DELIVERED' AND promised_delivery_at < now() AND NOT sla_breached`. For each, insert into `sla_alerts` (with `detected_by = hostname`) and set `sla_breached = true, sla_breached_at = now()`. Log `SLA_BREACH tracking=<n> promised=<ts> host=<h>`. The legacy implementation is **naive read-then-write with no locking** (AP-09).

### 3.4 HTTP API (v1)

- JSON throughout.
- Timestamps are ISO-8601 UTC with a `Z` suffix.
- Error envelope for **all** 4xx/5xx responses, including validation errors (custom handler):
  ```json
  {"error": {"code": "NOT_FOUND", "message": "...", "request_id": null}}
  ```
- Error codes: `VALIDATION_ERROR` (422), `NOT_FOUND` (404), `MISSING_IDEMPOTENCY_KEY` (400), `UNSUPPORTED_MEDIA_TYPE` (415), `PAYLOAD_TOO_LARGE` (413), `UNKNOWN_CARRIER` (422), `INTERNAL` (500).
- Modern-only codes (legacy never returns them): `QUEUE_UNAVAILABLE` (503, events endpoint only) and `INJECTED_FAULT` (500, game days only; modern §5.9). The contract suite accepts `QUEUE_UNAVAILABLE` only when `X-ShipTrack-Stack: modern` and treats `INJECTED_FAULT` as a failure.
- Every response carries `X-ShipTrack-Stack: legacy|modern` (legacy sets it in nginx, modern in middleware). The contract suite uses it to detect routing fall-through.

| Method | Path | Request | Success | Errors |
|---|---|---|---|---|
| GET | `/` | — | 200 `text/plain` `OK` | — |
| POST | `/api/v1/shipments` | `{carrier_code, origin, destination, promised_delivery_at}` | 201 Shipment, `Location` header | 422 |
| GET | `/api/v1/shipments/{id}` | — | 200 Shipment | 404 |
| GET | `/api/v1/shipments` | query `status?`, `carrier_code?`, `limit` (1–100, default 20), `cursor?` | 200 `{items:[Shipment], next_cursor}` (keyset on `created_at,id`; opaque base64 cursor) | 422 |
| POST | `/api/v1/shipments/{id}/events` | header `Idempotency-Key` (1–64 chars); body `{event_type, location, occurred_at, payload?}` | **202** `{accepted:true, idempotency_key}` (shipment existence is checked synchronously first) | 400, 404, 422; 503 `QUEUE_UNAVAILABLE` (modern only) |
| GET | `/api/v1/track/{tracking_number}` | — | 200 TrackView | 404 |
| POST | `/api/v1/shipments/{id}/pod` | multipart `file`; ≤10 MiB; `application/pdf`, `image/png`, `image/jpeg` | 201 `{document_id, shipment_id, content_type, size_bytes, sha256, uploaded_at}` | 404, 413, 415 |
| GET | `/api/v1/shipments/{id}/pod/{document_id}` | — | 200 file bytes with the correct `Content-Type` (modern may answer 302 → 200; clients must follow redirects) | 404 |
| GET | `/ui/`, `/ui/{path}` | — | 200 `text/html` SPA shell, `Cache-Control: no-cache`. Any non-asset path under `/ui/` returns the shell so client-side routes survive a refresh | — |
| GET | `/ui/assets/{file}` | — | 200 hashed static asset, `Cache-Control: public, max-age=31536000, immutable` | 404 |

**Shipment** JSON:
```json
{"id","tracking_number","carrier_code","origin","destination","status",
 "promised_delivery_at","estimated_delivery_at","delivered_at",
 "sla_breached","created_at","updated_at"}
```

**TrackView** is the public view and contains no internal IDs:
```json
{"tracking_number","carrier_code","status","estimated_delivery_at","delivered_at",
 "events":[{"event_type","location","occurred_at"}]}
```
Only applied events are included, sorted by `occurred_at` ascending.

### 3.5 Testing

- **Unit:** state machine (every transition pair), ETA, idempotency, out-of-order handling, cursor encode/decode.
- **Integration:** API against Postgres 17 (GitHub Actions service container), Alembic upgrade from an empty database, and an SLA scan that runs two scanners concurrently and **asserts duplicates can occur** (documents AP-09).
- Coverage ≥ 75% on `domain/` and `api/`.
- The cross-stack contract suite lives in `shiptrack-platform/validation/contract`.
- **UI:** Vitest + React Testing Library for every page state (loading, found, not found, invalid input, network error) and the tracking-number validator. `tsc --noEmit` and ESLint must be clean.
- **Packaging:** `tests/packaging/run.sh` builds the tarball and, on a fresh `amazonlinux:2023` container, runs migrate, deploy, rollback, pruning, and checksum-failure cases plus the nginx checks: stack header on every route, UI deep links, asset caching, no security headers (AP-16), and the 10 MiB POD limit.
- **Local development:** OrbStack provides Docker for Postgres 17 and for the `amazonlinux:2023` build container, and the unit and integration tests run against that Postgres. LocalStack (which needs an account and auth token) is used locally only for the S3, SSM, and Secrets Manager paths (`migrate_pod_to_s3.py`, v1.1); CI runs the same tests against a moto server, so fork PRs and token-less runs pass. The tests take the AWS endpoint from the environment. Real nginx, systemd, cron, and ALB behavior is validated only after deployment, in AWS. The same tests run in `ci.yml`; no workflow step depends on a developer workstation.

### 3.6 Web UI (minimal)

**Purpose:** let non-engineers look up a shipment, and make the cutover *visible* during the demo. Deliberately small: two pages, read-only, no authentication.

| Client route | Content |
|---|---|
| `/ui/` | Tracking-number search box. Validates `^MF\d{10}$` before navigating; shows an inline error otherwise |
| `/ui/track/:trackingNumber` | Status badge, carrier, estimated delivery, delivered time, event timeline (newest first), Refresh button. Auto-refreshes every 30 s until status is `DELIVERED` |
| anything else | Not-found page with a link back to search |

**Rules**
- Calls only `GET /api/v1/track/{tracking_number}`, using a same-origin relative URL. No CORS and no API base-URL configuration.
- **Stack badge** in the footer shows the `X-ShipTrack-Stack` value from the last API response ("Served by: legacy" or "Served by: modern"). This is how the audience watches traffic shift during Wave 1.
- Error states:
  - 404 → "No shipment found for MF…"
  - 422 or failed validation → validation message
  - network error or 5xx → retry prompt that shows `error.request_id` from the error envelope when present
- Vite `base: '/ui/'`; React Router `basename="/ui"`.
- No external CDNs, web fonts, analytics, inline `<script>`, or inline `<style>`. Everything is bundled and same-origin, so modern can enforce a strict CSP (REM-16) without UI changes.
- `dangerouslySetInnerHTML` is forbidden (ESLint `react/no-danger` as an error). React's output escaping is the XSS control for user-supplied tracking numbers.
- Accessibility basics: labelled input, visible focus ring, status conveyed by text and not color alone, `aria-live="polite"` on the result region.
- One plain stylesheet; no component library. Bundle budget: < 200 KB gzipped (checked in CI).
- **Reproducible builds:** `npm ci` from the lockfile with the pinned Node version. `web/.nvmrc` pins the **exact** version (major.minor.patch); the build container's Node must equal it, and `shiptrack-modern` must build with the same version. The same source must produce the same hashed asset filenames, because cutover gate G6 compares them across stacks.

---

## 4. Anti-pattern registry (intentional)

Each entry is a requirement here and maps 1:1 to a remediation (`REM-xx`) in the modern design.

| ID | Anti-pattern | Implementation | Evidence to capture | Remediation |
|---|---|---|---|---|
| AP-01 | Plaintext DB credentials on disk | User-data fetches the **migrator** secret and renders `/etc/shiptrack/app.ini`, mode `0644` | File listing; finding-register entry | REM-01 |
| AP-02 | App runs as schema owner | `app.ini` uses `shiptrack_migrator` for runtime *and* migrations | `SELECT current_user` from the app | REM-02 |
| AP-03 | Over-privileged instance role | Inline policy `s3:*` on `*`, `secretsmanager:GetSecretValue` on `*`, plus `AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy` (the boundary still applies). Also `kms:Decrypt` on the platform secrets key with `kms:ViaService = secretsmanager.<region>.amazonaws.com`; this is required to read a CMK-encrypted secret and is not part of the anti-pattern | IAM Access Analyzer / Security Hub IAM findings; Checkov | REM-03 |
| AP-04 | IMDSv1 allowed | Launch template `http_tokens = "optional"` | Security Hub EC2.8 | REM-04 |
| AP-05 | Local-disk POD storage, masked by ALB stickiness | Files under `/var/lib/shiptrack/pod/{shipment_id}/{doc_id}` on whichever host received the upload; platform tg-legacy has stickiness on | `curl` without a cookie → ≈50% 404 on POD GET | REM-05 |
| AP-06 | In-process event queue | `queue.Queue` + daemon thread per gunicorn worker; 202 is returned before persistence; the queue is lost on restart | Simulator ledger `verify` shows events lost during a deploy | REM-06 |
| AP-07 | Shallow health check | `GET /` returns `OK` without touching the DB; ASG `health_check_type = "EC2"` | Break DB access → ALB still shows healthy while the API returns 500s | REM-07 |
| AP-08 | Unstructured file logs | Plain-text logs to `/var/log/shiptrack/*.log`, logrotate, CloudWatch agent tails files; no request IDs | Log Insights cannot correlate a request | REM-08 |
| AP-09 | Cron on every host, naive SLA scan | `/etc/cron.d/shiptrack-sla` on both instances; read-then-write without locking | `SELECT shipment_id, count(*) FROM shiptrack.sla_alerts GROUP BY 1 HAVING count(*) > 1` | REM-09 |
| AP-10 | Oversized fixed capacity | 2 × `m5.xlarge`, ASG min = max = desired = 2, no scaling policies | CPU < 10% at baseline load; Compute Optimizer recommendation | REM-10 |
| AP-11 | gp2 root volumes, oversized | 100 GiB gp2, encrypted | Cost Explorer EBS line; Compute Optimizer | REM-11 |
| AP-12 | In-place mutable deploys, no draining | Symlink swap + `systemctl restart` without deregistering from the TG | ALB `HTTPCode_ELB_502_Count` spike during deploy | REM-12 |
| AP-13 | No security scanning in CI | `ci.yml` runs lint/test/build only; scans run once out-of-band (§9) | Assessment scan reports | REM-13 |
| AP-14 | AMI drift / manual patching | AMI ID resolved once and pinned in tfvars; no instance refresh | Inspector EC2 CVE findings over time | REM-14 |
| AP-15 | No application metrics | Observability is limited to ALB metrics + CloudWatch agent host metrics | No latency per route, no event-lag signal | REM-15 |
| AP-16 | No security headers on the UI | nginx serves `/ui/` with no `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`, or frame protection | `curl -sI $BASE_URL/ui/` | REM-16 |

---

## 5. Host runtime

**OS:** Amazon Linux 2023. Resolve the AMI from the SSM public parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` **once** and pin the result in `terraform.tfvars` as `ami_id` (AP-14).

**Python:** the AL2023 `python3.12` and `python3.12-pip` packages (available in current AL2023 releases; an older pinned AMI may need `dnf --releasever=latest`). The build container (§7.1) must use the same AL2023 release as the pinned AMI.

**Packages installed by user-data:** `python3.12`, `python3.12-pip`, `nginx`, `amazon-cloudwatch-agent`, `cronie` (**AL2023 does not ship cron by default**), `logrotate`, `awscli` (preinstalled), `jq`.

**Filesystem layout**

```
/opt/shiptrack/releases/<sha>/      # extracted release (app + venv + configs + web/dist)
/opt/shiptrack/current -> releases/<sha>
/opt/shiptrack/RELEASE_HISTORY      # one sha per line, newest last
/etc/shiptrack/app.ini              # AP-01, mode 0644
/var/lib/shiptrack/pod/             # AP-05
/var/log/shiptrack/{app,access,error,sla}.log   # AP-08
/run/shiptrack/gunicorn.sock
```

The app runs as system user `shiptrack` (no login shell).

**systemd `shiptrack.service`**
- `ExecStart=/opt/shiptrack/current/venv/bin/python -m gunicorn shiptrack.main:app -k uvicorn_worker.UvicornWorker -w 4 -b unix:/run/shiptrack/gunicorn.sock --access-logfile /var/log/shiptrack/access.log --error-logfile /var/log/shiptrack/error.log --timeout 30`
- `User=shiptrack`, `RuntimeDirectory=shiptrack`, `Restart=always`, `RestartSec=2`
- `KillMode=mixed`, `TimeoutStopSec=10` (short; in-flight queue items are lost — AP-06)

**nginx:** `deploy/nginx/nginx.conf` replaces the AL2023 default so the stock server block cannot shadow `shiptrack.conf`. `listen 80`; `location /` proxies to the unix socket; `client_max_body_size 11m` (a 10 MiB file plus multipart overhead: the application enforces the exact limit and answers with its error envelope, and an `error_page 413` gives bodies past nginx's limit the same envelope); `proxy_read_timeout 30s`; forwards `X-Forwarded-*`; `add_header X-ShipTrack-Stack legacy always;` (stack identification for routing verification; set at the proxy so the forked app code stays unaware of it).

**nginx UI locations:**
- `location /ui/assets/` → `alias /opt/shiptrack/current/web/dist/assets/;` with `Cache-Control: public, max-age=31536000, immutable`.
- `location /ui/` → `alias /opt/shiptrack/current/web/dist/;` with `try_files $uri $uri/ /ui/index.html;` and `Cache-Control: no-cache`.
- `gzip on` for `text/css` and `application/javascript`.
- No security headers (AP-16).
- **Gotcha:** an `add_header` inside a `location` block **cancels inheritance** of every server-level `add_header`. Repeat `add_header X-ShipTrack-Stack legacy always;` in both UI locations, so keep it in an `include` snippet (`shiptrack-headers.inc`) used in every location that sets a header. Otherwise UI responses silently lose the stack header and the contract suite fails.
- **Gotcha:** `alias` combined with `try_files` is easy to get wrong. Test deep links (`/ui/track/MF0000000000`) explicitly.

**cron** `/etc/cron.d/shiptrack-sla`:
```
*/5 * * * * shiptrack /opt/shiptrack/current/venv/bin/python -m shiptrack.jobs.sla_scan >> /var/log/shiptrack/sla.log 2>&1
```

**logrotate:** daily, `rotate 7`, `compress`, `copytruncate`.

**CloudWatch agent**

| File | Log group |
|---|---|
| `app.log` | `/shiptrack/legacy/app` |
| `access.log` | `/shiptrack/legacy/access` |
| nginx error log | `/shiptrack/legacy/nginx` |
| `sla.log` | `/shiptrack/legacy/sla` |

Metrics: `mem_used_percent`, `disk_used_percent` (namespace `CWAgent`, dimension `AutoScalingGroupName`). Log groups are created by Terraform with 30-day retention and the platform logs KMS key.

**User-data (cloud-init) responsibilities**, in order:
1. Install packages, create the user and directories.
2. Read platform SSM parameters.
3. Fetch the migrator secret → render `app.ini` (AP-01).
4. Write the systemd, nginx, cron, logrotate, and CloudWatch agent configs. These are embedded via `templatefile`; the same files also ship inside the tarball under `deploy/`.
5. Read `/shiptrack/legacy/current_release` from SSM. If it is set, download, verify, and install that release (so ASG replacement instances self-deploy).
6. Enable and start the services.

**Size limit:** EC2 user-data is limited to 16 KB raw. The rendered script plus the embedded configs must fit; if they do not, send them as a gzip-compressed cloud-init multipart payload.

**Gotcha — venv relocation:** virtualenvs embed absolute paths. The build creates the venv at the **exact install path** `/opt/shiptrack/releases/<sha>/venv` (§7.1), and every entrypoint is invoked as `venv/bin/python -m …`, never via console-script shebangs.

---

## 6. Infrastructure (Terraform)

```
terraform/
├── modules/app_host/        # SG, IAM, launch template, ASG, alarms
└── envs/dev/               # backend (key legacy/dev.tfstate), contract reads, SSM docs, artifact bucket
```

**Contract reads:** `data "aws_ssm_parameter"` for every `/shiptrack/platform/*` key used.

**Resources**

| Resource | Spec |
|---|---|
| SG `shiptrack-legacy-app` | Ingress TCP 80 from `sg_alb_id`; egress all. Instances also get `sg_db_client_id`. |
| IAM role `shiptrack-legacy-instance` + instance profile | AP-03 policy; `permissions_boundary = permission_boundary_arn` (**mandatory** — the apply role denies creation without it) |
| Launch template `shiptrack-legacy` | `m5.xlarge` (AP-10); `ami_id` var (AP-14); root 100 GiB **gp2**, encrypted (AP-11); `metadata_options { http_tokens = "optional", http_endpoint = "enabled" }` (AP-04); no key pair; no public IP; user-data per §5; detailed monitoring off |
| ASG `shiptrack-legacy` | min = max = desired = 2; private-app subnets; `target_group_arns = [tg_legacy_arn]`; `health_check_type = "EC2"`; no scaling policies; tags propagate `Stack=legacy`, `Name=shiptrack-legacy` |
| S3 `shiptrack-legacy-artifacts-<acct>-<region>` | Versioning, SSE-S3, BPA, ownership enforced, TLS-only; lifecycle expires `releases/*` at 180 d |
| SSM parameter `/shiptrack/legacy/current_release` | Initial value `none`; `lifecycle { ignore_changes = [value] }` (owned by the deploy pipeline) |
| SSM parameter `/shiptrack/legacy/asg_name` | ASG name, for platform/modern runbooks |
| SSM documents | `ShipTrack-Migrate`, `ShipTrack-Deploy`, `ShipTrack-Rollback`, `ShipTrack-Evidence` (§7.6), `ShipTrack-PodSync` (v1.1) — `aws:runShellScript` documents that embed `scripts/lib.sh` and the script they run (Terraform `file()`), so they work before any release is on the host, with parameters `releaseSha` and `artifactBucket`; `ShipTrack-Evidence` also takes `script` (an allow-listed name under `scripts/evidence/`) and an optional S3 key for an input file |
| CloudWatch log groups | As in §5 |
| Alarms (host-level only, AP-15) | `CPUUtilization > 80%` 15 min; `StatusCheckFailed > 0` 5 min; `mem_used_percent > 90%` 10 min → SNS sev2; descriptions include owner/sev/runbook |

Default tags are the same keys as platform, with `Stack=legacy` and `Repo=shiptrack-legacy`.

---

## 7. Build, deploy, rollback

### 7.1 Build — `scripts/build_tarball.sh <sha>`
- **UI stage first:** in a Node container pinned by digest (its Node version must equal `web/.nvmrc`; the script fails otherwise), run `npm ci && npm run build` in `web/`. The output `web/dist/` is copied into the release in step 4.
- Runs inside an `amazonlinux:2023` container, so glibc and Python match the hosts.
  1. Install `python3.12`.
  2. Create the venv at `/opt/shiptrack/releases/<sha>/venv`.
  3. `pip install --require-hashes -r requirements.txt`, then `pip install --no-deps --no-build-isolation .` (setuptools is in the hashed requirements, so the build downloads nothing unhashed).
  4. Copy `alembic.ini`, `migrations/`, `deploy/`, `scripts/`, and `web/dist/` into the release directory.
  5. Write a `RELEASE` file (sha, UTC build time, builder).
- Output: `shiptrack-<sha>.tar.gz` (created with `tar -C /opt/shiptrack/releases -czf … <sha>`) plus `shiptrack-<sha>.tar.gz.sha256`.

### 7.2 Deploy — `.github/workflows/deploy.yml`
Triggered on push to `dev` after CI, or by `workflow_dispatch` with an optional `sha` (used by the AP-06 and AP-12 evidence runs), with `environment: dev` (required reviewers) and the `shiptrack-legacy-deploy` role via OIDC. The first deploy requires `db/bootstrap.sql` (platform §6.4) to have been run.

1. Build the tarball, then upload the tarball and checksum to `s3://<artifacts>/releases/`.
2. **Migrate:** `ssm send-command` `ShipTrack-Migrate` to **one** instance (the first InService instance from the ASG). It extracts the release to its final path without activating it (the virtualenv cannot be relocated) and runs `alembic upgrade head` with the `app.ini` credentials. Skip this step when the repo variable `RUN_MIGRATIONS` is `false` (set after the schema-ownership handoff; see modern §9.1).
3. **Deploy:** `ShipTrack-Deploy` targets tag `Stack=legacy` with `--max-concurrency 1 --max-errors 0`. `scripts/deploy.sh` then:
   1. Downloads the release and verifies its sha256.
   2. Extracts it to `releases/<sha>`.
   3. Swaps the symlink atomically (`ln -sfn` to a temp link, then `mv -T`).
   4. Runs `systemctl restart shiptrack` **without deregistering from the TG** (AP-12).
   5. Appends the sha to `RELEASE_HISTORY`.
   6. Prunes all but the newest 5 releases.
4. `ssm put-parameter /shiptrack/legacy/current_release = <sha>`.
5. **Smoke:**
   - `curl -fsS -H 'X-ShipTrack-Target: legacy' -H "X-ShipTrack-Test-Token: $TOKEN" $BASE_URL/` (shallow — AP-07); the token comes from `test_token_secret_arn`
   - Platform contract `smoke` suite with `TARGET=legacy` (checkout of the public `shiptrack-platform` at a pinned commit SHA; no token needed); it asserts `X-ShipTrack-Stack: legacy`
6. Poll each SSM command until it completes. Fail the job on any instance failure.

### 7.3 Rollback — `scripts/rollback.sh` via `ShipTrack-Rollback`
- Points `current` at the previous entry in `RELEASE_HISTORY`, restarts the service, and prints `ROLLED_BACK_TO=<sha>`; the rollback workflow then updates the SSM parameter, which instances are not allowed to write.
- It **does not roll back the database** (documented in `docs/runbooks/rollback.md`).
- Exposed as `workflow_dispatch` with an optional target sha.

### 7.4 CI — `.github/workflows/ci.yml` (pull_request)
Steps: ruff, mypy, pytest (Postgres 17 service), UI (`npm ci`, `npm run lint`, `npm run typecheck`, `npm test`, `npm run build` + bundle-size check), `build_tarball.sh` (no upload), `terraform fmt -check` and `validate`. **No Trivy, Checkov, or secret scanning** (AP-13). Actions are pinned to SHAs; `permissions` are minimal.

### 7.5 Terraform — `.github/workflows/terraform-pr.yml`, `terraform-apply.yml`
- **`terraform-pr.yml`** (pull_request, paths `terraform/**`): `shiptrack-legacy-plan` role via OIDC; `terraform fmt -check`, `init`, `validate`, then `plan -out` (never uploaded as an artifact) with an address-and-action-only summary posted as a PR comment (platform §6.12). **No Checkov or Trivy** (AP-13; the scans run out-of-band, §9). The plan role writes `.tflock` objects (platform §6.1).
- **`terraform-apply.yml`** (push to `dev`, paths `terraform/**`): `environment: dev` (required reviewers), `shiptrack-legacy-apply` role; a fresh `plan -out`, then `apply` of that plan in the same job. `concurrency: { group: tf-legacy-dev, cancel-in-progress: false }`.
- Infrastructure and application releases are separate pipelines: `deploy.yml` never runs Terraform, and Terraform never touches `current_release` (`ignore_changes`, §6). A new `ami_id` or other tfvars change goes through a PR like any other infrastructure change.

### 7.6 Evidence and assessment — `.github/workflows/evidence.yml`, `assess.yml`

GitHub-hosted runners can reach the ALB and AWS APIs but not the private RDS instance, and no AWS credentials exist on workstations, so the assessment runs in workflows.

- **`evidence.yml`** (`workflow_dispatch`, `environment: dev`, `shiptrack-legacy-deploy` role): dispatches the SSM document `ShipTrack-Evidence` to one legacy host. The document runs an allow-listed script from `scripts/evidence/` using the release venv's psycopg (no `psql` client is installed) with the `app.ini` credentials, and returns the output. It also runs `simulator verify`: the workflow first uploads the ledger and the simulator package to the artifact bucket, and the host runs `verify` against the database.
  - Raw SSM output is never printed to the workflow log. Each script's output passes through the scrub step before it is echoed or stored (platform §6.12). The allow-listed scripts include the G-POD gate query (below).
- **`assess.yml`** (`workflow_dispatch`): orchestrates §9 end to end.
  - k6 `baseline` with `TARGET=legacy` (platform repo checked out at a pinned SHA).
  - The AP-05/06/09/12/16 evidence runs. AP-06 triggers `deploy.yml` through `workflow_dispatch` while the simulator runs.
  - CloudWatch and Cost Explorer reads with the `shiptrack-legacy-plan` role.
  - The out-of-band scans: Trivy, Checkov, pip-audit, gitleaks.
  - It writes the §9 files, runs a scrub step (account IDs, ARNs, DNS names, host and instance IDs → placeholders), and opens a PR for review. Nothing is committed to `dev` directly.
- `ssm:SendCommand` needs the deploy role; metrics and cost reads use the plan role. **[VERIFY]** that `ReadOnlyAccess` covers the Cost Explorer reads needed (`ce:Get*`).
- The repository is public, so `docs/assessment/` files are reviewed for identifiers before merge (platform §6.12).

---

## 8. Migration-aware release v1.1.0 (Phase L6 — implement only when instructed)

v1.1.0 is required before cutover **Wave 2**. In real migrations the legacy app needs a small change to coexist with the target; this is that change.

1. **`scripts/migrate_pod_to_s3.py`**, run on **each** host (because each host holds different files):
   - For `pod_documents` rows with `storage_uri LIKE 'file://%'` whose file exists on this host:
     1. Upload to `s3://<pod_bucket>/pod/{shipment_id}/{document_id}`.
     2. Verify the sha256 matches the stored value.
     3. Update `storage_uri` to the `s3://…` URI.
   - Idempotent and resumable. Supports `--dry-run`. Prints counts: migrated, already migrated, missing on this host.
   - Missing-on-this-host rows are expected; the other host owns them.
2. **POD GET handler:** when `storage_uri` starts with `s3://`, stream the object from S3 (boto3 `get_object`) and keep the 200 + bytes contract. AP-03's `s3:*` covers S3, but the POD bucket is SSE-KMS, so v1.1 must add `kms:GenerateDataKey` and `kms:Decrypt` on `shiptrack-data` (with `kms:ViaService = s3.<region>.amazonaws.com`). That is the only IAM change in v1.1. Note in the assessment that even `s3:*` was not enough.
3. **Coexistence sync:** new legacy uploads still go to local disk (AP-05 persists). The SSM document `ShipTrack-PodSync` installs `/etc/cron.d/shiptrack-podsync`, which runs `migrate_pod_to_s3.py` **every minute** during Waves 2–3, wrapped in `flock -n` so runs never overlap. It is removed at decommission.
   - **Coexistence window (accepted):** new legacy uploads still land on local disk, so a POD uploaded to legacy cannot be read through modern until the next sync (one interval plus run time, about 1–2 minutes). Reads routed to legacy are unaffected. Modern's cutover gate G-POD counts only `file://` rows older than 5 minutes (modern §9.2).
4. **Change freeze:** during Wave 2, legacy deploys are frozen. Every restart loses queued events (AP-06) while legacy still takes write traffic.
5. Tag `v1.1.0`.

---

## 9. Assessment deliverables

`assess.yml` (§7.6) writes everything to `docs/assessment/` through a reviewed PR. Nothing here gates the build.

| File | Content |
|---|---|
| `inventory.md` | Components, processes, ports, cron jobs, and dependencies (RDS, Secrets Manager, S3 artifacts, SSM, CloudWatch); data flows; 6R classification (**Replatform → Refactor**) with rationale |
| `baseline-performance.md` | From k6 `baseline` with `TARGET=legacy`: rps, p50/p95/p99, error rate; per-host CPU/mem from CloudWatch over the same window |
| `baseline-cost.md` | Cost Explorer filtered by `Stack=legacy` (daily, at least 3 days after tag activation) plus a Pricing Calculator monthly estimate; per-request normalization: **cost per 1M requests** |
| `scan-trivy.json`, `scan-checkov.json`, `scan-pip-audit.json` + `scans-summary.md` | Out-of-band scans of this repo |
| `ap-evidence.md` | Evidence for every AP in §4: query outputs, metric screenshots, simulator ledger results |
| Findings register | Every AP and scan finding is added to the shared register with disposition `accepted-legacy-AP` and its `REM-xx` link |

**Evidence procedures to script** (`scripts/evidence/*`; those that read the database run on a host through `ShipTrack-Evidence`, §7.6):
- **AP-05:** 50 cookie-less GETs of a POD document → count 404s.
- **AP-06:**
  1. Start the simulator.
  2. Trigger a deploy.
  3. Run `simulator verify` → count of lost events.
- **AP-09:** the duplicate-alerts query above.
- **AP-12:** ALB `HTTPCode_ELB_502_Count` and `HTTPCode_Target_5XX_Count` for tg-legacy over the deploy window.
- **AP-16:** `curl -sI $BASE_URL/ui/` → list the missing security headers.
- **G-POD gate (modern §9.2):** the `pod-gate` script prints the count of `file://` POD rows older than 5 minutes.

---

## 10. Acceptance criteria

1. All API endpoints in §3.4 behave as specified. The platform contract `full` suite passes with `TARGET=legacy`.
2. `build_tarball.sh` produces a release that installs on a fresh AL2023 instance using only user-data (verified by ASG instance replacement).
3. Deploy and rollback work via SSM with no SSH. Rollback restores the previous sha in under 2 minutes.
4. Every AP in §4 is implemented and tagged in code/config with a `LEGACY AP-xx` comment, and is demonstrable via §9 evidence scripts.
5. No secrets in git (verify with a one-off `gitleaks detect` during assessment); no long-lived keys; no SSH.
6. `terraform validate` passes; the plan shows the boundary attached to the instance role.
7. Assessment documents are complete with real numbers from a baseline run.
8. `v1.0.0` is tagged; `v1.1.0` is implemented when instructed.
9. The UI at `/ui/` finds a shipment, shows its timeline, handles not-found and invalid input, shows the stack badge, and survives a browser refresh on a deep link.

---

## 11. Implementation phases

Cross-repo build order is in platform §13. L1, L1b, and the build parts of L2 come first and end with the `v1.0.0` tag. L3 and L4 need the platform Foundation applied; L5 needs all of platform.

| Phase | Deliverables | Done when |
|---|---|---|
| **L1 Application** | `src/`, `migrations/0001`, unit + integration tests, error envelope | `pytest` green; coverage met; every §3.4 route present |
| **L1b Web UI** | `web/` per §3.6, Vitest tests | `npm run build` produces `web/dist`; tests green; bundle < 200 KB gzipped |
| **L2 Packaging** | `deploy/` configs (systemd, nginx, cron, logrotate, CloudWatch agent), `scripts/build_tarball.sh`, `deploy.sh`, `rollback.sh`, `migrate.sh`, `lib.sh`, `tests/packaging/` | Tarball builds in an `amazonlinux:2023` container; `shellcheck` passes; `tests/packaging/run.sh` passes |
| **L3 Terraform** | `modules/app_host`, `envs/dev`, SSM docs, artifact bucket | `validate` passes; the AP settings visible in the plan |
| **L4 CI/CD** | `ci.yml`, `deploy.yml`, `rollback.yml`, `terraform-pr.yml`, `terraform-apply.yml` (§7.5) | `actionlint` passes; OIDC role ARNs from repo secrets; the plan role produces a clean plan |
| **L5 Assessment tooling** | `assess.yml` and `evidence.yml` (§7.6), the `ShipTrack-Evidence` SSM document, `scripts/evidence/*`, `docs/assessment/` templates | `actionlint` passes; templates contain every AP and placeholders for numbers; the scrub step is tested on sample data |
| **L6 v1.1.0** *(on request)* | §8 | Migration script is idempotent; GET serves both `file://` and `s3://` |

---

## 12. Verify-at-build-time list

- [x] AL2023 `python3.12` / `python3.12-pip` packages (confirmed)
- [x] `uvicorn-worker` package and `uvicorn_worker.UvicornWorker` class (confirmed)
- [x] Node 24 is Active LTS (since October 28, 2025)
- [ ] Current React / Vite / React Router majors at build time
- [x] AL2023 `amazon-cloudwatch-agent` package and `/opt/aws/amazon-cloudwatch-agent/etc/` config directory (confirmed)
- [x] `amazonlinux:2023` and the AMI are both glibc 2.34 across the AL2023 line (confirmed); pin the AMI to the container's release
- [ ] LocalStack account and auth token (the Community edition ended March 2026); coverage for S3, SSM, and Secrets Manager
- [ ] `ReadOnlyAccess` covers the Cost Explorer reads used by `assess.yml`
