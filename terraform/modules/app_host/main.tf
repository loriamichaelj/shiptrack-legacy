# The legacy application host: security group, instance role, launch template, Auto Scaling group,
# log groups, and host-level alarms (legacy design §6). The anti-patterns are requirements, not
# mistakes; each one is tagged with its ID where it is implemented.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  deploy    = "${path.module}/../../../deploy"

  log_groups = toset(["app", "access", "nginx", "sla"])

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region           = local.region
    artifact_bucket  = var.artifact_bucket
    systemd_service  = file("${local.deploy}/systemd/shiptrack.service")
    nginx_conf       = file("${local.deploy}/nginx/nginx.conf")
    nginx_site       = file("${local.deploy}/nginx/shiptrack.conf")
    nginx_headers    = file("${local.deploy}/nginx/shiptrack-headers.inc")
    cron_sla         = file("${local.deploy}/cron/shiptrack-sla")
    logrotate        = file("${local.deploy}/logrotate/shiptrack")
    cloudwatch_agent = file("${local.deploy}/cloudwatch/amazon-cloudwatch-agent.json")
    lib_sh           = file("${path.module}/../../../scripts/lib.sh")
  })
}

# --- Network -------------------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "shiptrack-legacy-app"
  description = "ShipTrack legacy hosts: HTTP from the ALB only"
  vpc_id      = var.vpc_id

  tags = { Name = "shiptrack-legacy-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = var.sg_alb_id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Everything outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Instance role -------------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "instance" {
  # LEGACY AP-03: S3 and Secrets Manager access to every resource, far beyond what the host needs.
  statement {
    sid       = "LegacyAp03S3Everything"
    actions   = ["s3:*"]
    resources = ["*"]
  }

  statement {
    sid       = "LegacyAp03SecretsEverything"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }

  # Not part of the anti-pattern: reading a secret encrypted with a customer managed key needs this.
  statement {
    sid       = "DecryptSecretsThroughSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  # Not part of the anti-pattern: user-data reads the platform contract and the current release.
  statement {
    sid       = "ReadTheContractAndTheCurrentRelease"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account}:parameter/shiptrack/*"]
  }
}

resource "aws_iam_role" "instance" {
  name                 = "${var.role_prefix}-legacy-instance"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permission_boundary_arn
}

resource "aws_iam_role_policy" "instance" {
  name   = "legacy-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.role_prefix}-legacy-instance"
  role = aws_iam_role.instance.name
}

# --- Logs ----------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "host" {
  for_each = local.log_groups

  name              = "/shiptrack/legacy/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_key_arn
}

# --- Launch template and Auto Scaling group ------------------------------------------------------

resource "aws_launch_template" "app" {
  # LEGACY AP-04, AP-10, AP-11, AP-14: IMDSv1 allowed, oversized instances, a 100 GiB gp2 root
  # volume, and an AMI pinned once and never refreshed.
  name          = "shiptrack-legacy"
  image_id      = var.ami_id        # LEGACY AP-14: pinned once, never refreshed
  instance_type = var.instance_type # LEGACY AP-10: m5.xlarge, oversized

  vpc_security_group_ids = [aws_security_group.app.id, var.sg_db_client_id]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size_gib
      volume_type           = var.root_volume_type # LEGACY AP-11: gp2, 100 GiB
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional" # LEGACY AP-04: IMDSv1 allowed
  }

  monitoring {
    enabled = false
  }

  user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.instance_tags, { Name = "shiptrack-legacy" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.instance_tags, { Name = "shiptrack-legacy" })
  }
}

resource "aws_autoscaling_group" "app" {
  # LEGACY AP-10 and AP-07: fixed capacity with no scaling policies, and EC2 health checks that
  # never look at the application.
  name                = "shiptrack-legacy"
  min_size            = var.capacity
  max_size            = var.capacity
  desired_capacity    = var.capacity
  vpc_zone_identifier = var.subnet_ids
  target_group_arns   = [var.target_group_arn]
  health_check_type   = "EC2" # LEGACY AP-07: never looks at the application

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  dynamic "tag" {
    for_each = merge(var.instance_tags, { Name = "shiptrack-legacy" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# --- Host-level alarms (LEGACY AP-15: nothing about the application itself) ----------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "shiptrack-legacy-cpu"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#shiptrack-legacy-cpu | Average CPU across the legacy hosts has been above 80% for 15 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sns_sev2_arn]
  ok_actions          = [var.sns_sev2_arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "shiptrack-legacy-status-check"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#shiptrack-legacy-status-check | A legacy host has failed an EC2 status check for 5 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sns_sev2_arn]
  ok_actions          = [var.sns_sev2_arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "shiptrack-legacy-memory"
  alarm_description   = "owner: ${var.alarm_owner} | severity: SEV2 | runbook: ${var.runbook_url}#shiptrack-legacy-memory | Memory use on the legacy hosts has been above 90% for 10 minutes."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = 90
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sns_sev2_arn]
  ok_actions          = [var.sns_sev2_arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}
