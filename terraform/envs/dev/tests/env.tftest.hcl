# Offline. The AWS provider skips every API call; the data sources that would make one are
# overridden. Checks what the plan shows for the environment as a whole (legacy design §6).
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "offline"
  secret_key                  = "offline"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  default_tags {
    tags = {
      Project = "shiptrack"
      Stack   = "legacy"
    }
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = module.app_host.data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = data.aws_default_tags.current
  values = { tags = { Project = "shiptrack", Stack = "legacy", Repo = "shiptrack-legacy" } }
}

override_data {
  target = data.aws_ssm_parameter.platform["vpc_id"]
  values = { value = "vpc-mock" }
}
override_data {
  target = data.aws_ssm_parameter.platform["private_app_subnet_ids"]
  values = { value = "subnet-a,subnet-b,subnet-c" }
}
override_data {
  target = data.aws_ssm_parameter.platform["sg_alb_id"]
  values = { value = "sg-alb" }
}
override_data {
  target = data.aws_ssm_parameter.platform["sg_db_client_id"]
  values = { value = "sg-client" }
}
override_data {
  target = data.aws_ssm_parameter.platform["tg_legacy_arn"]
  values = { value = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-legacy/0123456789abcdef" }
}
override_data {
  target = data.aws_ssm_parameter.platform["permission_boundary_arn"]
  values = { value = "arn:aws:iam::123456789012:policy/testowner-dev-shiptrack-workload-boundary" }
}
override_data {
  target = data.aws_ssm_parameter.platform["kms_secrets_key_arn"]
  values = { value = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000b" }
}
override_data {
  target = data.aws_ssm_parameter.platform["kms_logs_key_arn"]
  values = { value = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c" }
}
override_data {
  target = data.aws_ssm_parameter.platform["rds_endpoint"]
  values = { value = "shiptrack-db.example.test" }
}
override_data {
  target = data.aws_db_instance.platform
  values = {
    master_user_secret = [{ kms_key_id = "mock", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-00000000-0000-0000-0000-00000000000a-AbCdEf", secret_status = "active" }]
  }
}
override_data {
  target = data.aws_ssm_parameter.platform["sns_sev2_arn"]
  values = { value = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev2" }
}

# A bucket's ID is unknown during a plan; fixing it lets the SSM document contents be read.
override_resource {
  target          = aws_s3_bucket.artifacts
  override_during = plan
  values = {
    id  = "shiptrack-legacy-artifacts-123456789012-us-east-1"
    arn = "arn:aws:s3:::shiptrack-legacy-artifacts-123456789012-us-east-1"
  }
}

variables {
  owner       = "testowner"
  cost_center = "test"
  role_prefix = "testowner-dev-shiptrack"
  ami_id      = "ami-0123456789abcdef0"
}

run "the_artifact_bucket_follows_the_design" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket.artifacts.bucket == "shiptrack-legacy-artifacts-123456789012-us-east-1",
      one(aws_s3_bucket_versioning.artifacts.versioning_configuration).status == "Enabled",
      one(one(aws_s3_bucket_server_side_encryption_configuration.artifacts.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256",
      aws_s3_bucket_public_access_block.artifacts.block_public_acls,
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets,
      one(aws_s3_bucket_ownership_controls.artifacts.rule).object_ownership == "BucketOwnerEnforced",
    ])
    error_message = "The artifact bucket is versioned, SSE-S3, blocks public access, and enforces ownership."
  }

  assert {
    condition = alltrue([
      one(one(aws_s3_bucket_lifecycle_configuration.artifacts.rule).filter).prefix == "releases/",
      one(one(aws_s3_bucket_lifecycle_configuration.artifacts.rule).expiration).days == 180,
    ])
    error_message = "releases/* expire at 180 days."
  }
}

run "release_pointer_is_created_once_and_never_overwritten" {
  command = plan

  assert {
    condition = alltrue([
      aws_ssm_parameter.current_release.name == "/shiptrack/legacy/current_release",
      nonsensitive(aws_ssm_parameter.current_release.value) == "none",
    ])
    error_message = "current_release starts as none; the deploy pipeline owns it afterwards."
  }
}

run "the_ssm_documents_embed_the_scripts_and_validate_their_inputs" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssm_document.shiptrack)) == toset(["ShipTrack-Migrate", "ShipTrack-Deploy", "ShipTrack-Rollback"])
    error_message = "Migrate, Deploy, and Rollback are created here; Evidence arrives with the assessment tooling."
  }

  assert {
    condition = alltrue([
      for d in aws_ssm_document.shiptrack :
      jsondecode(d.content).schemaVersion == "2.2"
      && jsondecode(d.content).mainSteps[0].action == "aws:runShellScript"
      && can(regex("SHIPTRACK_LIB_LOADED=1", jsondecode(d.content).mainSteps[0].inputs.runCommand[0]))
      && jsondecode(d.content).parameters.releaseSha.allowedPattern != ""
    ])
    error_message = "Each document pastes lib.sh ahead of its script and restricts its parameters."
  }

  assert {
    condition = alltrue([
      can(regex("migrations are at head", jsondecode(aws_ssm_document.shiptrack["ShipTrack-Migrate"].content).mainSteps[0].inputs.runCommand[0])),
      can(regex("deployed release", jsondecode(aws_ssm_document.shiptrack["ShipTrack-Deploy"].content).mainSteps[0].inputs.runCommand[0])),
      can(regex("ROLLED_BACK_TO", jsondecode(aws_ssm_document.shiptrack["ShipTrack-Rollback"].content).mainSteps[0].inputs.runCommand[0])),
    ])
    error_message = "Each document embeds the script it runs."
  }

  assert {
    condition     = jsondecode(aws_ssm_document.shiptrack["ShipTrack-Rollback"].content).parameters.releaseSha.allowedPattern == "^[A-Za-z0-9._-]*$"
    error_message = "Rollback may be run without a target release."
  }
}

run "the_hosts_use_the_platform_contract" {
  command = plan

  assert {
    condition = alltrue([
      module.app_host.user_data_bytes < 15000,
      aws_ssm_parameter.asg_name.name == "/shiptrack/legacy/asg_name",
    ])
    error_message = "User-data fits, and the ASG name is published for runbooks."
  }
}

run "the_ami_must_look_like_an_ami" {
  command = plan

  variables {
    ami_id = "not-an-ami"
  }

  expect_failures = [var.ami_id]
}

run "the_db_bootstrap_document_is_pinned_and_checked" {
  command = plan

  assert {
    condition     = aws_ssm_document.db_bootstrap.name == "ShipTrack-DbBootstrap"
    error_message = "The deploy role may run only ShipTrack-* documents, so the name must start with ShipTrack-."
  }

  assert {
    condition = alltrue([
      jsondecode(aws_ssm_document.db_bootstrap.content).parameters.platformSha.allowedPattern == "^[0-9a-f]{40}$",
      jsondecode(aws_ssm_document.db_bootstrap.content).parameters.sqlSha256.allowedPattern == "^[0-9a-f]{64}$",
      can(regex("^arn:", jsondecode(aws_ssm_document.db_bootstrap.content).parameters.masterSecretArn.default)),
      can(regex("sha256sum", jsondecode(aws_ssm_document.db_bootstrap.content).mainSteps[0].inputs.runCommand[0])),
      can(regex("bash /tmp/shiptrack-db-bootstrap.sh", jsondecode(aws_ssm_document.db_bootstrap.content).mainSteps[0].inputs.runCommand[0])),
    ])
    error_message = "The document takes a full commit and a checksum, defaults to the RDS master secret, and runs the embedded script."
  }
}
