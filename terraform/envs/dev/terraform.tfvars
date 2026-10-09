# Non-secret, non-identifying values only. The owner and the role prefix come from the workflows as
# TF_VAR_owner and TF_VAR_role_prefix. ami_id is pinned here once it has been resolved (LEGACY AP-14).
aws_region  = "us-east-1"
environment = "dev"
cost_center = "shiptrack-migration"

instance_type        = "m5.xlarge"
capacity             = 2
root_volume_size_gib = 100
