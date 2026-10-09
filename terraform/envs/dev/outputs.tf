output "asg_name" {
  description = "Name of the Auto Scaling group."
  value       = module.app_host.asg_name
}

output "artifact_bucket" {
  description = "Name of the release artifact bucket."
  value       = aws_s3_bucket.artifacts.id
}

output "document_names" {
  description = "Names of the SSM documents."
  value       = sort(concat([for d in aws_ssm_document.shiptrack : d.name], [aws_ssm_document.db_bootstrap.name]))
}

output "user_data_bytes" {
  description = "Size of the rendered user-data script; EC2 allows 16384."
  value       = module.app_host.user_data_bytes
}
