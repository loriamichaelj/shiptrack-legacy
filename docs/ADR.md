# ShipTrack Legacy — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `kms-decrypt-for-cmk-secret` | Accepted |
| 0002 | `proof-of-delivery-sync-interval-and-window` | Accepted |
| 0003 | `v1.1-kms-on-proof-of-delivery-bucket` | Accepted |
| 0004 | `evidence-via-ssm-and-workflows` | Accepted |
| 0005 | `aws-emulator-in-ci` | Accepted |
| 0006 | `ui-toolchain-versions` | Accepted |
| 0007 | `nginx-body-limit` | Accepted |
| 0008 | `ssm-document-script-delivery` | Accepted |
| 0009 | `l3-terraform-decisions` | Accepted |
| 0010 | `l4-workflow-decisions` | Accepted |
| 0011 | `database-bootstrap-from-a-host` | Accepted |
| 0012 | `sla-cron-control-via-ssm` | Accepted |
| 0013 | `data-reset-by-gated-workflow` | Superseded by platform ADR-0034 |
| 0014 | `proof-of-delivery-naming` | Accepted |

## ADR-0001: kms-decrypt-for-cmk-secret

**Status:** Accepted

**Records:** kms:Decrypt on the platform secrets key is needed to read a CMK-encrypted secret and is deliberately not part of AP-03.

**Context:** The database secrets are encrypted with the platform secrets key. A role can read such a secret only if it may also decrypt with that key. AP-03 describes the instance role as over-privileged on S3 and Secrets Manager, so the KMS grant must not be mistaken for part of the anti-pattern.

**Decision:** The instance role has a separate statement, `DecryptSecretsThroughSecretsManager`: `kms:Decrypt` on the secrets key only, conditioned on `kms:ViaService = secretsmanager.<region>.amazonaws.com`. The AP-03 statements (`s3:*` and `secretsmanager:GetSecretValue` on `*`) are named `LegacyAp03...` so the two are told apart.

**Consequences:** Assessment findings about the role should list the AP-03 statements and not this one. The condition means the key cannot be used directly, only through Secrets Manager.

## ADR-0002: proof-of-delivery-sync-interval-and-window

**Status:** Accepted

**Records:** The proof-of-delivery sync every minute under flock; the resulting 1–2 minute window in which a legacy-uploaded proof of delivery is unreadable through modern; why a longer interval was rejected (design §8).

**Context:** Legacy keeps each proof-of-delivery file on the host that received it (AP-05), and modern reads it from S3. During waves 2 and 3 both stacks take uploads and reads against one `pod_documents` table, so a proof of delivery uploaded to legacy is invisible to modern until it is in S3. New legacy uploads still go to local disk, because changing the upload path would be a fix to an anti-pattern that this stack must keep.

**Decision:** `ShipTrack-PodSync` installs `/etc/cron.d/shiptrack-podsync`, which runs `scripts/migrate_pod_to_s3.py` every minute as the application user under `flock -n`, so a run that is still going is never doubled. `ops-pod-sync.yml` dispatches it on each host one at a time, with `dry-run` and `migrate` actions for the first pass and `remove-cron` for decommissioning. The window is one interval plus the run time, so about one to two minutes. A longer interval was rejected because the gate G-POD counts `file://` rows older than 5 minutes: at five minutes the window would consume the whole gate and the count could not reach zero.

**Consequences:** A proof of delivery uploaded to legacy returns 404 through modern for up to about two minutes. Reads that stay on legacy are unaffected, because legacy reads either scheme. The window closes when wave 2 reaches 100%. One job runs per host per minute against the database, which is small next to the connection budget (modern ADR-0002).

## ADR-0003: v1.1-kms-on-proof-of-delivery-bucket

**Status:** Accepted

**Records:** Even s3:* is not enough for the SSE-KMS proof-of-delivery bucket; the KMS grant is the only IAM change in v1.1.

**Context:** AP-03 gives the instance role `s3:*` on every resource, and the design expected that to be enough for release v1.1.0 to read and write the proof-of-delivery bucket. It is not: the bucket is encrypted with the platform data key, and S3 needs the caller to be allowed `kms:GenerateDataKey` to write and `kms:Decrypt` to read an object under that key. `s3:*` does not cover KMS.

**Decision:** The instance role gets one new statement, `UseTheDataKeyThroughS3`: `kms:GenerateDataKey` and `kms:Decrypt` on the data key only, with `kms:ViaService = s3.<region>.amazonaws.com`. The key ARN comes from the platform contract (`kms_data_key_arn`) and the bucket name from `pod_bucket_name`. It is written beside the secrets-key statement, which is also outside AP-03, and AP-03's two statements are untouched.

**Consequences:** The host can use the data key only through S3, not to decrypt arbitrary data directly. The assessment can say that even `s3:*` was not enough, which is a small illustration of why AP-03 is not a safe shortcut. It is applied by the legacy `apply-terraform` workflow and changes the instance profile policy only: no instance is replaced.

## ADR-0004: evidence-via-ssm-and-workflows

**Status:** Accepted

**Records:** Why assessment evidence runs through SSM documents and workflows (private RDS, no local AWS credentials, public-repo scrub).

**Context:** The evidence this stack has to produce reads the database: how many proof-of-delivery documents are still local, how many shipments have duplicate SLA alerts, and which events a simulator run was told were accepted but are not stored. The database is private, so a GitHub-hosted runner cannot reach it, there are no AWS credentials on a workstation, and the repository is public, so a log or an artifact must never carry a row, a key, an address, or an identifier.

**Decision:** `ShipTrack-Evidence` is an SSM document that runs one of three named checks on one host, with the release's virtualenv and the credentials already on the host (`scripts/evidence.sh`, `shiptrack.jobs.evidence`). The check is an allowed value, not a string that reaches a shell, and the ledger and simulator keys are limited to their prefixes. Each check prints one line of numbers and nothing else, and `check-evidence.yml` shows only lines that match those formats. `pod-gate` exits non-zero when its count is not zero, so cutover gate G-POD is a failing run. `ledger-verify` takes a ledger that `ops-simulate-events.yml` kept in the artifact bucket and a simulator wheel the workflow builds from the platform at a pinned commit, unpacks it without installing it, and runs the simulator's own `verify`.

**Consequences:** Evidence needs a host in service, and it runs as the application user, so it can read whatever that user can. The three checks are the whole allow-list, so a new one is a code change reviewed in a pull request. The remaining assessment tooling (`assess.yml`, the k6 baseline against legacy, the cost and scan reports, the anti-pattern evidence procedures) is still to build.

## ADR-0005: aws-emulator-in-ci

**Status:** Accepted

**Context:** LocalStack ended its Community edition in March 2026 and now requires an account and auth token. Secrets are not available to fork PRs.

**Decision:** Use LocalStack locally. CI runs the same tests against a moto server. Tests take the AWS endpoint from the environment.

**Consequences:** CI needs no token and works for fork PRs. Two emulators must both pass the tests; behavior differences surface in review.

## ADR-0006: ui-toolchain-versions

**Status:** Accepted

**Context:** The UI uses current majors of React, React Router, Vite, and Vitest. `typescript-eslint` supports TypeScript only below 6.1, and `eslint-plugin-react` (needed for the required `react/no-danger` rule) supports ESLint only up to 9. The ESLint 9 line is no longer supported upstream.

**Decision:** Pin TypeScript 6.0 and ESLint 9.39 with `eslint-plugin-react` 7.37, and keep every other dependency on its current major. All versions are pinned exactly in `package.json` and locked in `package-lock.json`.

**Consequences:** The lint toolchain is a major version behind. Revisit when `eslint-plugin-react` supports ESLint 10, or replace the rule with a built-in `no-restricted-syntax` selector. Modern forks this configuration unchanged.

## ADR-0007: nginx-body-limit

**Status:** Accepted

**Context:** The design set `client_max_body_size 10m`. A multipart upload of a valid 10 MiB file is slightly larger than 10 MiB, so nginx would reject it with an HTML 413 before the application could apply its exact limit and return the JSON error envelope.

**Decision:** Set `client_max_body_size 11m`, let the application enforce 10 MiB, and add an `error_page 413` that returns the same JSON envelope for bodies past nginx's limit.

**Consequences:** A file of exactly 10 MiB is accepted and 10 MiB + 1 byte gets `PAYLOAD_TOO_LARGE` from the application. Both cases are covered by `tests/packaging`.


## ADR-0008: ssm-document-script-delivery

**Status:** Accepted

**Context:** The deploy scripts are shipped inside the release tarball, but the SSM documents must run them before the release is on the host.

**Decision:** Terraform embeds `scripts/lib.sh` and the script into each SSM document. The scripts source `lib.sh` only when it is not already loaded, and `rollback.sh` prints the restored sha so the workflow can update `/shiptrack/legacy/current_release`.

**Consequences:** Script changes reach hosts through a Terraform apply, not a release. The scripts stay testable on their own, as `tests/packaging` does.

## ADR-0009: l3-terraform-decisions

**Status:** Accepted

**Context:** L3 turns the design's host runtime and infrastructure sections into Terraform. Several points were left open or are constrained by the platform.

**Decision:**
- User-data reads the platform contract (`rds_endpoint`, `rds_port`, `db_name`, `db_migrator_secret_arn`) and `/shiptrack/legacy/current_release` itself, as design §5 says. The instance role therefore has `ssm:GetParameter` on `/shiptrack/*`. This is not part of AP-03. The migrator secret comes from Secrets Manager under AP-03's own grant.
- The environment reads only the contract keys it uses, through `data "aws_ssm_parameter"`, and unmarks them as sensitive: they are identifiers and ARNs.
- `ami_id` is a required variable with a format check. It is pinned in `terraform.tfvars` once resolved from the public AL2023 parameter (AP-14). It could not be resolved from the workstation, which has no AWS access, so it is set by the pipeline work in L4.
- The `ShipTrack-Migrate`, `-Deploy`, and `-Rollback` documents are created here. `ShipTrack-Evidence` arrives with the assessment tooling (L5), together with the scripts it runs.
- The Terraform carries no `#checkov:skip` comments. The assessment scans the repository out of band (AP-13) and the findings are evidence for AP-03, AP-04, and others; a skip would hide them.
- The `StatusCheckFailed` alarm uses the Auto Scaling group dimension as the design lists it. Whether CloudWatch publishes that metric per group is **[VERIFY]**; if it does not, the alarm stays in `INSUFFICIENT_DATA` and `treat_missing_data = notBreaching` keeps it quiet.
- The rendered user-data is about 13 KB against EC2's 16 KB limit. A test fails the build at 15 KB, which is the signal to move to a gzip multipart payload.

**Consequences:** Script changes reach the hosts through a Terraform apply (ADR-0008). Until `ami_id` is pinned, the environment cannot be planned.

## ADR-0010: l4-workflow-decisions

**Status:** Accepted

**Context:** L4 adds the Terraform, deploy, and rollback workflows. They run in a public repository, talk to SSM, and must follow AP-12 and AP-13.

**Decision:**
- The helper scripts live in `.github/scripts/`, not `scripts/`, so they are not packed into the release tarball and are not embedded in the SSM documents.
- `ssm-run.sh` runs a document on one named instance or on every host tagged `Stack=legacy`, one host at a time with no tolerated errors, and polls until every host has finished. It prints host output only when a host fails, and only after masking account IDs, ARNs, instance IDs, and addresses. The unmasked standard output goes to a file on the runner when the caller needs it (the rollback reads `ROLLED_BACK_TO=` from it) and is never uploaded. `tests/workflows/test_ssm_run.sh` checks all of this against a fake `aws` in CI.
- `deploy-app.yml` runs on a push to `dev` that changes the application, its migrations, the UI, `deploy/`, or `scripts/`, so a documentation or Terraform change does not release. The ALB address and the test token are masked before use and never printed.
- The smoke step checks that the legacy test route answers and that the response carries `X-ShipTrack-Stack: legacy`. After it, the platform contract suite's `smoke` subset runs with `TARGET=legacy`: the workflow resolves the platform's `dev` branch, or the `platform_ref` input, to a commit SHA, checks the public repository out at that SHA, and runs `uv run --frozen pytest -m smoke`, as modern's `deploy-app.yml` does for `modern`. The suite fails when the response is not `X-ShipTrack-Stack: legacy`, so a missing token cannot test the wrong stack. Nothing from the run is uploaded, because a failure message can contain the ALB address. It makes real API calls, so a smoke run creates at most one `ZZTEST` shipment. A failure leaves the new release on the hosts: this workflow has no rollback step, and `ops-rollback-release.yml` is run by hand.
- `ci-terraform.yml` and `apply-terraform.yml` mirror the platform workflows without Checkov or Trivy (AP-13). The apply also runs when `scripts/` or `deploy/` change, because the SSM documents and user-data embed them (ADR-0008).
- A workflow that read the public AMI parameter with the read-only plan role was the way to pin the AMI on purpose (AP-14); it was removed once the AMI was pinned, and re-pinning is a deliberate change to `terraform.tfvars`.
- `ci-checks.yml` also runs `terraform fmt -check` and `validate`, as design §7.4 lists.

**Consequences:** A deploy needs `db/bootstrap.sql` to have been run and at least one InService host. The workflows are first exercised by the pull request that adds them (`ci-terraform`) and by the first merge (`deploy`, `apply-terraform`).

## ADR-0011: database-bootstrap-from-a-host

**Status:** Accepted

**Context:** The platform design makes the first run of `db/bootstrap.sql` a manual step from an AWS CloudShell VPC environment. The account in use has no CloudShell access, and the first deploy cannot migrate until the database, roles, and schema exist.

**Decision:** A legacy host does the same work. `ShipTrack-DbBootstrap` is an SSM document (created here, so the deploy role may run it) that embeds `scripts/db_bootstrap.sh`; `ops-db-bootstrap.yml` dispatches it to one InService host. The host is already inside the VPC, has the path to RDS, and may read the secrets (AP-03 gives it `secretsmanager:GetSecretValue` on every secret, and the secrets key allows decrypt through Secrets Manager). The script installs a PostgreSQL client, fetches `bootstrap.sql` from the public platform repository at a commit pinned by the workflow, checks it against a SHA-256 the workflow computed, reads the master and application credentials from Secrets Manager, and runs the SQL over a verified TLS connection. The two passwords reach `psql` through a mode-0600 temporary file and the environment, never a command line, and the file is deleted on exit. It then checks the result (two login roles, the schema owned by the migrator, the application role able to use but not create) and prints only `max_connections`. The master secret's ARN is not in the platform contract, so Terraform reads it from the RDS instance with a data source.

**Consequences:** The master credentials are used from a legacy host, which any anti-pattern in the host's role (AP-03) already allows; this stays a legacy-only convenience and the modern stack does not use it. The platform runbook remains the documented route where CloudShell is available. The `GRANT` of the migrator role to the master user, which `bootstrap.sql` relies on, is exercised for the first time on RDS by this run (platform ADR-0015, VERIFY); its failure would show as a `permission denied` and a failed run.

## ADR-0012: sla-cron-control-via-ssm

**Status:** Accepted

**Context:** Cutover wave 3 starts by removing the SLA scan cron from the legacy hosts so that the modern CronJob is the only scanner (modern design §9.2). The cron file is written at launch by the launch template, not by a release, so no deploy can remove it, and there is no SSH or key pair (AP-13 stays fixed in modern; legacy has none either). Until the contract migration the rollback is to put the cron back.

**Decision:** `ShipTrack-LegacyCron` is an SSM document that embeds `scripts/lib.sh` and `scripts/legacy_cron.sh`, like the other documents (ADR-0008), with three actions: `status` (changes nothing), `remove-sla`, and `restore-sla` (copies the current release's `deploy/cron/shiptrack-sla` back). `ops-legacy-cron.yml` runs it on one host at a time behind the `dev` environment. The proof-of-delivery sync's cron keeps its own `remove-cron` action in `ops-pod-sync.yml`. Output is one line of words per host.

**Consequences:** Wave 3 step 1 and its rollback are two workflow runs and need no host access. A host launched after the removal gets the SLA cron again from its launch template, so the Auto Scaling group going to 0 at the end of wave 3 is what makes the removal final; if a host is replaced in between, `status` shows it and `remove-sla` runs again. The removal is only a rollback until the contract migration; nothing here changes that point of no return.

## ADR-0013: data-reset-by-gated-workflow

**Status:** Superseded by platform ADR-0034

**Context:** Nothing deletes shipments: the API has no delete and the contract is frozen, so the data only grows. The owner asked for a workflow that resets it. It was first built here as `ShipTrack-ResetData` and `ops-reset-data.yml`, because a legacy host is the one place a workflow can reach the private database from (ADR-0011).

**Decision:** The reset moved to `shiptrack-platform` before it was ever run, because the database and the proof-of-delivery bucket are the platform's and both stacks read them. The workflow, the job, and its tests were removed from this repository. The SSM document it had created was not deleted: this Terraform forgot it, and the platform's Terraform adopted it by import. Both handoff blocks were removed once the applies had run.

**Consequences:** This repository holds no code that deletes shipments. The reset still runs on these hosts, through the platform's document, so it depends on them while they exist.

## ADR-0014: proof-of-delivery-naming

**Status:** Accepted

**Context:** The abbreviation POD names the document a carrier produces when a shipment is delivered, and it is also the usual short form of a Kubernetes pod, which is what `shiptrack-modern` runs on. Across the three repositories the two readings collided in prose, diagrams, and code names.

**Decision:** A proof of delivery is the file a carrier uploads through `POST /api/v1/shipments/{id}/pod` as evidence of delivery, with its row in `pod_documents`. It is written "proof of delivery" in prose, comments, messages, and documentation, and "proof-of-delivery" when it qualifies a noun. Code names say `proof_of_delivery` (modules, functions, classes, settings attributes, tests). A pod, in lower case and never abbreviated to POD, is only ever a Kubernetes pod, and this stack has none. Names that other systems, stored data, or the frozen contract depend on are kept as they are: the `/pod` API paths, the `pod_documents` table, the `pod/` S3 key prefix and `/var/lib/shiptrack/pod` directory, the `pod_dir` key in `app.ini`, the `POD_BUCKET` variable, the `pod_bucket_name` and `pod_bucket_arn` platform contract keys, the `ShipTrack-PodSync` document and its `podBucket` parameter, `pod_sync.sh`, `migrate_pod_to_s3.py`, the `shiptrack-podsync` cron file, `ops-pod-sync.yml`, and the `pod-gate` check with its `POD_GATE` output line. The gate id `G-POD` is kept and reads as the proof-of-delivery gate.

**Consequences:** No behavior, schema, contract, or deployed name changes. The kept names still contain `pod`; they stand for proof of delivery and are listed here so that a search for `pod` in this repository is read as proof of delivery, never as a Kubernetes pod. The same rule is recorded in the platform and modern ADRs, where `pod` also has its Kubernetes meaning.

## ADR-0015: stack-version-labels

**Status:** Accepted

**Context:** The UI's footer names the stack that served the page with the value of `X-ShipTrack-Stack`: `legacy` or `modern`. The user asked for the UI to call them v1 and v3, on this stack's page as well as modern's (modern ADR-0041). The rule until now was that this UI is not changed once modern has its own.

**Decision:** The footer shows legacy as v1 and modern as v3. One function in `web/src/format.ts` maps the header value to its label, and a value it does not know is shown as it is. `X-ShipTrack-Stack` keeps `legacy` and `modern`, and the badge's `data-stack` attribute keeps the header value. This is a display change only and an exception to the rule that this UI is not changed; the anti-patterns and the API are untouched.

**Consequences:** The page and the header use different names for the same stack. The contract suite reads only the header and is unchanged. The label reaches the running stack only when a new legacy release is built and deployed.
