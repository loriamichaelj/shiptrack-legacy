# Offline. The AWS provider is real but configured to skip every API call, so policy documents are
# built for real and can be read back. The one data source that would call STS is overridden.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "offline"
  secret_key                  = "offline"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

# Resource IDs are unknown during a plan; fixing this one lets the launch template's group set be read.
override_resource {
  target          = aws_security_group.app
  override_during = plan
  values          = { id = "sg-app" }
}

variables {
  role_prefix             = "testowner-dev-shiptrack"
  vpc_id                  = "vpc-mock"
  subnet_ids              = ["subnet-a", "subnet-b", "subnet-c"]
  sg_alb_id               = "sg-alb"
  sg_db_client_id         = "sg-client"
  target_group_arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-legacy/0123456789abcdef"
  permission_boundary_arn = "arn:aws:iam::123456789012:policy/testowner-dev-shiptrack-workload-boundary"
  secrets_key_arn         = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000b"
  logs_key_arn            = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-00000000000c"
  sns_sev2_arn            = "arn:aws:sns:us-east-1:123456789012:shiptrack-alerts-sev2"
  artifact_bucket         = "shiptrack-legacy-artifacts-mock"
  ami_id                  = "ami-0123456789abcdef0"
  runbook_url             = "https://runbooks.example.test/legacy.md"
  instance_tags           = { Stack = "legacy", Project = "shiptrack" }
}

run "anti_patterns_are_visible_in_the_launch_template" {
  command = plan

  # AP-10, AP-11, AP-14
  assert {
    condition = alltrue([
      aws_launch_template.app.instance_type == "m5.xlarge",
      aws_launch_template.app.image_id == var.ami_id,
      one(aws_launch_template.app.block_device_mappings).device_name == "/dev/xvda",
      one(one(aws_launch_template.app.block_device_mappings).ebs).volume_size == 100,
      one(one(aws_launch_template.app.block_device_mappings).ebs).volume_type == "gp2",
      one(one(aws_launch_template.app.block_device_mappings).ebs).encrypted == "true",
    ])
    error_message = "AP-10, AP-11 and AP-14: m5.xlarge, a pinned AMI, and a 100 GiB encrypted gp2 root volume."
  }

  # AP-04
  assert {
    condition = alltrue([
      one(aws_launch_template.app.metadata_options).http_tokens == "optional",
      one(aws_launch_template.app.metadata_options).http_endpoint == "enabled",
    ])
    error_message = "AP-04: IMDSv1 must be allowed."
  }

  assert {
    condition     = !one(aws_launch_template.app.monitoring).enabled
    error_message = "Detailed monitoring is off."
  }

  assert {
    condition     = aws_launch_template.app.key_name == null || aws_launch_template.app.key_name == ""
    error_message = "No key pair: there is no SSH."
  }
}

run "the_asg_is_fixed_and_checks_only_ec2" {
  command = plan

  # AP-10, AP-07
  assert {
    condition = alltrue([
      aws_autoscaling_group.app.min_size == 2,
      aws_autoscaling_group.app.max_size == 2,
      aws_autoscaling_group.app.desired_capacity == 2,
      aws_autoscaling_group.app.health_check_type == "EC2",
      aws_autoscaling_group.app.name == "shiptrack-legacy",
      length(aws_autoscaling_group.app.target_group_arns) == 1,
    ])
    error_message = "The ASG is min = max = desired = 2 with EC2 health checks, behind the legacy target group."
  }

  assert {
    condition = alltrue([
      anytrue([for t in aws_autoscaling_group.app.tag : t.key == "Stack" && t.value == "legacy" && t.propagate_at_launch]),
      anytrue([for t in aws_autoscaling_group.app.tag : t.key == "Name" && t.value == "shiptrack-legacy" && t.propagate_at_launch]),
    ])
    error_message = "Instances carry Stack=legacy, which the SSM documents target, and the Name tag."
  }
}

run "the_instance_role_is_over_privileged_and_bounded" {
  command = plan

  assert {
    condition = alltrue([
      aws_iam_role.instance.name == "testowner-dev-shiptrack-legacy-instance",
      aws_iam_role.instance.permissions_boundary == var.permission_boundary_arn,
      aws_iam_instance_profile.instance.name == "testowner-dev-shiptrack-legacy-instance",
    ])
    error_message = "The role is named under the role prefix and carries the workload boundary."
  }

  # AP-03
  assert {
    condition = alltrue([
      anytrue([for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Sid == "LegacyAp03S3Everything" && s.Action == "s3:*" && s.Resource == "*"]),
      anytrue([for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Sid == "LegacyAp03SecretsEverything" && s.Action == "secretsmanager:GetSecretValue" && s.Resource == "*"]),
    ])
    error_message = "AP-03: s3:* and secretsmanager:GetSecretValue on every resource."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement :
      s.Sid == "DecryptSecretsThroughSecretsManager"
      && s.Action == "kms:Decrypt"
      && s.Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com"
    ])
    error_message = "The host may decrypt the secrets key only through Secrets Manager."
  }

  assert {
    condition = alltrue([
      aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      aws_iam_role_policy_attachment.cloudwatch_agent.policy_arn == "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    ])
    error_message = "AP-03 also attaches the two managed policies."
  }
}

run "only_the_alb_can_reach_the_hosts" {
  command = plan

  assert {
    condition = alltrue([
      aws_security_group.app.name == "shiptrack-legacy-app",
      aws_vpc_security_group_ingress_rule.from_alb.from_port == 80,
      aws_vpc_security_group_ingress_rule.from_alb.referenced_security_group_id == var.sg_alb_id,
      aws_launch_template.app.vpc_security_group_ids == toset(["sg-app", var.sg_db_client_id]),
    ])
    error_message = "The hosts accept TCP 80 from the ALB group only and carry the database-client group."
  }
}

run "log_groups_follow_the_design" {
  command = plan

  assert {
    condition = alltrue([
      toset([for g in aws_cloudwatch_log_group.host : g.name]) == toset(["/shiptrack/legacy/app", "/shiptrack/legacy/access", "/shiptrack/legacy/nginx", "/shiptrack/legacy/sla"]),
      alltrue([for g in aws_cloudwatch_log_group.host : g.retention_in_days == 30 && g.kms_key_id == var.logs_key_arn]),
    ])
    error_message = "Four log groups, 30 days, encrypted with the platform logs key."
  }
}

run "alarms_are_host_level_only" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.cpu.threshold == 80,
      aws_cloudwatch_metric_alarm.cpu.period * aws_cloudwatch_metric_alarm.cpu.evaluation_periods == 900,
      aws_cloudwatch_metric_alarm.status_check.threshold == 0,
      aws_cloudwatch_metric_alarm.status_check.period * aws_cloudwatch_metric_alarm.status_check.evaluation_periods == 300,
      aws_cloudwatch_metric_alarm.memory.threshold == 90,
      aws_cloudwatch_metric_alarm.memory.namespace == "CWAgent",
      aws_cloudwatch_metric_alarm.memory.period * aws_cloudwatch_metric_alarm.memory.evaluation_periods == 600,
    ])
    error_message = "CPU above 80% for 15 minutes, status check for 5, memory above 90% for 10."
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.cpu, aws_cloudwatch_metric_alarm.status_check, aws_cloudwatch_metric_alarm.memory] :
      can(regex("^owner: legacy \\| severity: SEV2 \\| runbook: https://[^ ]+#shiptrack-legacy-[a-z-]+ \\|", a.alarm_description))
      && a.alarm_actions == toset([var.sns_sev2_arn])
      && a.ok_actions == toset([var.sns_sev2_arn])
    ])
    error_message = "Every alarm names its owner, severity, and runbook, and notifies the SEV2 topic on alarm and OK."
  }
}

run "user_data_fits_and_renders_the_configs" {
  command = plan

  assert {
    condition     = output.user_data_bytes < 15000
    error_message = "EC2 limits user-data to 16384 bytes; the rendered script must leave headroom."
  }

  assert {
    condition = alltrue([
      can(regex("AWS_DEFAULT_REGION=\"us-east-1\"", base64decode(aws_launch_template.app.user_data))),
      can(regex("ARTIFACT_BUCKET=\"shiptrack-legacy-artifacts-mock\"", base64decode(aws_launch_template.app.user_data))),
      can(regex("/etc/shiptrack/app.ini", base64decode(aws_launch_template.app.user_data))),
      can(regex("chmod 0644 /etc/shiptrack/app.ini", base64decode(aws_launch_template.app.user_data))),
      can(regex("X-ShipTrack-Stack legacy", base64decode(aws_launch_template.app.user_data))),
      can(regex("AutoScalingGroupName", base64decode(aws_launch_template.app.user_data))),
    ])
    error_message = "The script must set the region and bucket, write app.ini at mode 0644 (AP-01), and embed the nginx and CloudWatch configs verbatim."
  }
}
