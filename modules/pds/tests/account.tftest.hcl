# bootstrap_account (v1.2.0). Off must leave user_data byte-identical to v1.1.0 (the golden hash
# of render_identity.tftest.hcl); on renders the loopback port and the idempotent account step.

mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:415898136109:trb-pds-prod-backup-alarm" }
  }
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

run "account_off_renders_the_golden" {
  command = plan

  variables {
    bootstrap_account = false
  }

  assert {
    condition     = sha256(aws_instance.pds.user_data) == "eaa367e2744a8df071e069e547a486f1dcf512f51d3f7c4245c37fb0ee107f4a"
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

run "backup_schedule_renders_a_systemd_timer" {
  command = plan

  variables {
    backup_on_calendar = "daily"
  }

  assert {
    condition = (
      strcontains(aws_instance.pds.user_data, "OnCalendar=daily\n") &&
      strcontains(aws_instance.pds.user_data, "ConditionPathExists=/pds/backup-pubkey.pem") &&
      strcontains(aws_instance.pds.user_data, "systemctl enable --now pds-backup-identity.timer")
    )
    error_message = "A backup schedule must install and enable the timer, gated on the public key."
  }
}

run "backup_schedule_refuses_unit_file_injection" {
  command = plan

  variables {
    backup_on_calendar = "daily\nExecStartPre=/bin/true"
  }

  expect_failures = [var.backup_on_calendar]
}

run "backup_alarm_off_creates_nothing" {
  command = plan

  variables {
    backup_on_calendar = "daily"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.backup_missing) == 0 && length(aws_sns_topic.backup_alarm) == 0 && output.backup_alarm_topic_arn == null
    error_message = "No alarm resources unless backup_alarm is on."
  }

  assert {
    condition     = !strcontains(aws_instance.pds.user_data, "put-metric-data")
    error_message = "No metric publish unless backup_alarm is on."
  }
}

run "backup_alarm_fires_after_two_missed_days" {
  command = plan

  variables {
    backup_on_calendar = "daily"
    backup_alarm       = true
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backup_missing[0].alarm_name == "trb-pds-prod-backup-missing" &&
      aws_cloudwatch_metric_alarm.backup_missing[0].namespace == "PDS/Backup" &&
      aws_cloudwatch_metric_alarm.backup_missing[0].dimensions.Pds == "trb-pds-prod" &&
      aws_cloudwatch_metric_alarm.backup_missing[0].period == 86400 &&
      aws_cloudwatch_metric_alarm.backup_missing[0].evaluation_periods == 2 &&
      aws_cloudwatch_metric_alarm.backup_missing[0].datapoints_to_alarm == 2 &&
      aws_cloudwatch_metric_alarm.backup_missing[0].treat_missing_data == "breaching"
    )
    error_message = "The alarm must fire only after two whole UTC days without a successful backup."
  }

  assert {
    condition     = aws_sns_topic.backup_alarm[0].name == "trb-pds-prod-backup-alarm"
    error_message = "The topic follows the <prefix>-pds-<env> naming the CI roles are scoped to."
  }

  assert {
    condition     = strcontains(aws_instance.pds.user_data, "ExecStartPost=/usr/bin/aws cloudwatch put-metric-data --region us-east-1 --namespace PDS/Backup --metric-name ArchiveUploaded --dimensions Pds=trb-pds-prod --value 1")
    error_message = "The backup service must publish the metric the alarm watches, only after success."
  }
}

run "backup_alarm_needs_a_schedule" {
  command = plan

  variables {
    backup_alarm = true
  }

  expect_failures = [terraform_data.backup_alarm_needs_a_schedule]
}
