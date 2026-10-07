# ShipTrack Legacy — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `kms-decrypt-for-cmk-secret` | Planned |
| 0002 | `podsync-interval-and-window` | Planned |
| 0003 | `v1.1-kms-on-pod-bucket` | Planned |
| 0004 | `evidence-via-ssm-and-workflows` | Planned |

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
