# ShipTrack Legacy — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `kms-decrypt-for-cmk-secret` | Planned |
| 0002 | `podsync-interval-and-window` | Planned |
| 0003 | `v1.1-kms-on-pod-bucket` | Planned |
| 0004 | `evidence-via-ssm-and-workflows` | Planned |
| 0005 | `aws-emulator-in-ci` | Accepted |
| 0006 | `ui-toolchain-versions` | Accepted |
| 0007 | `nginx-body-limit` | Accepted |
| 0008 | `ssm-document-script-delivery` | Accepted |

## ADR-0001: kms-decrypt-for-cmk-secret

**Status:** Planned

**Records:** kms:Decrypt on the platform secrets key is needed to read a CMK-encrypted secret and is deliberately not part of AP-03.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0002: podsync-interval-and-window

**Status:** Planned

**Records:** PodSync every minute under flock; the resulting 1–2 minute window in which a legacy-uploaded POD is unreadable through modern; why a longer interval was rejected (design §8).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0003: v1.1-kms-on-pod-bucket

**Status:** Planned

**Records:** Even s3:* is not enough for the SSE-KMS POD bucket; the KMS grant is the only IAM change in v1.1.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0004: evidence-via-ssm-and-workflows

**Status:** Planned

**Records:** Why assessment evidence runs through SSM documents and workflows (private RDS, no local AWS credentials, public-repo scrub).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

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
