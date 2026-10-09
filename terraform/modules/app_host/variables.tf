variable "role_prefix" {
  description = "Prefix of IAM role names (<owner>-<environment>-<project>)."
  type        = string
}

variable "vpc_id" {
  description = "ID of the platform VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Private-app subnet IDs for the instances."
  type        = list(string)
}

variable "sg_alb_id" {
  description = "ID of the platform ALB security group; the instances accept HTTP from it only."
  type        = string
}

variable "sg_db_client_id" {
  description = "ID of the platform database-client security group."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the platform's legacy target group."
  type        = string
}

variable "permission_boundary_arn" {
  description = "ARN of the workload permission boundary. The apply role refuses to create the instance role without it."
  type        = string
}

variable "secrets_key_arn" {
  description = "ARN of the platform secrets key, used to read the database secret."
  type        = string
}

variable "logs_key_arn" {
  description = "ARN of the platform logs key, which encrypts the log groups."
  type        = string
}

variable "sns_sev2_arn" {
  description = "ARN of the platform SEV2 alert topic."
  type        = string
}

variable "artifact_bucket" {
  description = "Name of the release artifact bucket."
  type        = string
}

variable "ami_id" {
  description = "AMI ID, resolved once and pinned (LEGACY AP-14)."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "Instance type. LEGACY AP-10: oversized on purpose."
  type        = string
  default     = "m5.xlarge"
}

variable "root_volume_size_gib" {
  description = "Root volume size in GiB. LEGACY AP-11: oversized on purpose."
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Root volume type. LEGACY AP-11: gp2 on purpose."
  type        = string
  default     = "gp2"
}

variable "capacity" {
  description = "Instance count: ASG minimum, maximum, and desired. LEGACY AP-10: fixed capacity, no scaling."
  type        = number
  default     = 2
}

variable "instance_tags" {
  description = "Tags applied to instances and volumes at launch, including Stack=legacy, which the SSM documents target."
  type        = map(string)
}

variable "log_retention_days" {
  description = "Days the host log groups are kept."
  type        = number
  default     = 30
}

variable "alarm_owner" {
  description = "Owner named in every alarm description."
  type        = string
  default     = "legacy"
}

variable "runbook_url" {
  description = "URL of the runbook page; each alarm links to it with the alarm name as the anchor."
  type        = string
}
