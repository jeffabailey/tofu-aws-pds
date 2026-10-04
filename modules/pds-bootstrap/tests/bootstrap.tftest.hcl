# pds-bootstrap toggles and guards, against a mocked AWS provider. Creates nothing; no credentials.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "091153021562" }
  }
  mock_data "aws_route53_zone" {
    defaults = {
      name = "jeffbailey.us."
      arn  = "arn:aws:route53:::hostedzone/Z04289081C40P36K0S8LM"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::091153021562:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::091153021562:role/mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::091153021562:instance-profile/mock" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::091153021562:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  name_prefix         = "openlore"
  project             = "openlore"
  aws_region          = "us-east-1"
  expected_account_id = "091153021562"
  hosted_zone_id      = "Z04289081C40P36K0S8LM"
  dns_record_name     = "openlore.jeffbailey.us"
  environments = {
    prod = {
      environment           = "prod"
      atproto_namespace     = "org.openlore"
      pds_hostname          = "openlore.jeffbailey.us"
      handle                = "jeff.openlore.jeffbailey.us"
      tofu_state_key        = "openlore/pds/prod.tfstate"
      lifecycle             = "persistent"
      aws_region            = "us-east-1"
      instance_type         = "t4g.micro"
      data_volume_gb        = 5
      contact_ssm_parameter = "/openlore/prod/acme-contact-email"
    }
  }
}

# OpenLore's shape: laptop apply, an existing state bucket, no CI, and a default VPC to create.
run "laptop_only_toggles_create_only_the_host_side" {
  command = plan

  variables {
    create_state_bucket  = false
    state_bucket_name    = "jeffbaileyterraformstate"
    create_oidc_provider = false
    enable_ci_roles      = false
    create_default_vpc   = true
  }

  assert {
    condition     = length(aws_s3_bucket.state) == 0 && output.state_bucket == "jeffbaileyterraformstate"
    error_message = "No state bucket may be created when create_state_bucket is false."
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0 && length(aws_iam_role.apply) == 0 && length(aws_iam_openid_connect_provider.github) == 0 && length(data.aws_iam_openid_connect_provider.github_existing) == 0
    error_message = "No CI role or OIDC provider may exist when enable_ci_roles is false."
  }

  assert {
    condition     = length(aws_default_vpc.this) == 1
    error_message = "create_default_vpc must manage the default VPC."
  }

  assert {
    condition     = aws_s3_bucket.backup.bucket == "openlore-identity-backup-091153021562"
    error_message = "Backup bucket name is ${aws_s3_bucket.backup.bucket}."
  }

  assert {
    condition     = aws_iam_role.host["prod"].name == "openlore-pds-host-prod" && aws_iam_instance_profile.host["prod"].name == "openlore-pds-host-prod"
    error_message = "Host role / instance profile names must follow name_prefix."
  }

  assert {
    condition     = output.host_instance_profile_names == { prod = "openlore-pds-host-prod" }
    error_message = "host_instance_profile_names output is wrong."
  }

  assert {
    condition     = output.plan_role_arns == {} && output.apply_role_arns == {}
    error_message = "CI role outputs must be empty with CI roles off."
  }
}

# TRB's shape: everything on. Names keep the "<prefix>-..." pattern of the original root.
run "everything_on_creates_trb_shaped_names" {
  command = plan

  variables {
    name_prefix            = "trb"
    project                = "the-reality-base"
    expected_account_id    = null
    create_state_bucket    = true
    create_oidc_provider   = true
    enable_ci_roles        = true
    github_org             = "example-org"
    github_repo            = "example-repo"
    apply_job_workflow_ref = "example-org/example-repo/.github/workflows/deploy-pds.yml@refs/heads/main"
  }

  assert {
    condition     = aws_s3_bucket.state[0].bucket == "trb-tofu-state-091153021562"
    error_message = "State bucket name is ${aws_s3_bucket.state[0].bucket}."
  }

  assert {
    condition     = aws_iam_role.plan["prod"].name == "trb-tofu-plan-prod" && aws_iam_role.apply["prod"].name == "trb-tofu-apply-prod"
    error_message = "CI role names must follow name_prefix."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && length(aws_default_vpc.this) == 0
    error_message = "OIDC provider must be created and the default VPC left alone."
  }
}

run "wrong_account_is_refused" {
  command = plan

  variables {
    expected_account_id = "415898136109"
    create_state_bucket = false
    state_bucket_name   = "jeffbaileyterraformstate"
    enable_ci_roles     = false
  }

  expect_failures = [terraform_data.account_guard]
}

run "reusing_a_state_bucket_needs_its_name" {
  command = plan

  variables {
    create_state_bucket = false
    enable_ci_roles     = false
  }

  expect_failures = [terraform_data.inputs_are_consistent]
}

run "ci_roles_need_github_inputs" {
  command = plan

  variables {
    create_state_bucket = false
    state_bucket_name   = "jeffbaileyterraformstate"
    enable_ci_roles     = true
  }

  expect_failures = [terraform_data.inputs_are_consistent]
}

run "record_outside_the_zone_is_refused" {
  command = plan

  variables {
    create_state_bucket = false
    state_bucket_name   = "jeffbaileyterraformstate"
    enable_ci_roles     = false
    dns_record_name     = "openlore.example.org"
  }

  expect_failures = [terraform_data.zone_is_the_delegated_one]
}

# bootstrap_account: the host may write exactly its two account-password parameters, and only
# when asked to.
run "account_passwords_are_writable_only_when_asked" {
  command = plan

  variables {
    create_state_bucket  = false
    state_bucket_name    = "jeffbaileyterraformstate"
    create_oidc_provider = false
    enable_ci_roles      = false
    bootstrap_account    = true
  }

  assert {
    condition = toset(flatten([
      for s in data.aws_iam_policy_document.host_permissions["prod"].statement : s.resources
      if s.sid == "WriteOwnAccountPasswords"
      ])) == toset([
      "arn:aws:ssm:us-east-1:091153021562:parameter/openlore/prod/account-password",
      "arn:aws:ssm:us-east-1:091153021562:parameter/openlore/prod/cli-app-password",
    ])
    error_message = "The host must be able to write exactly /openlore/prod/{account-password,cli-app-password}."
  }
}

run "no_account_write_by_default" {
  command = plan

  variables {
    create_state_bucket  = false
    state_bucket_name    = "jeffbaileyterraformstate"
    create_oidc_provider = false
    enable_ci_roles      = false
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.host_permissions["prod"].statement : s if s.sid == "WriteOwnAccountPasswords"]) == 0
    error_message = "The host policy must not change when bootstrap_account is off."
  }
}

run "backup_metrics_lets_the_host_publish_only_its_namespace" {
  command = plan

  variables {
    create_state_bucket  = false
    state_bucket_name    = "jeffbaileyterraformstate"
    create_oidc_provider = false
    enable_ci_roles      = false
    backup_metrics       = true
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.host_permissions["prod"].statement :
      s.sid == "PublishBackupMetric" && toset(s.actions) == toset(["cloudwatch:PutMetricData"])
    ])
    error_message = "The host must be able to put the PDS/Backup metric."
  }
}

run "no_metric_grant_by_default" {
  command = plan

  variables {
    create_state_bucket  = false
    state_bucket_name    = "jeffbaileyterraformstate"
    create_oidc_provider = false
    enable_ci_roles      = false
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.host_permissions["prod"].statement : s if s.sid == "PublishBackupMetric"]) == 0
    error_message = "The host policy must not change when backup_metrics is off."
  }
}
