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
    "sns_sev2_arn",
  ])

  name = "/shiptrack/platform/${each.key}"
}

locals {
  platform = { for k, p in data.aws_ssm_parameter.platform : k => nonsensitive(p.value) }

  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region

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
