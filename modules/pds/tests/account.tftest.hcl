# bootstrap_account (v1.2.0). Off must leave user_data byte-identical to v1.1.0 (the golden hash
# of render_identity.tftest.hcl); on renders the loopback port and the idempotent account step.

mock_provider "aws" {
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0001"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-east-1a"] }
  }
}

variables {
  name_prefix                        = "trb"
  project                            = "the-reality-base"
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
  instance_profile_name = "trb-pds-host-prod"
  backup_bucket         = "trb-identity-backup-415898136109"
  hosted_zone_id        = "Z02283223U1ANYA4AW977"
  ami_id                = "ami-00000000000000001"
}

run "account_off_is_byte_identical_to_v1_1_0" {
  command = plan

  variables {
    bootstrap_account = false
  }

  assert {
    condition     = sha256(aws_instance.pds.user_data) == "769544157dc032f60110b15f0203e0995291a1952fe3299141a65dab7527b19b"
    error_message = "bootstrap_account = false changed user_data (sha256 ${sha256(aws_instance.pds.user_data)})."
  }

  assert {
    condition     = output.account_ssm_parameters == null
    error_message = "No account parameters are named when the account step is off."
  }
}

# With swap AND the account step (OpenLore's shape) the script passes EC2's 16 KiB user_data
# limit, so it is delivered gzipped. Its content is checked by scripts/check-user-data.sh, which renders the template
# directly; here the delivery and the output are pinned.
run "account_on_is_delivered_gzipped" {
  command = plan

  variables {
    bootstrap_account = true
    swap_mb           = 1024
  }

  assert {
    condition     = aws_instance.pds.user_data == null && aws_instance.pds.user_data_base64 != null
    error_message = "An over-16-KiB script must go through user_data_base64 (gzipped), not user_data."
  }

  assert {
    condition     = output.account_ssm_parameters.cli_app_password == "/trb/prod/cli-app-password"
    error_message = "The output must name the app-password parameter."
  }
}

run "verification_methods_refuse_the_atproto_key" {
  command = plan

  variables {
    verification_methods = { atproto = "did:key:z6MkpwHtDxopasFQ89TVijaSDqyTUvp4auQARnJgQj5LbQgR" }
  }

  expect_failures = [var.verification_methods]
}

run "verification_methods_must_be_did_keys" {
  command = plan

  variables {
    verification_methods = { "org.openlore.application" = "hex:0011" }
  }

  expect_failures = [var.verification_methods]
}

run "verification_methods_render_the_plc_step" {
  command = plan

  variables {
    bootstrap_account    = true
    swap_mb              = 1024
    verification_methods = { "org.openlore.application" = "did:key:z6MkpwHtDxopasFQ89TVijaSDqyTUvp4auQARnJgQj5LbQgR" }
  }

  assert {
    condition     = aws_instance.pds.user_data_base64 != null
    error_message = "The script with the PLC step is delivered gzipped."
  }
}
