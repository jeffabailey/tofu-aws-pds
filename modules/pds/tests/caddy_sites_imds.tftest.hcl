# v1.7.0: the host serves extra Caddy sites.
#
# Sites: user_data creates /pds/caddy/sites, the Caddy container mounts it read-only at
# /etc/caddy/sites, and the Caddyfile imports /etc/caddy/sites/*.caddy at top level. Consumers'
# deploy scripts check exactly these three things (and never create the directory themselves).

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
