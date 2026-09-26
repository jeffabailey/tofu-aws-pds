variable "descriptor" {
  description = <<-EOT
    The decoded environment descriptor from deploy/environments/<env>.json. This is the single
    source of every name (ADR-012 §1) -- no caller passes a hostname or a namespace separately,
    because two places holding one fact is exactly the failure Gap 3 describes.
  EOT

  type = object({
    environment           = string
    atproto_namespace     = string
    pds_hostname          = string
    handle                = string
    tofu_state_key        = string
    lifecycle             = string
    aws_region            = string
    instance_type         = string
    data_volume_gb        = number
    contact_ssm_parameter = string
  })
}

variable "hosted_zone_id" {
  description = "Route 53 zone for the delegated subdomain, from the bootstrap output."
  type        = string
}

variable "instance_profile_name" {
  description = "Instance profile the host assumes, from the bootstrap output."
  type        = string
}

variable "backup_bucket" {
  description = "Bucket the host writes its encrypted identity archive to."
  type        = string
}

variable "pds_image" {
  description = <<-EOT
    The PDS image, pinned BY DIGEST rather than by tag. A tag is mutable: upstream runs
    watchtower against `:0.4` on a nightly schedule, which silently replaces the running image
    on an internet-facing service. VER-1 confirmed this digest is a manifest list carrying
    linux/arm64.
  EOT
  type        = string
  default     = "ghcr.io/bluesky-social/pds@sha256:05e164855fa1a3cf251c002210c46f8c86e7ae27bddc7a96045da25483840826"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.pds_image))
    error_message = "The PDS image must be pinned by digest (…@sha256:<64 hex>), never by tag."
  }
}

variable "ami_id" {
  description = <<-EOT
    Pin the AMI explicitly. Null resolves the current Amazon Linux 2023 arm64 image at apply
    time; the instance carries ignore_changes on `ami`, so a later AWS release does not silently
    replace the host. Upgrading is a commit that sets this.
  EOT
  type        = string
  default     = null
}

variable "ssh_key_name" {
  description = "EC2 key pair for break-glass access. Null means no key, which is the default."
  type        = string
  default     = null
}

variable "ssh_ingress_cidr" {
  description = <<-EOT
    Single address allowed to reach port 22, as a CIDR (e.g. "203.0.113.4/32"). Null closes SSH
    entirely, which is the default: this host holds a private key that cannot be regenerated.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.ssh_ingress_cidr == null || can(cidrhost(coalesce(var.ssh_ingress_cidr, "0.0.0.0/32"), 0))
    error_message = "ssh_ingress_cidr must be valid CIDR notation, or null."
  }

  validation {
    condition     = var.ssh_ingress_cidr != "0.0.0.0/0"
    error_message = "Refusing to open SSH to the whole internet on the host holding the PLC rotation key."
  }
}
