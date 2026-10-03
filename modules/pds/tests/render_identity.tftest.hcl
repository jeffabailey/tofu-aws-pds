# Render identity: the host bootstrap the-reality-base (TRB) gets for its inputs is pinned, so any
# change to it is a deliberate, CHANGELOG-listed release rather than a surprise in a plan.
#
# A user_data change on a live instance is an in-place stop/start (AWS provider v6). The PDS
# survives it -- the volume and EIP are separate resources -- but an UNPLANNED one is exactly the
# regression this test exists to catch: a changed user_data is the easiest way to sneak a diff
# past a reviewer who expects none.
#
# HOW THE GOLDEN HASHES WERE DERIVED:
#   v1.0.0-v1.3.0 (2026-10-02): sha256 of the ORIGINAL, pre-extraction template at the-reality-base
#   commit 025bec4, rendered with TRB's deploy/environments/{prod,test}.json, the default
#   pds_image digest, backup_bucket "trb-identity-backup-415898136109" and aws_region "us-east-1":
#     prod  769544157dc032f60110b15f0203e0995291a1952fe3299141a65dab7527b19b
#     test  1ec07ff737a444ab9124224b4b262ce8bac0bfb5ace19062605872a4e2c9942e
#   v1.4.0 (2026-10-03): the same inputs after the identity-backup fix, whose only change is the
#   body of /usr/local/bin/pds-backup-identity (hybrid encryption; see CHANGELOG):
#     prod  2fc2df2ec6addb93c5846a6f5d578310998ddb6e9ae7d3946067e54ac124a368
#     test  0b2f169dd869dfc3368f4ffd91f9955cb67c6eaa54d9870dc332055fbcd31a7b

# Everything is mocked. The test creates nothing and needs no credentials.

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
  instance_profile_name              = "trb-pds-host-prod"
  backup_bucket                      = "trb-identity-backup-415898136109"
  hosted_zone_id                     = "Z02283223U1ANYA4AW977"
  ami_id                             = "ami-00000000000000001"
}

run "trb_prod_renders_byte_identical" {
  command = plan

  variables {
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
    condition     = sha256(aws_instance.pds.user_data) == "2fc2df2ec6addb93c5846a6f5d578310998ddb6e9ae7d3946067e54ac124a368"
    error_message = "TRB prod user_data changed: sha256 ${sha256(aws_instance.pds.user_data)}. Applying this would stop/start the live prod PDS."
  }
}

run "trb_test_renders_byte_identical" {
  command = plan

  variables {
    descriptor = {
      environment           = "test"
      atproto_namespace     = "us.savetherepublic.graph.test"
      pds_hostname          = "test.graph.savetherepublic.us"
      handle                = "trb.test.graph.savetherepublic.us"
      tofu_state_key        = "env/test/pds.tfstate"
      lifecycle             = "ephemeral-compute"
      aws_region            = "us-east-1"
      instance_type         = "t4g.small"
      data_volume_gb        = 20
      contact_ssm_parameter = "/trb/test/acme-contact-email"
    }
    instance_profile_name = "trb-pds-host-test"
  }

  assert {
    condition     = sha256(aws_instance.pds.user_data) == "0b2f169dd869dfc3368f4ffd91f9955cb67c6eaa54d9870dc332055fbcd31a7b"
    error_message = "TRB test user_data changed: sha256 ${sha256(aws_instance.pds.user_data)}."
  }
}
