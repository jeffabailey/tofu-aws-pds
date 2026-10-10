# v1.7.0: the host serves extra Caddy sites and keeps containers off the instance role.
#
# Sites: user_data creates /pds/caddy/sites, the Caddy container mounts it read-only at
# /etc/caddy/sites, and the Caddyfile imports /etc/caddy/sites/*.caddy at top level. Consumers'
# deploy scripts check exactly these three things (and never create the directory themselves).
#
# IMDS: the PUT response hop limit is 1 by default, so a container on a bridge network cannot get
# an IMDSv2 token; imds_hop_limit = 2 restores the v1.6.x behaviour for a consumer that needs it.

mock_provider "aws" {
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0001"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-east-1a"] }
  }
}

variables {
  name_prefix           = "example"
  project               = "example"
  instance_profile_name = "example-pds-host-prod"
  backup_bucket         = "example-identity-backup-000000000000"
  hosted_zone_id        = "Z0000000000000000000"
  ami_id                = "ami-00000000000000001"
  descriptor = {
    environment           = "prod"
    atproto_namespace     = "com.example.pds"
    pds_hostname          = "pds.example.com"
    handle                = "alice.pds.example.com"
    tofu_state_key        = "env/prod/pds.tfstate"
    lifecycle             = "persistent"
    aws_region            = "us-east-1"
    instance_type         = "t4g.small"
    data_volume_gb        = 20
    contact_ssm_parameter = "/example/prod/acme-contact-email"
  }
}

run "sites_directory_is_created_mounted_read_only_and_imported" {
  command = plan

  # Created by the module, on the data volume, before compose starts Caddy.
  assert {
    condition     = can(regex("(?m)^mkdir -p [^\n]* /pds/caddy/sites$", aws_instance.pds.user_data))
    error_message = "user_data does not create /pds/caddy/sites."
  }

  assert {
    condition     = can(regex("(?s)mkdir -p [^\n]*/pds/caddy/sites\n.*\ndocker compose up -d\n", aws_instance.pds.user_data))
    error_message = "/pds/caddy/sites must exist before docker compose starts Caddy."
  }

  # The mount: that exact source, that exact destination, read-only, on the caddy service.
  assert {
    condition     = strcontains(aws_instance.pds.user_data, "      - /pds/caddy/config:/config\n      - /pds/caddy/sites:/etc/caddy/sites:ro\n    depends_on:\n      - pds\n\n  pds:\n")
    error_message = "The caddy service does not mount /pds/caddy/sites at /etc/caddy/sites:ro."
  }

  assert {
    condition     = length(regexall("/pds/caddy/sites:/etc/caddy/sites", aws_instance.pds.user_data)) == 1
    error_message = "/pds/caddy/sites must be mounted exactly once (on caddy only)."
  }

  # The import: a live top-level line, last in the Caddyfile, matching the consumers' check
  # ^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\*\.caddy
  assert {
    condition     = can(regex("(?m)^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\\*\\.caddy$", aws_instance.pds.user_data))
    error_message = "The Caddyfile does not import /etc/caddy/sites/*.caddy."
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "\treverse_proxy http://pds:3000\n}\n\n") && can(regex("\nimport /etc/caddy/sites/\\*\\.caddy\nCADDYEOF\n", aws_instance.pds.user_data))
    error_message = "The import must be the Caddyfile's last line, at top level, after the PDS site blocks."
  }
}

run "imds_hop_limit_defaults_to_1" {
  command = plan

  assert {
    condition     = aws_instance.pds.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit must default to 1: containers must not read the instance role."
  }

  assert {
    condition     = aws_instance.pds.metadata_options[0].http_tokens == "required" && aws_instance.pds.metadata_options[0].http_endpoint == "enabled"
    error_message = "IMDSv2 must stay required and the endpoint enabled (the host's own AWS calls need it)."
  }
}

run "imds_hop_limit_2_is_an_explicit_opt_out" {
  command = plan

  variables {
    imds_hop_limit = 2
  }

  assert {
    condition     = aws_instance.pds.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "imds_hop_limit = 2 is not passed to the instance."
  }
}

run "imds_hop_limit_0_is_refused" {
  command = plan

  variables {
    imds_hop_limit = 0
  }

  expect_failures = [var.imds_hop_limit]
}
