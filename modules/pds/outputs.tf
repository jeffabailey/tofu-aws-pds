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
