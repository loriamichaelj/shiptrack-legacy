variable "aws_region" {
  description = "Region of every resource in this environment."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name; it is also the Environment tag."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag, and the GitHub owner in runbook links. The workflows supply the repository owner (TF_VAR_owner)."
  type        = string

  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "cost_center" {
  description = "CostCenter tag."
  type        = string
}

variable "role_prefix" {
  description = "Prefix of every IAM role and policy name: <owner>-<environment>-<project>. The workflows supply it from the ROLE_PREFIX repository variable (TF_VAR_role_prefix)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$", var.role_prefix))
    error_message = "role_prefix must be 2 to 40 characters: lowercase letters, digits, and hyphens."
  }
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI, resolved once from /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 and pinned here (LEGACY AP-14). The build container must use the same AL2023 release."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "LEGACY AP-10: oversized on purpose."
  type        = string
  default     = "m5.xlarge"
}

variable "capacity" {
  description = "LEGACY AP-10: fixed capacity, no scaling."
  type        = number
  default     = 2
}

variable "root_volume_size_gib" {
  description = "LEGACY AP-11: oversized on purpose."
  type        = number
  default     = 100
}
