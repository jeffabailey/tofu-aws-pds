variable "name_prefix" {
  description = <<-EOT
    Prefix for every name this module creates: "<prefix>-tofu-state-<account>",
    "<prefix>-identity-backup-<account>", "<prefix>-pds-host-<env>", "<prefix>-tofu-plan-<env>",
    "<prefix>-tofu-apply-<env>". It also scopes the SSM deny on the CI roles to
    parameter/<prefix>/*. Bucket and role names are ForceNew: keep the prefix you started with.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must match ^[a-z][a-z0-9-]{1,20}$."
  }
}

variable "project" {
  description = "Project name, used on the tags of resources this module tags itself (the default VPC)."
  type        = string
}

variable "aws_region" {
  description = "Region of the PDS environments. Used to build SSM parameter ARNs and the kms:ViaService condition."
  type        = string
}

variable "expected_account_id" {
  description = <<-EOT
    Refuse to plan anywhere else. The deployment must land in the account that owns the hosted
    zone, or the DNS records it needs cannot be written at all. Null disables the guard.
  EOT
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = <<-EOT
    The EXISTING public Route 53 zone the PDS records go into, adopted rather than created.
    Pinned by id rather than looked up by name: a by-name lookup silently picks up a duplicate
    zone with the same name, and writes to the wrong one succeed and resolve nowhere.
  EOT
  type        = string
}

variable "dns_record_name" {
  description = "The name the PDS environments live under (e.g. openlore.jeffbailey.us). Checked against the zone's own name at plan time."
  type        = string
}

variable "environments" {
  description = <<-EOT
    The decoded environment descriptors, keyed by environment name. The caller reads them
    (jsondecode(file(...))) -- this module reads no files -- and each key must equal its
    descriptor's `environment`. Only `environment`, `tofu_state_key` and `contact_ssm_parameter`
    are used here, but the full descriptor shape is required so the same object feeds modules/pds.
  EOT
  type = map(object({
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
  }))

  validation {
    condition     = alltrue([for k, d in var.environments : k == d.environment])
    error_message = "Each environments key must equal its descriptor's environment field."
  }

  validation {
    condition     = length(var.environments) > 0
    error_message = "At least one environment is required."
  }
}

# ---- state ----------------------------------------------------------------------------------

variable "create_state_bucket" {
  description = "Create a versioned, encrypted, TLS-only state bucket \"<prefix>-tofu-state-<account>\". False reuses state_bucket_name."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "Existing state bucket, used when create_state_bucket is false (for the CI roles' grants and the state_bucket output). It should have versioning enabled."
  type        = string
  default     = null
}

variable "state_key_prefix" {
  description = "Prepended to each descriptor's tofu_state_key when scoping the CI roles' state grants. Empty when the descriptor key is already the full object key."
  type        = string
  default     = ""
}

# ---- network --------------------------------------------------------------------------------

variable "create_default_vpc" {
  description = <<-EOT
    Manage the region's default VPC with aws_default_vpc, which creates it (and a default subnet
    per AZ) when the account has none. modules/pds looks the default VPC up, so an account
    without one needs this. Removing it later only forgets the VPC; it is never deleted.
  EOT
  type        = bool
  default     = false
}

# ---- CI (GitHub OIDC) -----------------------------------------------------------------------

variable "enable_ci_roles" {
  description = "Create per-environment plan and apply roles assumable from GitHub Actions by OIDC. False means a human applies from a laptop and no CI role exists."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider (only when enable_ci_roles). False adopts an existing one: an account holds one provider per URL."
  type        = bool
  default     = true
}

variable "github_org" {
  description = "GitHub organisation or user owning the repository. Required when enable_ci_roles."
  type        = string
  default     = null
}

variable "github_repo" {
  description = "GitHub repository name. Required when enable_ci_roles."
  type        = string
  default     = null
}

variable "use_immutable_subject" {
  description = <<-EOT
    Whether the repository issues OIDC tokens with GitHub's immutable subject claims (numeric org
    and repo ids in `sub`). Check, do not guess:
      gh api /repos/<org>/<repo>/actions/oidc/customization/sub
  EOT
  type        = bool
  default     = false
}

variable "github_org_id" {
  description = "Numeric owner id (gh api repos/<org>/<repo> --jq .owner.id). Required when use_immutable_subject."
  type        = string
  default     = null
}

variable "github_repo_id" {
  description = "Numeric repository id (gh api repos/<org>/<repo> --jq .id). Required when use_immutable_subject."
  type        = string
  default     = null
}

variable "apply_job_workflow_ref" {
  description = "The exact workflow file allowed to assume the apply role, as the job_workflow_ref claim spells it, e.g. \"org/repo/.github/workflows/deploy-pds.yml@refs/heads/main\". Required when enable_ci_roles."
  type        = string
  default     = null
}
