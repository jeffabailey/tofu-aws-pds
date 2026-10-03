# Render identity: the extraction must not change a single byte of the host bootstrap for the
# inputs the-reality-base (TRB) already runs with.
#
# A user_data change on a live instance is an in-place stop/start (AWS provider v6). The PDS
# survives it -- the volume and EIP are separate resources -- but an UNPLANNED stop/start during
# the cut-over is exactly the regression this test exists to catch. TRB's cut-over gate is "no
# create, delete or replace on any address", and a changed user_data is the easiest way to
# sneak a diff past a reviewer who expects none.
#
# HOW THE GOLDEN HASHES WERE DERIVED (2026-10-02):
#   A throwaway OpenTofu root (no providers) evaluated
#     sha256(templatefile("<the-reality-base>/deploy/tofu/modules/pds/user-data.sh.tftpl", {...}))
#   against the ORIGINAL, pre-extraction template at the-reality-base commit 025bec4, with the
#   same eight variables the module passes, filled from TRB's deploy/environments/{prod,test}.json,
#   the module's default pds_image digest, backup_bucket "trb-identity-backup-415898136109" and
#   aws_region "us-east-1". `tofu output` printed:
#     prod  769544157dc032f60110b15f0203e0995291a1952fe3299141a65dab7527b19b
#     test  1ec07ff737a444ab9124224b4b262ce8bac0bfb5ace19062605872a4e2c9942e
#   Before TRB's cut-over these should also be compared against the live instance's user_data
#   (ADR-069 step 1). If they ever disagree, the live value wins and this file is wrong.
#
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
    condition     = sha256(aws_instance.pds.user_data) == "769544157dc032f60110b15f0203e0995291a1952fe3299141a65dab7527b19b"
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
    condition     = sha256(aws_instance.pds.user_data) == "1ec07ff737a444ab9124224b4b262ce8bac0bfb5ace19062605872a4e2c9942e"
    error_message = "TRB test user_data changed: sha256 ${sha256(aws_instance.pds.user_data)}."
  }
}
