data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_default_tags" "current" {}

# --- The platform contract -----------------------------------------------------------------------
# Read only the keys this stack uses. They are identifiers and ARNs, not secrets, so the values are
# unmarked to keep plans readable.

data "aws_ssm_parameter" "platform" {
  for_each = toset([
    "vpc_id",
    "private_app_subnet_ids",
    "sg_alb_id",
    "sg_db_client_id",
    "tg_legacy_arn",
    "permission_boundary_arn",
    "kms_secrets_key_arn",
    "kms_logs_key_arn",
    "kms_data_key_arn",
    "pod_bucket_name",
    "sns_sev2_arn",
    "rds_endpoint",
  ])

  name = "/shiptrack/platform/${each.key}"
}

locals {
  platform = { for k, p in data.aws_ssm_parameter.platform : k => nonsensitive(p.value) }

  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region

  # The RDS-managed master secret is not in the contract; it is read from the instance itself, whose
  # identifier is the first label of the endpoint address.
  db_identifier = split(".", local.platform.rds_endpoint)[0]

  artifact_bucket = "shiptrack-legacy-artifacts-${local.account}-${local.region}"
  runbook_url     = "https://github.com/${var.owner}/shiptrack-legacy/blob/dev/docs/runbooks/legacy.md"
}

# --- Release artifacts ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifact_bucket
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-releases"
    status = "Enabled"

    filter {
      prefix = "releases/"
    }

    expiration {
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# --- The hosts -----------------------------------------------------------------------------------

module "app_host" {
  source = "../../modules/app_host"

  role_prefix             = var.role_prefix
  vpc_id                  = local.platform.vpc_id
  subnet_ids              = split(",", local.platform.private_app_subnet_ids)
  sg_alb_id               = local.platform.sg_alb_id
  sg_db_client_id         = local.platform.sg_db_client_id
  target_group_arn        = local.platform.tg_legacy_arn
  permission_boundary_arn = local.platform.permission_boundary_arn
  secrets_key_arn         = local.platform.kms_secrets_key_arn
  logs_key_arn            = local.platform.kms_logs_key_arn
  data_key_arn            = local.platform.kms_data_key_arn
  sns_sev2_arn            = local.platform.sns_sev2_arn
  artifact_bucket         = aws_s3_bucket.artifacts.id
  ami_id                  = var.ami_id
  instance_type           = var.instance_type
  capacity                = var.capacity
  root_volume_size_gib    = var.root_volume_size_gib
  instance_tags           = data.aws_default_tags.current.tags
  runbook_url             = local.runbook_url
}

# --- SSM parameters ------------------------------------------------------------------------------

# Owned by the deploy pipeline: Terraform creates it and never changes it again.
resource "aws_ssm_parameter" "current_release" {
  name  = "/shiptrack/legacy/current_release"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "asg_name" {
  name  = "/shiptrack/legacy/asg_name"
  type  = "String"
  value = module.app_host.asg_name
}

# --- SSM documents -------------------------------------------------------------------------------
# Each document embeds scripts/lib.sh and the script it runs, so it works before any release is on
# the host. Parameters are checked against an allowed pattern before they reach the shell.

locals {
  scripts = "${path.module}/../../../scripts"

  documents = {
    "ShipTrack-Migrate" = {
      description     = "Run the database migrations of a release on one host"
      script          = "migrate.sh"
      release_pattern = "^[A-Za-z0-9._-]+$"
    }
    "ShipTrack-Deploy" = {
      description     = "Install and activate a release on a host"
      script          = "deploy.sh"
      release_pattern = "^[A-Za-z0-9._-]+$"
    }
    "ShipTrack-Rollback" = {
      description     = "Roll a host back to the previous release, or to a given one"
      script          = "rollback.sh"
      release_pattern = "^[A-Za-z0-9._-]*$"
    }
  }
}

resource "aws_ssm_document" "shiptrack" {
  for_each = local.documents

  name            = each.key
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = each.value.description
    parameters = {
      releaseSha = {
        type           = "String"
        description    = "The release to act on"
        allowedPattern = each.value.release_pattern
        default        = each.key == "ShipTrack-Rollback" ? "" : "none"
      }
      artifactBucket = {
        type           = "String"
        description    = "The artifact bucket"
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        default        = aws_s3_bucket.artifacts.id
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-run.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/lib.sh"),
          file("${local.scripts}/${each.value.script}"),
          "SHIPTRACK_EOF_SCRIPT",
          each.key == "ShipTrack-Rollback" ? "bash /tmp/shiptrack-run.sh '{{ releaseSha }}'" : "bash /tmp/shiptrack-run.sh '{{ releaseSha }}' '{{ artifactBucket }}'",
        ])]
      }
    }]
  })
}

# --- Database bootstrap --------------------------------------------------------------------------
# Runs the platform's db/bootstrap.sql from a host inside the VPC, so no CloudShell is needed
# (ADR-0011). The workflow ops-db-bootstrap.yml dispatches it. The SQL is fetched at a pinned commit and
# checked against a SHA-256 supplied with each run.

data "aws_db_instance" "platform" {
  db_instance_identifier = local.db_identifier
}

resource "aws_ssm_document" "db_bootstrap" {
  name            = "ShipTrack-DbBootstrap"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Create the ShipTrack database, roles, and schema from the platform's db/bootstrap.sql"
    parameters = {
      platformRepo = {
        type           = "String"
        description    = "owner/name of the platform repository"
        allowedPattern = "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"
      }
      platformSha = {
        type           = "String"
        description    = "Full commit of the platform repository to read db/bootstrap.sql from"
        allowedPattern = "^[0-9a-f]{40}$"
      }
      sqlSha256 = {
        type           = "String"
        description    = "SHA-256 that db/bootstrap.sql at that commit must have"
        allowedPattern = "^[0-9a-f]{64}$"
      }
      masterSecretArn = {
        type           = "String"
        description    = "The RDS-managed master secret"
        allowedPattern = "^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@!-]+$"
        default        = data.aws_db_instance.platform.master_user_secret[0].secret_arn
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-db-bootstrap.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/db_bootstrap.sh"),
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-db-bootstrap.sh '{{ platformRepo }}' '{{ platformSha }}' '{{ sqlSha256 }}' '{{ masterSecretArn }}'",
          "rm -f /tmp/shiptrack-db-bootstrap.sh",
        ])]
      }
    }]
  })
}

# --- Proof-of-delivery sync (release v1.1.0) ------------------------------------------------------
# Moves each host's local POD files to the platform POD bucket and installs or removes the
# per-minute sync (design section 8, ADR-0002 and ADR-0003). The workflow ops-pod-sync.yml dispatches it, one host at a
# time, because each host holds different files.

resource "aws_ssm_document" "pod_sync" {
  name            = "ShipTrack-PodSync"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Move this host's proof-of-delivery files to S3, or install or remove the per-minute sync"
    parameters = {
      action = {
        type          = "String"
        description   = "What to do"
        allowedValues = ["dry-run", "migrate", "install-cron", "remove-cron"]
      }
      podBucket = {
        type           = "String"
        description    = "The proof-of-delivery bucket"
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        default        = local.platform.pod_bucket_name
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-pod-sync.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/lib.sh"),
          file("${local.scripts}/pod_sync.sh"),
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-pod-sync.sh '{{ action }}' '{{ podBucket }}'",
          "rm -f /tmp/shiptrack-pod-sync.sh",
        ])]
      }
    }]
  })
}

# --- Legacy cron control (cutover wave 3) ----------------------------------------------------------
# Reports on, removes, or restores the SLA scan cron on a host (ADR-0012). The workflow
# ops-legacy-cron.yml dispatches it, one host at a time. The proof-of-delivery sync's cron is removed
# with ShipTrack-PodSync remove-cron.

resource "aws_ssm_document" "legacy_cron" {
  name            = "ShipTrack-LegacyCron"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Report on, remove, or restore the SLA scan cron on this host"
    parameters = {
      action = {
        type          = "String"
        description   = "What to do"
        allowedValues = ["status", "remove-sla", "restore-sla"]
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-legacy-cron.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/lib.sh"),
          file("${local.scripts}/legacy_cron.sh"),
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-legacy-cron.sh '{{ action }}'",
          "rm -f /tmp/shiptrack-legacy-cron.sh",
        ])]
      }
    }]
  })
}

# --- Data reset -------------------------------------------------------------------------------------
# Deletes every shipment and its proof-of-delivery files, and can seed five demo shipments (ADR-0013).
# The workflow ops-reset-data.yml dispatches it, one host at a time, behind the dev environment and
# a typed confirmation. The document carries its own copy of the job, so it needs no deploy.

resource "aws_ssm_document" "reset_data" {
  name            = "ShipTrack-ResetData"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Delete every shipment and its proof-of-delivery files, and optionally seed five"
    parameters = {
      confirm = {
        type           = "String"
        description    = "Must be delete-all-shipments"
        allowedPattern = "^delete-all-shipments$"
      }
      podBucket = {
        type           = "String"
        description    = "The proof-of-delivery bucket"
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        default        = local.platform.pod_bucket_name
      }
      seed = {
        type          = "String"
        description   = "Whether to create five demo shipments afterwards"
        allowedValues = ["yes", "no"]
        default       = "yes"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-reset-data.py <<'SHIPTRACK_EOF_JOB'",
          file("${local.scripts}/reset_data.py"),
          "SHIPTRACK_EOF_JOB",
          "chmod 0644 /tmp/shiptrack-reset-data.py",
          "cat >/tmp/shiptrack-reset-data.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/lib.sh"),
          file("${local.scripts}/reset_data.sh"),
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-reset-data.sh '{{ confirm }}' '{{ podBucket }}' '{{ seed }}'",
          "rm -f /tmp/shiptrack-reset-data.sh /tmp/shiptrack-reset-data.py",
        ])]
      }
    }]
  })
}

# --- Evidence checks ------------------------------------------------------------------------------
# Read-only queries that need the private database, so they run on a host (ADR-0004). The document
# runs one allow-listed check and returns a single line of numbers. The workflow check-evidence.yml
# dispatches it on one host.

resource "aws_ssm_document" "evidence" {
  name            = "ShipTrack-Evidence"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Run one read-only evidence check against the database from a host"
    parameters = {
      check = {
        type          = "String"
        description   = "Which check"
        allowedValues = ["pod-gate", "sla-duplicates", "ledger-verify"]
      }
      artifactBucket = {
        type           = "String"
        description    = "The artifact bucket"
        allowedPattern = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        default        = aws_s3_bucket.artifacts.id
      }
      ledgerKey = {
        type           = "String"
        description    = "The simulator ledger to verify, for ledger-verify"
        allowedPattern = "^(none|simulator/sent-[A-Za-z0-9._-]+\\.jsonl)$"
        default        = "none"
      }
      wheelKey = {
        type           = "String"
        description    = "The simulator package, for ledger-verify"
        allowedPattern = "^(none|evidence/shiptrack_simulator-[A-Za-z0-9._+-]+\\.whl)$"
        default        = "none"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        runCommand = [join("\n", [
          "set -euo pipefail",
          "cat >/tmp/shiptrack-evidence.sh <<'SHIPTRACK_EOF_SCRIPT'",
          file("${local.scripts}/lib.sh"),
          file("${local.scripts}/evidence.sh"),
          "SHIPTRACK_EOF_SCRIPT",
          "bash /tmp/shiptrack-evidence.sh '{{ check }}' '{{ artifactBucket }}' '{{ ledgerKey }}' '{{ wheelKey }}'",
          "rm -f /tmp/shiptrack-evidence.sh",
        ])]
      }
    }]
  })
}

