# Naming contract: for the-reality-base's inputs, every name the module produces is the name the
# pre-extraction module produced. The security group name is ForceNew -- a different name would
# replace it, and with it the instance's network attachment -- so this is a state contract, not
# a cosmetic one.

mock_provider "aws" {
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0001"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-east-1a"] }
  }
}

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
  hosted_zone_id        = "Z02283223U1ANYA4AW977"
  instance_profile_name = "trb-pds-host-prod"
  backup_bucket         = "trb-identity-backup-415898136109"
  ami_id                = "ami-00000000000000001"
}

run "trb_names_are_unchanged" {
  command = plan

  variables {
    name_prefix                        = "trb"
    project                            = "the-reality-base"
    require_namespace_matches_hostname = true
  }

  assert {
    condition     = aws_security_group.pds.name == "trb-pds-prod"
    error_message = "Security group name is ${aws_security_group.pds.name}; it is ForceNew and must stay trb-pds-prod."
  }

  assert {
    condition     = aws_ebs_volume.pds_data.tags["Name"] == "trb-pds-prod-data"
    error_message = "Data volume Name tag is ${aws_ebs_volume.pds_data.tags["Name"]}."
  }

  assert {
    condition     = aws_instance.pds.tags["Name"] == "trb-pds-prod" && aws_eip.pds.tags["Name"] == "trb-pds-prod"
    error_message = "Instance/EIP Name tags changed."
  }

  assert {
    condition     = aws_ebs_volume.pds_data.tags["Project"] == "the-reality-base" && aws_security_group.pds.tags["Project"] == "the-reality-base"
    error_message = "Project tag must come from var.project."
  }

  assert {
    condition     = aws_route53_record.pds.name == "graph.savetherepublic.us" && aws_route53_record.wildcard.name == "*.graph.savetherepublic.us"
    error_message = "DNS record names changed."
  }
}

run "another_project_gets_its_own_names" {
  command = plan

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
  }

  assert {
    condition     = aws_security_group.pds.name == "openlore-pds-prod"
    error_message = "Security group name is ${aws_security_group.pds.name}."
  }

  assert {
    condition     = aws_ebs_volume.pds_data.tags["Name"] == "openlore-pds-prod-data" && aws_ebs_volume.pds_data.tags["Project"] == "openlore"
    error_message = "Volume tags do not follow name_prefix/project."
  }
}

run "name_prefix_is_validated" {
  command = plan

  variables {
    name_prefix = "TRB_bad"
    project     = "the-reality-base"
  }

  expect_failures = [var.name_prefix]
}
