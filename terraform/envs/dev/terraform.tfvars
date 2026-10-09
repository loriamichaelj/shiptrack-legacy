# Non-secret, non-identifying values only. The owner and the role prefix come from the workflows as
# TF_VAR_owner and TF_VAR_role_prefix.
aws_region  = "us-east-1"
environment = "dev"
cost_center = "shiptrack-migration"

instance_type        = "m5.xlarge"
capacity             = 2
root_volume_size_gib = 100

# LEGACY AP-14: the AMI is resolved once and pinned; nothing refreshes it. This is
# al2023-ami-2023.12.20260930.0-kernel-6.18-x86_64 in us-east-1, found by the resolve-ami workflow.
ami_id = "ami-0d27e0fb3bac4d724"
