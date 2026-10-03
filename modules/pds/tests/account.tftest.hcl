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

run "account_on_renders_the_account_step" {
  command = plan

  variables {
    bootstrap_account = true
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "      - /pds:/pds\n    # Loopback only") && strcontains(aws_instance.pds.user_data, "- \"127.0.0.1:3000:3000\"\nCOMPOSEEOF")
    error_message = "The PDS port must be published on loopback only, inside the pds service."
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "/usr/local/bin/pds-ensure-account \"trb.graph.savetherepublic.us\" \"/trb/prod\" \"$REGION\" \"$CONTACT_PARAM\"")
    error_message = "The account step must run for the descriptor's handle with the /<prefix>/<env> SSM prefix."
  }

  # Idempotency and ordering: an existing handle exits before anything is created, and the
  # account password is stored before the app password is minted.
  assert {
    condition = (
      strcontains(aws_instance.pds.user_data, "resolveHandle?handle=$HANDLE") &&
      length(split("--name \"$PREFIX/account-password\"", aws_instance.pds.user_data)[0]) <
      length(split("createAppPassword", aws_instance.pds.user_data)[0])
    )
    error_message = "The account step must check for the handle first and store the account password before minting the app password."
  }

  assert {
    condition     = output.account_ssm_parameters.cli_app_password == "/trb/prod/cli-app-password"
    error_message = "The output must name the app-password parameter."
  }
}
