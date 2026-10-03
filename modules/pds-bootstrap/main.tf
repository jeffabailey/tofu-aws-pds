# The per-account foundation a PDS environment stands on: the account guard and zone checks,
# the identity backup bucket, one host role + instance profile per environment, and -- behind
# toggles -- a state bucket, the default VPC, the GitHub OIDC provider and per-environment CI
# roles.
#
# Generalised from the-reality-base deploy/tofu/bootstrap. Differences from that root:
#   - no provider or backend block (the calling root owns both);
#   - no file reads: environment descriptors arrive as `var.environments`;
#   - names are "${name_prefix}-…" instead of "trb-…";
#   - the state bucket, the OIDC provider and the CI roles are optional, and the default VPC
#     can be created.
# Resource names match that root, so an existing bootstrap can adopt this module with one
# `moved {}` block per resource (e.g. aws_s3_bucket.state -> module.bootstrap.aws_s3_bucket.state[0]).
#
# The bootstrap is applied by a human, with human credentials, before anything else.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  state_bucket_name = var.create_state_bucket ? aws_s3_bucket.state[0].id : var.state_bucket_name
  state_bucket_arn  = var.create_state_bucket ? aws_s3_bucket.state[0].arn : "arn:aws:s3:::${coalesce(var.state_bucket_name, "-")}"

  ci_environments = var.enable_ci_roles ? var.environments : {}
}

# The deployment must land in the account that owns the zone, or the DNS records it needs
# cannot be written at all.
resource "terraform_data" "account_guard" {
  lifecycle {
    precondition {
      condition     = var.expected_account_id == null || local.account_id == var.expected_account_id
      error_message = "Wrong AWS account. Expected ${coalesce(var.expected_account_id, "-")}, got ${local.account_id}. Check AWS_PROFILE / the provider's profile."
    }
  }
}

# Inputs that are only required together, checked at plan time with a message that names them.
resource "terraform_data" "inputs_are_consistent" {
  lifecycle {
    precondition {
      condition     = var.create_state_bucket || var.state_bucket_name != null
      error_message = "create_state_bucket is false, so state_bucket_name must name the existing state bucket."
    }
    precondition {
      condition     = !var.enable_ci_roles || (var.github_org != null && var.github_repo != null && var.apply_job_workflow_ref != null)
      error_message = "enable_ci_roles needs github_org, github_repo and apply_job_workflow_ref."
    }
    precondition {
      condition     = !(var.enable_ci_roles && var.use_immutable_subject) || (var.github_org_id != null && var.github_repo_id != null)
      error_message = "use_immutable_subject needs github_org_id and github_repo_id."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# 1. Remote state (optional). Versioned, encrypted, private, and protected from this
#    configuration itself. With create_state_bucket = false an existing bucket is used; enable
#    versioning on it first, because state is the one file a bad apply can corrupt.
# ---------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = "${var.name_prefix}-tofu-state-${local.account_id}"

  # A plan that would delete the state bucket fails at plan time, before any approval.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count                   = var.create_state_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# OpenTofu state stores variable values in the clear, including ones marked sensitive.
resource "aws_s3_bucket_policy" "state_tls_only" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.state[0].arn,
        "${aws_s3_bucket.state[0].arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ---------------------------------------------------------------------------------------------
# 2. The backup bucket. Separate from state, and no CI role may touch it. It holds the
#    encrypted identity archive -- the PLC rotation key, the one asset that cannot be
#    regenerated. Records are re-importable; a did:plc is not.
# ---------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "backup" {
  bucket = "${var.name_prefix}-identity-backup-${local.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------------------------
# 3. DNS. The zone is ADOPTED, not created; the PDS hostname is a record inside it.
# ---------------------------------------------------------------------------------------------

data "aws_route53_zone" "pds" {
  zone_id = var.hosted_zone_id
}

resource "terraform_data" "zone_is_the_delegated_one" {
  lifecycle {
    precondition {
      condition     = data.aws_route53_zone.pds.private_zone != true
      error_message = "Hosted zone ${var.hosted_zone_id} is private. A PDS needs public DNS."
    }
    precondition {
      condition     = endswith(var.dns_record_name, trimsuffix(data.aws_route53_zone.pds.name, "."))
      error_message = "Record '${var.dns_record_name}' does not belong in zone '${data.aws_route53_zone.pds.name}'."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# 4. Network (optional). modules/pds places the host in the default VPC; an account that has
#    deleted its default VPC gets it back here, for free. aws_default_vpc never deletes the VPC
#    on destroy (force_destroy is false): removing it from config only forgets it.
# ---------------------------------------------------------------------------------------------

resource "aws_default_vpc" "this" {
  count = var.create_default_vpc ? 1 : 0

  tags = {
    Name    = "default"
    Project = var.project
  }
}

# ---------------------------------------------------------------------------------------------
# 5. OIDC (only with CI roles). No long-lived AWS credential exists to leak.
# ---------------------------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_ci_roles && var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS stopped verifying this thumbprint for token.actions.githubusercontent.com in 2023, but the
  # API still requires the field. Kept for compatibility; it is not a security control here.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github_existing" {
  count = var.enable_ci_roles && !var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = (
    !var.enable_ci_roles ? null :
    var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn :
    data.aws_iam_openid_connect_provider.github_existing[0].arn
  )
}
