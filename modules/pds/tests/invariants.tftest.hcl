# Naming invariants. The namespace check is opt-in (require_namespace_matches_hostname); the
# handle-under-hostname check is always on. Both live in terraform_data.name_invariants, whose
# address must never move.

mock_provider "aws" {
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0001"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-east-1a"] }
  }
}

variables {
  name_prefix = "openlore"
  project     = "openlore"
  descriptor = {
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
  hosted_zone_id        = "Z04289081C40P36K0S8LM"
  instance_profile_name = "openlore-pds-host-prod"
  backup_bucket         = "openlore-identity-backup-091153021562"
  ami_id                = "ami-00000000000000001"
}

run "namespace_check_off_allows_a_product_namespace" {
  command = plan

  assert {
    condition     = aws_security_group.pds.name == "openlore-pds-prod"
    error_message = "A mismatched namespace must plan when the check is off."
  }
}

run "namespace_check_on_refuses_a_mismatch" {
  command = plan

  variables {
    require_namespace_matches_hostname = true
  }

  expect_failures = [terraform_data.name_invariants]
}

run "namespace_check_on_accepts_a_reversed_hostname" {
  command = plan

  variables {
    require_namespace_matches_hostname = true
    descriptor = {
      environment           = "prod"
      atproto_namespace     = "us.savetherepublic.graph"
      pds_hostname          = "graph.savetherepublic.us"
      handle                = "trb.graph.savetherepublic.us"
      tofu_state_key        = "env/prod/pds.tfstate"
      lifecycle             = "persistent"
      aws_region            = "us-east-1"
      instance_type         = "t4g.small"
      data_volume_gb        = 20
      contact_ssm_parameter = "/trb/prod/acme-contact-email"
    }
  }

  assert {
    condition     = aws_security_group.pds.name == "openlore-pds-prod"
    error_message = "A matching namespace must plan with the check on."
  }
}

run "handle_outside_hostname_always_fails_check_off" {
  command = plan

  variables {
    descriptor = {
      environment           = "prod"
      atproto_namespace     = "org.openlore"
      pds_hostname          = "openlore.jeffbailey.us"
      handle                = "jeff.bsky.social"
      tofu_state_key        = "openlore/pds/prod.tfstate"
      lifecycle             = "persistent"
      aws_region            = "us-east-1"
      instance_type         = "t4g.micro"
      data_volume_gb        = 5
      contact_ssm_parameter = "/openlore/prod/acme-contact-email"
    }
  }

  expect_failures = [terraform_data.name_invariants]
}

run "handle_outside_hostname_always_fails_check_on" {
  command = plan

  variables {
    require_namespace_matches_hostname = true
    descriptor = {
      environment           = "prod"
      atproto_namespace     = "us.jeffbailey.openlore"
      pds_hostname          = "openlore.jeffbailey.us"
      handle                = "openlore.jeffbailey.us.evil.example"
      tofu_state_key        = "openlore/pds/prod.tfstate"
      lifecycle             = "persistent"
      aws_region            = "us-east-1"
      instance_type         = "t4g.micro"
      data_volume_gb        = 5
      contact_ssm_parameter = "/openlore/prod/acme-contact-email"
    }
  }

  expect_failures = [terraform_data.name_invariants]
}
