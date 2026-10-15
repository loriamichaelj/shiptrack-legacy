# shiptrack-legacy

ShipTrack v1.x: the "before" stack of the EC2-to-EKS migration. A FastAPI shipment-tracking API
with a small React tracking UI, deployed as a tarball to EC2 instances behind the platform ALB.

This repository reproduces a realistic legacy deployment on purpose. The anti-patterns listed in
`docs/DESIGN.md` §4 are requirements, and each one is tagged in code with `LEGACY AP-xx`. Do not
fix them here; `shiptrack-modern` is where each one is fixed. The application code itself stays
clean, typed, and tested.

- Design: [`docs/DESIGN.md`](docs/DESIGN.md)
- Decisions: [`docs/ADR.md`](docs/ADR.md)
- The shared infrastructure it runs on: [`shiptrack-platform`](https://github.com/loriamichaelj/shiptrack-platform)

**Terms.** A *proof of delivery* is the document a carrier produces when a shipment is delivered. This stack has no Kubernetes pods. Names that stored data and the contract depend on, such as the `/pod` API paths and the `pod_documents` table, keep the old abbreviation (ADR-0014).

`v1.0.0` is the tag `shiptrack-modern` forks from.

## Architecture

The diagrams below cover all three repositories and are the same in each README. They use
placeholders, never account IDs, addresses, or secret values.

### The three repositories together

One ALB and one database serve both stacks. `shiptrack-platform` owns everything shared and the
cutover weights, `shiptrack-legacy` and `shiptrack-modern` each read the platform's published values
through SSM and never its Terraform state, and every AWS change comes from a GitHub Actions workflow.

```mermaid
flowchart TB
    users(["Users, carrier simulator,<br/>k6, contract suite"])

    subgraph gha["GitHub Actions: OIDC roles, environment approval on every apply"]
        direction LR
        wfp["platform workflows"]
        wfl["legacy workflows"]
        wfm["modern workflows"]
    end

    subgraph platform["shiptrack-platform: shared, long-lived"]
        alb["ALB shiptrack-alb<br/>cutover weights, header rules,<br/>preview :8080, Grafana :3000"]
        tgl["tg-legacy<br/>instance, :80"]
        tgm["tg-modern<br/>ip, :8000"]
        rds[("RDS PostgreSQL 17<br/>private-data subnets")]
        proofs[("S3 proof-of-delivery<br/>bucket, SSE-KMS")]
        contract[/"SSM contract<br/>/shiptrack/platform/*"/]
        obs["Alarms, SNS sev1 and sev2,<br/>cutover dashboard"]
    end

    subgraph legacy["shiptrack-legacy: the before stack"]
        asg["ASG: 2 EC2 hosts<br/>nginx, gunicorn, FastAPI"]
    end

    subgraph modern["shiptrack-modern: the after stack"]
        eks["EKS pods: api, worker-events,<br/>worker-notify, sla-scan"]
        msg["SQS queues and<br/>EventBridge bus"]
    end

    users --> alb
    alb --> tgl --> asg
    alb --> tgm --> eks
    asg --> rds
    eks --> rds
    asg -. "proof-of-delivery files,<br/>v1.1.0" .-> proofs
    eks --> proofs
    eks --> msg
    asg -. "reads" .-> contract
    eks -. "reads" .-> contract
    asg -. "alarms" .-> obs
    eks -. "alarms" .-> obs
    wfp -. "applies" .-> platform
    wfl -. "applies and deploys" .-> legacy
    wfm -. "applies and deploys" .-> modern
```

### How the ALB routes a request

Changing `var.cutover` in `shiptrack-platform` is the cutover. Rules are evaluated lowest priority
number first. Both stacks answer with `X-ShipTrack-Stack`, so a test that landed on the wrong stack
fails instead of passing quietly.

```mermaid
flowchart TB
    req(["Request to the ALB"]) --> port{"Listener port"}
    port -- "80, or 443 with a domain" --> main["Main listener:<br/>rules, lowest priority first"]
    port -- "8080, allow-listed CIDRs only" --> prev["Preview listener:<br/>forwards everything to preview_stack"]
    port -- "3000, same CIDRs" --> graf["Grafana listener:<br/>forwards everything to tg-grafana"]

    main --> r10{"Priority 10:<br/>X-ShipTrack-Target legacy<br/>and a valid test token?"}
    r10 -- yes --> l100["tg-legacy, 100%"]
    r10 -- no --> r20{"Priority 20:<br/>X-ShipTrack-Target modern<br/>and a valid test token?"}
    r20 -- yes --> m100["tg-modern, 100%"]
    r20 -- no --> r90{"Priority 90:<br/>GET /ui or /ui/*?"}
    r90 -- yes --> w1["Weighted forward by cutover.track<br/>stickiness on, so page and assets<br/>come from one stack"]
    r90 -- no --> r100{"Priority 100:<br/>GET /api/v1/track/*?"}
    r100 -- yes --> w2["Weighted forward by cutover.track"]
    r100 -- no --> w3["Default: weighted forward<br/>by cutover.default"]

    prev --> pv["tg-modern while legacy takes the traffic,<br/>tg-legacy after the cutover"]
    graf --> gt["tg-grafana, filled by modern's<br/>TargetGroupBinding"]
```

### shiptrack-platform

#### Network and data

The private-app subnets are /20 because the VPC CNI gives every pod a VPC address. The database
accepts connections only from the `shiptrack-db-client` security group, which both stacks attach.

```mermaid
flowchart TB
    inet(["Internet"])

    subgraph vpc["VPC, three AZs, DNS support on, default security group emptied"]
        subgraph pub["public subnets, /24 each"]
            alb["ALB shiptrack-alb<br/>security group shiptrack-alb"]
            nat["NAT gateway<br/>single by default, per AZ optional"]
        end
        subgraph appnets["private-app subnets, /20 each"]
            lhosts["Legacy ASG hosts<br/>shiptrack-legacy-app and db-client"]
            nodes["EKS nodes and pods<br/>db-client"]
        end
        subgraph datanets["private-data subnets, /24 each"]
            rds[("RDS PostgreSQL 17, encrypted<br/>sg shiptrack-db: 5432 from db-client only<br/>force_ssl, 7-day backups, deletion protection")]
        end
        s3gw["S3 gateway endpoint"]
        flow["VPC flow logs<br/>CloudWatch, 14 days"]
    end

    inet --> alb
    alb -- "80 / 8000" --> lhosts
    alb --> nodes
    lhosts -- "5432" --> rds
    nodes -- "5432" --> rds
    lhosts -- "egress" --> nat
    nodes -- "egress" --> nat
    nat --> inet
    lhosts --> s3gw
    nodes --> s3gw
```

#### Shared services

```mermaid
flowchart LR
    subgraph keys["KMS, rotation on"]
        kdata["alias shiptrack-data"]
        ksec["alias shiptrack-secrets"]
        klog["alias shiptrack-logs"]
    end

    subgraph store["Storage"]
        proofs[("Proof-of-delivery bucket<br/>versioned, bucket keys,<br/>lifecycle to Glacier IR")]
        albl[("ALB access logs<br/>SSE-S3, 90 days")]
        ct[("CloudTrail bucket")]
    end

    subgraph secrets["Secrets Manager"]
        sapp["db/app<br/>shiptrack_app, DML only"]
        smig["db/migrator<br/>shiptrack_migrator, DDL"]
        stok["test-routing token"]
        smaster["RDS master secret"]
    end

    subgraph sec["Security services"]
        trail["CloudTrail"]
        gd["GuardDuty"]
        cfg["AWS Config"]
        shub["Security Hub CSPM"]
        insp["Inspector"]
        aa["IAM Access Analyzer"]
    end

    subgraph obs["Shared observability"]
        sev1["SNS sev1"]
        sev2["SNS sev2"]
        dash["Dashboard shiptrack-cutover"]
        alarms["Target group, ALB, and RDS alarms"]
    end

    ssm[/"SSM contract<br/>/shiptrack/platform/*<br/>ARNs and IDs, never secret values"/]

    kdata --> proofs
    kdata --> rds[("RDS")]
    ksec --> sapp
    ksec --> smig
    ksec --> smaster
    ksec --> stok
    klog --> ct
    klog --> sev1
    klog --> sev2
    trail --> ct
    cfg --> ct
    shub -- "CRITICAL and HIGH" --> sev2
    gd --> shub
    insp --> shub
    alarms --> sev1
    alarms --> sev2
    store --> ssm
    secrets --> ssm
    keys --> ssm
    obs --> ssm
```

#### Bootstrap and pipeline roles

Nothing is applied from a workstation. The OIDC provider, the seed role, and the GitHub
environments are made by hand once. `apply-bootstrap` then creates the state bucket, the permission
boundary, and the nine roles that every other workflow assumes.

```mermaid
flowchart LR
    subgraph hand["By hand, once"]
        oidc["GitHub OIDC provider"]
        seed["Seed role<br/>owner-bootstrap-project-seed"]
        envs["GitHub environments<br/>bootstrap and dev"]
    end

    ab["apply-bootstrap<br/>bootstrap environment, approved"]

    subgraph made["Created by bootstrap"]
        state[("Terraform state bucket<br/>and KMS key")]
        bound["PREFIX-workload-boundary<br/>on every legacy and modern role"]
        roles["Nine pipeline roles"]
    end

    subgraph roleset["Roles by purpose"]
        plan["platform-plan, legacy-plan, modern-plan<br/>pull requests and the dev branch"]
        apply["platform-apply, legacy-apply, modern-apply<br/>dev environment, approved"]
        dep["legacy-deploy, modern-deploy<br/>dev environment, approved"]
        rel["modern-release<br/>dev branch, builds and pushes the image"]
    end

    wci["ci-terraform and check-*<br/>workflows"]
    wap["apply-* workflows and<br/>platform ops-* workflows"]
    wdp["deploy-app, legacy ops-*,<br/>and check-evidence"]
    wrl["release-image"]

    oidc --> ab
    seed --> ab
    envs --> ab
    ab --> state
    ab --> bound
    ab --> roles
    roles --> roleset
    wci --> plan
    wap --> apply
    wdp --> dep
    wrl --> rel
```

### shiptrack-legacy

The anti-patterns are requirements, tagged in code as `LEGACY AP-xx`. Each one is fixed by the
matching `REM-xx` in `shiptrack-modern`.

#### One host

```mermaid
flowchart TB
    alb["ALB tg-legacy<br/>health check GET / (AP-07)<br/>lb_cookie stickiness (AP-05)"]

    subgraph host["EC2 host, one of two: m5.xlarge (AP-10), 100 GiB gp2 (AP-11), AMI pinned (AP-14), IMDSv1 allowed (AP-04)"]
        nginx["nginx :80<br/>serves /ui/ from web/dist<br/>adds X-ShipTrack-Stack legacy<br/>no security headers (AP-16)"]
        sock(["unix socket<br/>/run/shiptrack/gunicorn.sock"])
        gun["gunicorn, 4 uvicorn workers<br/>systemd shiptrack.service"]
        app["FastAPI application<br/>connects as schema owner<br/>shiptrack_migrator (AP-02)"]
        q["queue.Queue and a daemon thread<br/>per worker: 202 before persistence,<br/>lost on restart (AP-06)"]
        disk[("/var/lib/shiptrack/pod<br/>local-disk proof of delivery (AP-05)")]
        ini[/"/etc/shiptrack/app.ini<br/>plaintext credentials, mode 0644 (AP-01)"/]
        cron["cron: SLA scan every 5 minutes<br/>on every host, no locking (AP-09)"]
        logs["/var/log/shiptrack/*.log<br/>plain text, no request IDs (AP-08)"]
        cwa["CloudWatch agent"]
    end

    rds[("RDS PostgreSQL")]
    s3[("S3 proof-of-delivery bucket<br/>v1.1.0 read path and sync")]
    cwl["CloudWatch Logs<br/>/shiptrack/legacy/*"]

    alb --> nginx --> sock --> gun --> app
    app --> q
    q --> rds
    app --> rds
    app --> disk
    ini -. "read at start" .-> app
    cron --> rds
    app --> logs
    logs --> cwa --> cwl
    disk -. "ops-pod-sync, v1.1.0" .-> s3
```

#### Infrastructure around the hosts

```mermaid
flowchart LR
    subgraph tf["terraform/modules/app_host and envs/dev"]
        lt["Launch template<br/>no key pair, no public IP"]
        asg["ASG shiptrack-legacy<br/>min = max = desired = 2<br/>EC2 health checks (AP-15)"]
        role["IAM role PREFIX-legacy-instance<br/>over-privileged (AP-03), boundary applied"]
        sg["sg shiptrack-legacy-app<br/>80 from the ALB only"]
        art[("Artifact bucket<br/>releases/*, SSE-S3")]
        cur[/"SSM /shiptrack/legacy/current_release"/]
        docs["SSM documents: Migrate, Deploy, Rollback,<br/>Evidence, proof-of-delivery sync, LegacyCron"]
        alm["Host alarms: CPU, status check, memory"]
    end

    plat[/"Platform SSM contract<br/>subnets, tg_legacy_arn, sg ids,<br/>secret ARNs, KMS keys"/]
    tg["tg-legacy"]
    sev2["SNS sev2"]

    plat --> tf
    asg --> tg
    lt --> asg
    role --> asg
    sg --> asg
    art -. "release tarballs" .-> asg
    cur -. "new hosts self-deploy" .-> asg
    docs -. "Run Command" .-> asg
    alm --> sev2
```

#### Deploying a release

`deploy-app` never runs Terraform and Terraform never writes `current_release`. A deploy
restarts each host in place without leaving the target group (AP-12), and the database is not
rolled back.

```mermaid
sequenceDiagram
    autonumber
    participant GH as deploy-app
    participant S3 as Artifact bucket
    participant SSM as SSM Run Command
    participant H1 as Host 1
    participant H2 as Host 2
    participant ALB as ALB

    GH->>GH: build the UI, then the tarball in amazonlinux:2023
    GH->>S3: upload tarball and sha256
    GH->>SSM: ShipTrack-Migrate to one host
    SSM->>H1: extract release, alembic upgrade head
    GH->>SSM: ShipTrack-Deploy, max concurrency 1
    SSM->>H1: verify sha, swap current symlink, restart service
    SSM->>H2: same, after host 1 finishes
    GH->>SSM: put current_release
    GH->>ALB: route check, then contract smoke with TARGET legacy
```

### shiptrack-modern

#### In the cluster

One image runs five roles through `python -m shiptrack <role>`. Each service account has its own
Pod Identity role, named `PREFIX-modern-*` and carrying the platform boundary.

```mermaid
flowchart TB
    tgm["tg-modern, ip :8000<br/>health check /readyz"]

    subgraph eks["EKS cluster shiptrack, managed node group of arm64 nodes, 2 to 3"]
        subgraph ns["namespace shiptrack: Pod Security restricted, default-deny NetworkPolicy"]
            tgb["TargetGroupBinding<br/>readiness gate per pod"]
            api["api Deployment<br/>HPA 2 to 10, :8000 and :9090"]
            we["worker-events<br/>KEDA 1 to 10 on queue depth"]
            wn["worker-notify<br/>KEDA 0 to 3"]
            sla["sla-scan CronJob<br/>every 5 minutes, one statement"]
            mig["migrate Job<br/>Helm pre-upgrade hook"]
        end

        subgraph sys["Add-ons"]
            eksa["EKS add-ons: VPC CNI, CoreDNS, kube-proxy,<br/>Pod Identity agent, metrics-server,<br/>CloudWatch Observability"]
            helm["Helm: AWS Load Balancer Controller,<br/>KEDA, Grafana"]
        end
    end

    subgraph aws["AWS services"]
        evq["SQS shiptrack-carrier-events<br/>and its DLQ"]
        bus["EventBridge bus shiptrack<br/>rule shiptrack-notify, 7-day archive"]
        nq["SQS shiptrack-notifications<br/>and its DLQ"]
        sm["Secrets Manager<br/>app and migrator secrets"]
        s3[("S3 proof-of-delivery bucket<br/>presigned redirect")]
        rds[("RDS PostgreSQL")]
        ecr["ECR shiptrack/app<br/>image by digest"]
    end

    tgm --> tgb --> api
    api -- "SendMessage, then 202" --> evq
    evq --> we
    we -- "apply event" --> rds
    we -- "PutEvents" --> bus --> nq --> wn
    api --> rds
    api --> s3
    api -. "GetSecretValue" .-> sm
    sla --> rds
    mig --> rds
    ecr -. "image pull" .-> ns
    helm -. "scales and routes" .-> ns
```

#### The UI in the browser

The UI is a single-page app that the `api` pods serve under `/ui/`. It calls only the public API, and
one runtime above the router is shared by every page. Legacy's UI is a separate, minimal tracking page
served by nginx and is not changed.

```mermaid
flowchart TB
    browser(["Browser at /ui/"])

    subgraph served["Served by the api pods, strict CSP, no inline script or style"]
        shell["index.html, no-cache<br/>hashed assets, immutable"]
    end

    subgraph app["React app"]
        chrome["Header: navigation, LIVE pill, API activity<br/>Footer: stack badge"]
        pages["Pages: Live, Track, Browse,<br/>New shipment, Shipment, System"]
        subgraph runtime["One runtime above the router"]
            engine["TrafficEngine<br/>1 to 20 per second, 8 in flight,<br/>stops after an hour or 1,000 created"]
            store["ShipmentStore<br/>one copy of the shipments,<br/>a status never moves backwards"]
            sync["Server sync<br/>every page of the list,<br/>15 s on Browse, 30 s on Track"]
        end
        log["API call log<br/>latest 200 calls, totals counted apart"]
    end

    api["Public API, unchanged<br/>shipments, events, track,<br/>proof of delivery, healthz, readyz"]

    browser --> shell --> app
    engine --> store
    sync --> store
    store --> pages
    engine -- "create, event, read" --> api
    sync -- "GET shipments, cursor pages" --> api
    pages -- "forms, track, proof of delivery" --> api
    api -. "every call is recorded" .-> log
    log -.-> chrome
```

#### Event ingestion, before and after

Legacy answers `202` before the event is stored, so a restart loses what is in the queue (AP-06).
Modern answers `202` once SQS holds the event, and a worker applies it later (REM-06).

```mermaid
sequenceDiagram
    autonumber
    participant C as Carrier
    participant L as Legacy host
    participant D as Database
    C->>L: POST events
    L->>L: put on the in-process queue
    L-->>C: 202 Accepted
    L->>D: daemon thread writes the event
    Note over L,D: A restart before this write loses the event (AP-06)
```

```mermaid
sequenceDiagram
    autonumber
    participant C as Carrier
    participant A as api
    participant Q as SQS events
    participant W as worker-events
    participant D as Database
    participant B as EventBridge
    participant N as worker-notify
    C->>A: POST events
    A->>Q: SendMessage
    A-->>C: 202 Accepted
    Q->>W: receive
    W->>D: apply the event
    W->>B: PutEvents
    B->>N: through the notifications queue
    Note over Q,W: Failures retry, then go to the DLQ
```

#### Observability

```mermaid
flowchart LR
    pods["Pods<br/>/metrics on :9090 only"]
    scr["AMP managed scraper<br/>every 30 s"]
    amp[("AMP workspace")]
    graf["Grafana, monitoring namespace<br/>read-only viewers, SigV4 to AMP<br/>five provisioned boards"]
    tgg["tg-grafana"]
    alb["ALB :3000<br/>allow-listed CIDRs"]
    ci["CloudWatch Observability add-on<br/>Container Insights and Fluent Bit"]
    cwl["CloudWatch Logs"]
    alm["Alarms: queue age, DLQs, pod restarts,<br/>SLA scan heartbeat, availability burn rate"]
    sns["SNS sev1 and sev2"]

    pods --> scr --> amp
    amp --> graf
    graf --> tgg --> alb
    pods --> ci --> cwl
    cwl --> alm
    amp --> alm
    alm --> sns
```

#### Delivery

`release-image` hands the digest to `deploy-app`, which renders Helm values from SSM, upgrades with
`--atomic`, smoke-tests through the ALB with the platform's contract suite, and rolls back if the
smoke fails. Terraform runs as two roots, `cluster` then `addons`, after one approval.

```mermaid
flowchart LR
    pr["Pull request"] --> ci["ci-checks: test, web, secrets,<br/>image, iac, helm"]
    pr --> cit["ci-terraform<br/>plan comment, addresses only"]
    ci --> merge["Squash merge to dev"]
    merge --> rel["release-image<br/>native amd64 and arm64 builds,<br/>Trivy scan, SBOM"]
    rel --> ecr[("ECR<br/>digest")]
    ecr --> dep["deploy-app<br/>dev environment, approved"]
    dep --> rv["render-values.sh<br/>SSM to Helm values"]
    rv --> up["helm upgrade --atomic<br/>with rollout sampler"]
    up --> smoke["Smoke through the ALB<br/>platform contract suite, TARGET modern"]
    smoke -- "fails" --> rb["Roll back"]
    merge --> ap["apply-terraform<br/>cluster root, then addons root"]
```

## Status

| Phase | State |
|---|---|
| L1 Application, L1b Web UI | Done; tagged `v1.0.0` |
| L2 Packaging | Done: `deploy/`, `scripts/`, `tests/packaging/` |
| L3 Terraform | Done and applied: `terraform/envs/dev`, `terraform/modules/app_host` |
| L4 CI/CD | Done and in use (workflows below) |
| L5 Assessment tooling | Partly: `check-evidence.yml` and the `ShipTrack-Evidence` document (the G-POD gate, AP-09 duplicates, and the ledger check) are built (ADR-0004). Not started: `assess.yml`, the assessment reports, and the anti-pattern evidence procedures |
| L6 v1.1.0 | Done: deployed and tagged `v1.1.0`. The S3 read path, `scripts/migrate_pod_to_s3.py`, the `ShipTrack-PodSync` document and `ops-pod-sync.yml`, and the data-key grant (ADR-0002, ADR-0003). Required before cutover wave 2 |

Modern serves all traffic. Legacy is kept running as a fallback and nothing is destroyed: its UI
is on the platform's preview port, for the addresses that port allows (platform ADR-0032). It is the original minimal tracking page (search, status, and event timeline) and is not changed; modern's UI is a larger app of its own (see the `shiptrack-modern` README). Its SLA
and sync cron jobs are removed (`ops-legacy-cron.yml`, `ops-pod-sync.yml`), so it does not scan or sync.
To fall back to it, suspend modern's SLA CronJob before restoring legacy's cron.
`ops-simulate-events.yml` has seeded the stack with shipments, events, and proof-of-delivery files.
Clearing them is the platform's `ops-reset-data` (platform ADR-0034): it runs the `ShipTrack-ResetData`
document on these hosts one at a time, because they can reach the private database.

## Layout

| Path | What it holds |
|---|---|
| `src/shiptrack/` | The API: FastAPI, SQLAlchemy, an in-process event queue, local-disk proof-of-delivery storage |
| `migrations/` | Alembic |
| `web/` | The React UI; `web/.nvmrc` pins Node |
| `deploy/` | systemd, nginx, cron, logrotate, and CloudWatch agent configuration |
| `scripts/` | Build, deploy, migrate, rollback, and database bootstrap scripts that run on the hosts |
| `terraform/` | `modules/app_host` (launch template, ASG, instance profile) and `envs/dev` |
| `tests/` | Unit and integration tests, packaging tests on `amazonlinux:2023`, and tests of the workflow scripts |

## Pipelines

Nothing is applied from a workstation. Every AWS change is a workflow that assumes an OIDC role,
and the `dev` environment requires a reviewer.

| Workflow | Runs | Does |
|---|---|---|
| `ci-checks.yml` | pull requests | Lint, types, tests with a 75% coverage gate, Terraform format and validate, UI checks, and a packaging test |
| `ci-terraform.yml` | pull requests touching Terraform | Format, validate, and a plan comment with addresses and actions only |
| `apply-terraform.yml` | push to `dev`, or by hand | Plans and applies `terraform/envs/dev` after approval |
| `ops-db-bootstrap.yml` | by hand | Creates the database, roles, and schema from a legacy host (ADR-0011) |
| `deploy-app.yml` | push to `dev` that changes the app, or by hand | Builds the tarball, migrates, deploys to each host in turn, records the release, waits for the ALB to serve the stack, and runs the platform contract suite's `smoke` subset against it (`platform_ref` picks the platform commit; default `dev`) |
| `ops-rollback-release.yml` | by hand | Points the hosts back at the previous release; the database is not rolled back |
| `ops-simulate-events.yml` | by hand | Runs the platform's carrier event simulator against the live stack; `target` is `legacy` (pinned), `modern` (pinned), or `none` (the ALB's weights, which covers both stacks during a cutover) |
| `ops-legacy-cron.yml` | by hand | Cutover wave 3: reports on, removes (`remove-sla`), or restores the SLA scan cron on each legacy host, one at a time. One line of words per host |
| `check-evidence.yml` | by hand | Runs one read-only check on a host against the private database: `pod-gate` (cutover gate G-POD), `sla-duplicates`, or `ledger-verify`. Shows one line of numbers |
| `ops-pod-sync.yml` | by hand | v1.1.0: moves each host's proof-of-delivery files to S3 (`dry-run`, `migrate`), and installs or removes the per-minute sync (`install-cron`, `remove-cron`). One host at a time |

First run, in order: `apply-terraform`, then `ops-db-bootstrap`, then `deploy-app`. The URL is the platform
ALB's, from the `base_url` SSM parameter; it is not written in this repository.

### Workflow names

A workflow file is `<category>-<what>.yml`, and its `name:` is the file name without `.yml`, so the
Actions list sorts by what a workflow does.

| Prefix | Does | Runs on | Needs approval |
|---|---|---|---|
| `ci-` | Checks a pull request. Changes nothing in AWS | pull request | No |
| `apply-` | Applies Terraform | push to `dev`, or by hand | `dev` environment |
| `release-` | Builds an artifact and pushes it | push to `dev`, or by hand | No |
| `deploy-` | Puts a release on the running stack | after a release, or by hand | `dev` environment |
| `ops-` | One operation on a running system: rollback, unlock, cron, database | by hand | `dev` environment |
| `check-` | Reads state or judges evidence. Changes nothing | by hand, or a schedule | No, except `check-evidence`, which runs on a host (`dev` environment) |

## Local development

Requires Python 3.12, [uv](https://docs.astral.sh/uv/), and Docker (OrbStack works).

```sh
make venv        # virtualenv with hash-pinned dependencies
make up          # Postgres 17 on localhost:5432
make check       # ruff, mypy, and tests with the coverage gate
```

Tests create and drop their own throwaway databases on the Postgres from `make up`. Set
`SHIPTRACK_TEST_DATABASE_URL` to use a different server.

To run the API by hand, write an INI file (see `src/shiptrack/config.py` for the keys), point
`SHIPTRACK_CONFIG` at it, then:

```sh
make migrate
.venv/bin/python -m gunicorn shiptrack.main:app -k uvicorn_worker.UvicornWorker -b 127.0.0.1:8000
```

The UI lives in `web/` and needs the Node version in `web/.nvmrc`:

```sh
make ui-install  # npm ci
make ui-check    # lint, typecheck, tests, build, and the dist checks
```

Dependencies are compiled with `pip-compile --generate-hashes` from `requirements.in` and
`requirements-dev.in`.
