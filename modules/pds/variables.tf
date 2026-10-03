variable "name_prefix" {
  description = <<-EOT
    Prefix for every resource name: the security group, instance and EIP are named
    "<name_prefix>-pds-<environment>", the data volume "<name_prefix>-pds-<environment>-data".
    The security group name is ForceNew, so an existing deployment must keep passing the prefix
    it was created with (the-reality-base passes "trb").
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must match ^[a-z][a-z0-9-]{1,20}$ (lowercase, starts with a letter, 2-21 chars)."
  }
}

variable "project" {
  description = "Value of the Project tag on every resource. A tag only: changing it is an in-place update."
  type        = string

  validation {
    condition     = length(trimspace(var.project)) > 0
    error_message = "project must not be empty."
  }
}

variable "require_namespace_matches_hostname" {
  description = <<-EOT
    Refuse a plan unless reverse(descriptor.atproto_namespace) == descriptor.pds_hostname.
    Off by default: a lexicon namespace is often a product domain that is not where the PDS is
    hosted. Turn it on when your naming policy ties the two together. The handle-under-hostname
    check is always on regardless of this setting.
  EOT
  type        = bool
  default     = false
}

variable "descriptor" {
  description = <<-EOT
    The decoded environment descriptor (typically jsondecode(file(".../environments/<env>.json"))).
    This is the single source of every name -- no caller passes a hostname or a namespace
    separately, because two places holding one fact drift apart. `atproto_namespace` is rendered
    into the host's PDS_ATPROTO_NAMESPACE (informational to the PDS) and checked only when
    require_namespace_matches_hostname is true.
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
  description = "Route 53 zone the hostname and wildcard A records are written into."
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

variable "swap_mb" {
  description = <<-EOT
    Size in MiB of a swap file created on the ROOT volume at first boot. 0 (the default) adds no
    swap and renders user_data byte-identical to v1.0.0, so existing deployments plan no change.
    1024 suits a t4g.micro (1 GiB RAM). Changing it on a live host changes user_data, which is an
    in-place stop/start, and cloud-init does not re-run on that restart: replace the instance (it
    is cattle) for a new value to take effect.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.swap_mb >= 0 && floor(var.swap_mb) == var.swap_mb
    error_message = "swap_mb must be a whole number >= 0."
  }
}

variable "bootstrap_account" {
  description = <<-EOT
    Create the descriptor's handle as the PDS's first account at first boot, with an app password
    for CLI use, and store both passwords as SSM SecureString parameters
    /<name_prefix>/<environment>/account-password and .../cli-app-password (the host role needs
    write access: set bootstrap_account on modules/pds-bootstrap too). The account email is the
    ACME contact. Idempotent: an existing handle is left alone. false (the default) renders
    user_data byte-identical to v1.1.0. Like swap_mb, turning it on for a live host changes
    user_data, and cloud-init only runs on a new instance: replace the instance to apply it.
  EOT
  type        = bool
  default     = false
}

variable "verification_methods" {
  description = <<-EOT
    Extra verification methods to publish in the account's did:plc document, as
    { "<method id>" = "did:key:z..." } -- e.g. { "org.openlore.application" = "did:key:z6Mk..." }
    for an application's Ed25519 claim-signing key. First boot signs the PLC update with this
    PDS's rotation key (so it needs the account to exist: pair with bootstrap_account or create
    it first). Idempotent; other methods (the account's #atproto key) are kept. {} (the default)
    renders user_data byte-identical to v1.2.x. Changing it on a live host means replacing the
    instance, like the other first-boot inputs.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for id, key in var.verification_methods :
      can(regex("^[a-z0-9][a-z0-9.-]{0,62}$", id)) && can(regex("^did:key:z[1-9A-HJ-NP-Za-km-z]+$", key))
    ])
    error_message = "verification_methods maps a lowercase method id to a did:key:z... value."
  }

  validation {
    condition     = !contains(keys(var.verification_methods), "atproto")
    error_message = "The #atproto method is the account's own signing key; the PDS manages it."
  }
}
