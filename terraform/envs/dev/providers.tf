provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "shiptrack"
      Stack       = "legacy"
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
      Repo        = "shiptrack-legacy"
    }
  }
}
