# None of these is a secret. An ARN, a bucket name and a zone id are not confidential; the trust
# policy is what protects a role. If a value here ever needed hiding, a credential would have
# become an OpenTofu value, which this design forbids.

output "account_id" {
  value = local.account_id
}

output "state_bucket" {
  description = "Bucket holding OpenTofu state (created here, or the one passed in)."
  value       = local.state_bucket_name
}

output "backup_bucket" {
  description = "Bucket holding encrypted identity archives. Pass to modules/pds as backup_bucket."
  value       = aws_s3_bucket.backup.id
}

output "host_instance_profile_names" {
  description = "Per environment. Pass the matching one to modules/pds as instance_profile_name."
  value       = { for k, p in aws_iam_instance_profile.host : k => p.name }
}

output "hosted_zone_id" {
  description = "The adopted Route 53 zone. Pass to modules/pds as hosted_zone_id."
  value       = data.aws_route53_zone.pds.zone_id
}

output "default_vpc_id" {
  description = "The managed default VPC, or null when create_default_vpc is false."
  value       = var.create_default_vpc ? aws_default_vpc.this[0].id : null
}

output "plan_role_arns" {
  description = "Per environment; empty when enable_ci_roles is false."
  value       = { for k, r in aws_iam_role.plan : k => r.arn }
}

output "apply_role_arns" {
  description = "Per environment; empty when enable_ci_roles is false."
  value       = { for k, r in aws_iam_role.apply : k => r.arn }
}
