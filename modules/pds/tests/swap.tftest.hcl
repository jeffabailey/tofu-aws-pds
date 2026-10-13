# swap_mb (v1.1.0). 0 must leave user_data byte-identical to v1.0.0 -- the same golden hash as
# render_identity.tftest.hcl -- so an existing consumer bumps the tag with a no-op plan.

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

run "swap_zero_renders_the_golden" {
  command = plan

  variables {
    swap_mb = 0
  }

  assert {
    condition     = sha256(aws_instance.pds.user_data) == "eaa367e2744a8df071e069e547a486f1dcf512f51d3f7c4245c37fb0ee107f4a"
    error_message = "swap_mb = 0 changed user_data (sha256 ${sha256(aws_instance.pds.user_data)})."
  }

  assert {
    condition     = !strcontains(aws_instance.pds.user_data, "swapon")
    error_message = "swap_mb = 0 must render no swap step."
  }
}

run "swap_1024_renders_a_swapfile_step" {
  command = plan

  variables {
    swap_mb = 1024
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "SWAP_MB=1024\n")
    error_message = "The swap size is not rendered."
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "mkswap \"$SWAPFILE\"") && strcontains(aws_instance.pds.user_data, "swapon \"$SWAPFILE\"")
    error_message = "The swap file is not created and enabled."
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "/swapfile none swap defaults 0 0") || strcontains(aws_instance.pds.user_data, "$SWAPFILE none swap defaults 0 0")
    error_message = "The swap file is not persisted in fstab."
  }

  # Before the package update, which is the memory squeeze swap exists for; and never on /pds.
  assert {
    condition     = strcontains(aws_instance.pds.user_data, "swapon \"$SWAPFILE\"\n\ndnf -q -y update") && !strcontains(aws_instance.pds.user_data, "SWAPFILE=/pds")
    error_message = "Swap must be set up on the root volume before dnf update."
  }

  assert {
    condition     = sha256(aws_instance.pds.user_data) != "eaa367e2744a8df071e069e547a486f1dcf512f51d3f7c4245c37fb0ee107f4a"
    error_message = "swap_mb = 1024 rendered the same user_data as swap_mb = 0."
  }
}

run "negative_swap_is_refused" {
  command = plan

  variables {
    swap_mb = -1
  }

  expect_failures = [var.swap_mb]
}

# swappiness (v1.8.0). null must leave user_data byte-identical; a value is written to sysctl.d
# and applied at once, inside the swap step.
run "swappiness_null_leaves_the_swap_step_unchanged" {
  command = plan

  variables {
    swap_mb = 1024
  }

  assert {
    condition     = !strcontains(aws_instance.pds.user_data, "swappiness") && strcontains(aws_instance.pds.user_data, "swapon \"$SWAPFILE\"\n\ndnf -q -y update")
    error_message = "swappiness = null must render no swappiness step."
  }
}

run "swappiness_10_is_persisted_and_applied" {
  command = plan

  variables {
    swap_mb    = 1024
    swappiness = 10
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "echo \"vm.swappiness = 10\" > /etc/sysctl.d/90-pds-swappiness.conf\nsysctl -q -w vm.swappiness=10\n\ndnf -q -y update")
    error_message = "swappiness = 10 must be written to sysctl.d and applied before dnf update."
  }
}

run "swappiness_out_of_range_is_refused" {
  command = plan

  variables {
    swap_mb    = 1024
    swappiness = 201
  }

  expect_failures = [var.swappiness]
}

run "swappiness_without_swap_is_refused" {
  command = plan

  variables {
    swap_mb    = 0
    swappiness = 10
  }

  expect_failures = [var.swappiness]
}
