# The state bucket name contains the account ID, so the pipeline passes the bucket, key, region, and
# lock setting to `terraform init` instead of committing them here. The key is legacy/dev.tfstate.
terraform {
  backend "s3" {}
}
