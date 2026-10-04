output "public_ip" {
  description = "Elastic IP. Stable across instance replacement."
  value       = aws_eip.pds.public_ip
}

output "pds_url" {
  value = "https://${local.hostname}"
}

output "handle" {
  value = local.handle
}

output "atproto_namespace" {
  description = "Baked into the collection and $type of every record (RISK-3). Changing it after an import orphans them all."
  value       = local.namespace
}

output "instance_id" {
  value = aws_instance.pds.id
}

output "data_volume_id" {
  description = "The volume that must outlive the instance. Carries prevent_destroy."
  value       = aws_ebs_volume.pds_data.id
}

# Nothing sensitive is output, and nothing can be: every credential is generated on the host and
# never becomes an OpenTofu value (ADR-013 §3). If this list ever needed a `sensitive = true`,
# that would be the bug.

output "account_ssm_parameters" {
  description = "SSM parameter names holding the first account's passwords, when bootstrap_account is on."
  value = var.bootstrap_account ? {
    account_password = "${local.account_ssm_prefix}/account-password"
    cli_app_password = "${local.account_ssm_prefix}/cli-app-password"
  } : null
}

output "backup_alarm_topic_arn" {
  description = "SNS topic the backup alarm notifies (subscribe to it out of band), when backup_alarm is on."
  value       = var.backup_alarm ? aws_sns_topic.backup_alarm[0].arn : null
}
