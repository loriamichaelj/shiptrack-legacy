output "asg_name" {
  description = "Name of the Auto Scaling group."
  value       = aws_autoscaling_group.app.name
}

output "instance_role_name" {
  description = "Name of the instance role."
  value       = aws_iam_role.instance.name
}

output "security_group_id" {
  description = "ID of the legacy app security group."
  value       = aws_security_group.app.id
}

output "user_data_bytes" {
  description = "Size of the rendered user-data script; EC2 allows 16384."
  value       = length(local.user_data)
}
