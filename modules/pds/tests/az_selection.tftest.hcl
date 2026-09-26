# Regression test for the apply failure of 2026-09-26 (run 36260085619):
#
#   Unsupported: Your requested instance type (t4g.small) is not supported in your
#   requested Availability Zone (us-east-1e).
#
# Root cause: the subnet was chosen with `sort(subnet_ids)[0]` -- deterministic, but arbitrary,
# and in the real account that is the us-east-1e subnet. Graviton availability is PER-AZ and is
# not uniform: t4g.small is offered in us-east-1a, 1b, 1c, 1d and 1f, and not in 1e.
#
# The defect's signature is that it PLANS PERFECTLY and fails at apply, after the security group
# and the prevent_destroy data volume already exist. So this test asserts on a plan: if the
# selection logic regresses, this goes red in milliseconds instead of stranding a protected
# volume in an AZ it cannot leave.
#
# Everything is mocked. The test creates nothing and needs no credentials.

mock_provider "aws" {}

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
  hosted_zone_id        = "Z02283223U1ANYA4AW977"
  instance_profile_name = "trb-pds-host-test"
  backup_bucket         = "trb-identity-backup-415898136109"
  ami_id                = "ami-00000000000000001"
}

# The world as it actually is: the lowest-sorting subnet sits in the one AZ that cannot run the
# instance type. A selection that ignores offerings picks exactly the wrong one.
override_data {
  target = data.aws_vpc.default
  values = { id = "vpc-regression" }
}

override_data {
  target = data.aws_ec2_instance_type_offerings.supported
  values = { locations = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"] }
}

# Every default subnet, INCLUDING the us-east-1e one that sorts first. This is the set the
# broken version chose from.
override_data {
  target = data.aws_subnets.default
  values = { ids = ["subnet-aaa1e", "subnet-bbb1a"] }
}

# The subnets the API returns once filtered to AZs that offer the instance type -- the 1e one
# is absent, exactly as EC2 would report it.
override_data {
  target = data.aws_subnets.usable
  values = { ids = ["subnet-bbb1a"] }
}

# Only computed fields can be overridden. `id` is configured (it comes from the usable set),
# so the AZ is the one thing to state here -- and it is the field the volume is placed by.
override_data {
  target = data.aws_subnet.chosen
  values = { availability_zone = "us-east-1a" }
}

run "the_instance_never_lands_in_an_az_that_cannot_run_it" {
  command = plan

  # The whole bug in one line: subnet-aaa1e sorts first and is what the broken version picked.
  assert {
    condition     = aws_instance.pds.subnet_id == "subnet-bbb1a"
    error_message = "Chose subnet ${aws_instance.pds.subnet_id}. subnet-aaa1e sorts first but sits in us-east-1e, which does not offer ${var.descriptor.instance_type}. Selection must come from the AZ-filtered set, not from every default subnet."
  }

  # The volume is the expensive half of this bug: it carries prevent_destroy, so landing it in
  # the wrong AZ means it cannot be moved without lifting the guard in a commit.
  assert {
    condition     = aws_ebs_volume.pds_data.availability_zone == "us-east-1a"
    error_message = "Volume would be created in ${aws_ebs_volume.pds_data.availability_zone}. It carries prevent_destroy and cannot change AZ, so a wrong choice here is only recoverable by lifting the guard."
  }

  assert {
    condition     = aws_ebs_volume.pds_data.availability_zone != "us-east-1e"
    error_message = "Volume placed in us-east-1e, the AZ that triggered the original failure."
  }
}
