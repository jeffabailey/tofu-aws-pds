# IAM. Every environment gets a HOST role + instance profile. With enable_ci_roles, every
# environment also gets two CI roles: one that can only read (plan), one that can only be
# assumed from one workflow file on main (apply).
#
# The risk is not in the ARN -- an ARN is not confidential. The risk is in the trust policy's
# subject condition. A policy scoped to the repository WITHOUT a ref or environment condition
# lets any workflow on any ref assume the role, including one a pull request introduces. It is
# the single most consequential line in this file.
#
# NOTE ON `StringEquals` WITH A LIST -- this is an OR, not an AND.
#   "`…:pull_request` and `…:ref:refs/heads/main`" is ambiguous in prose. A token's `sub` is ONE string;
#   it can never be both at once, so an AND would deny every request. IAM evaluates a list under
#   one condition key as "matches any", which is the intended meaning: plan may run from a pull
#   request OR from main. It is written as a list here so the semantics are in the code rather
#   than in the prose.

# IMMUTABLE SUBJECT CLAIMS.
#
# A repository that opts into GitHub's immutable subject claims issues tokens whose `sub` is NOT
# the widely-published `repo:<org>/<repo>:...` but carries the NUMERIC ids:
#
#     repo:<org>@<org_id>/<repo>@<repo_id>:ref:refs/heads/main
#
# A policy written in the name-only form cannot match any such token, and every assume-role
# fails with "Not authorized to perform sts:AssumeRoleWithWebIdentity", which says nothing about
# why. Check `gh api /repos/<org>/<repo>/actions/oidc/customization/sub` and set
# use_immutable_subject to match. The id form is the STRONGER binding: a repository deleted and
# recreated under the same name gets a new id, so a stale trust policy stops matching.

locals {
  # Null-safe: these are only USED when enable_ci_roles is true, which the input-consistency
  # precondition ties to the github_* inputs being set.
  repo = "${coalesce(var.github_org, "-")}/${coalesce(var.github_repo, "-")}"

  # Built from the ids rather than hardcoded, so the two halves cannot drift apart.
  subject_prefix = var.use_immutable_subject ? "repo:${coalesce(var.github_org, "-")}@${coalesce(var.github_org_id, "-")}/${coalesce(var.github_repo, "-")}@${coalesce(var.github_repo_id, "-")}" : "repo:${local.repo}"

  # Plan: read-only, and reachable from ordinary events. Both forms are needed -- pull_request
  # for review, and the main ref for the post-merge drift check. A list under one condition key
  # is an OR in IAM.
  plan_subjects = [
    "${local.subject_prefix}:pull_request",
    "${local.subject_prefix}:ref:refs/heads/main",
  ]
}

data "aws_iam_policy_document" "plan_trust" {
  for_each = local.ci_environments

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

# APPLY IS PINNED TO ONE WORKFLOW FILE, by the `job_workflow_ref` claim, and to the main ref.
#
#   - a second workflow added to the repository cannot assume the apply role, even on main;
#   - a pull request cannot, because the subject must also be the main ref;
#   - apply still requires a deliberate dispatch -- there is no automatic path.
#
# A GitHub Environment with required reviewers is the stronger gate where the plan allows it
# (free on public repositories); it changes `sub` to `...:environment:<name>`, so the trust
# policy must change with it. Confirm the real claim values from a token before the first apply.
data "aws_iam_policy_document" "apply_trust" {
  for_each = local.ci_environments

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only from main, never from a pull request.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.subject_prefix}:ref:refs/heads/main"]
    }

    # Only from THIS workflow file.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = [coalesce(var.apply_job_workflow_ref, "-")] # null is refused by inputs_are_consistent
    }
  }
}

resource "aws_iam_role" "plan" {
  for_each = local.ci_environments

  name                 = "${var.name_prefix}-tofu-plan-${each.key}"
  description          = "OpenTofu plan for the ${each.key} PDS. Read-only; no state write."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role" "apply" {
  for_each = local.ci_environments

  name                 = "${var.name_prefix}-tofu-apply-${each.key}"
  description          = "OpenTofu apply for the ${each.key} PDS. Assumable only via the ${each.key} GitHub Environment."
  assume_role_policy   = data.aws_iam_policy_document.apply_trust[each.key].json
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------------------------
# Plan permissions: describe everything in scope, read this environment's state, write nothing.
# Plan runs with -lock=false precisely because it has no PutObject.
# ---------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_permissions" {
  for_each = local.ci_environments

  statement {
    sid    = "ReadOwnStateOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${local.state_bucket_arn}/${var.state_key_prefix}${each.value.tofu_state_key}"]
  }

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  # backup_metrics: read the backup-alarm topic and alarm modules/pds manages.
  dynamic "statement" {
    for_each = var.backup_metrics ? [1] : []
    content {
      sid    = "ReadBackupAlarm"
      effect = "Allow"
      actions = [
        "sns:GetTopicAttributes",
        "sns:ListTagsForResource",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListTagsForResource",
      ]
      resources = [
        "arn:aws:sns:${var.aws_region}:${local.account_id}:${var.name_prefix}-pds-*",
        "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${var.name_prefix}-pds-*",
      ]
    }
  }

  statement {
    sid    = "DescribeInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "route53:Get*",
      "route53:List*",
      "iam:GetRole",
      "iam:GetInstanceProfile",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy",
      "ssm:DescribeParameters",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }


  # Belt and braces on the line above: the plan role must never read the contact address.
  statement {
    sid       = "DenyContactParameters"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${var.name_prefix}/*"]
  }

  # The plan role must never reach the identity backup, in any environment.
  statement {
    sid       = "DenyBackupBucket"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
  }
}

# ---------------------------------------------------------------------------------------------
# Apply permissions: create and update in scope, with an explicit Deny on irreversible deletes.
# ---------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_permissions" {
  for_each = local.ci_environments

  statement {
    sid    = "ReadWriteOwnStateOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject", # the backend's own lockfile; state objects are versioned
    ]
    resources = ["${local.state_bucket_arn}/${var.state_key_prefix}${each.value.tofu_state_key}*"]
  }

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  # backup_metrics: manage the backup-alarm topic and alarm, and only those (by name).
  dynamic "statement" {
    for_each = var.backup_metrics ? [1] : []
    content {
      sid    = "ManageBackupAlarm"
      effect = "Allow"
      actions = [
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes",
        "sns:ListTagsForResource",
        "sns:TagResource",
        "sns:UntagResource",
        "cloudwatch:PutMetricAlarm",
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListTagsForResource",
        "cloudwatch:TagResource",
        "cloudwatch:UntagResource",
      ]
      resources = [
        "arn:aws:sns:${var.aws_region}:${local.account_id}:${var.name_prefix}-pds-*",
        "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${var.name_prefix}-pds-*",
      ]
    }
  }

  statement {
    sid    = "ManageCompute"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:ModifyVolume",
      "ec2:CreateSnapshot",
      "ec2:AllocateAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:ReleaseAddress",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
    ]
    resources = ["*"]
  }


  # The apply role provisions the host that reads the contact at boot. It does not need to read
  # the contact itself, and must not: the address would land in plan output and state.
  statement {
    sid       = "DenyContactParameters"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${var.name_prefix}/*"]
  }

  statement {
    sid    = "ManageDnsInTheDelegatedZoneOnly"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ListHostedZones",
    ]
    resources = [data.aws_route53_zone.pds.arn, "arn:aws:route53:::change/*"]
  }

  statement {
    sid    = "InstanceProfileForTheHost"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:PassRole",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      aws_iam_role.host[each.key].arn,
      aws_iam_instance_profile.host[each.key].arn,
    ]
  }

  # These are the operations that lose data irrecoverably. The explicit Deny holds even if the
  # workflow, the prevent_destroy lifecycle blocks and the structural check are all wrong at once.
  statement {
    sid    = "DenyIrreversibleDeletes"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "route53:DeleteHostedZone",
      "ec2:DeleteVolume",
      "iam:DeleteRole",
      "iam:DeleteOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  # The CI role never reaches the identity archive. The PLC rotation key is the one asset that
  # cannot be regenerated, and no unattended process has a reason to read it.
  statement {
    sid       = "DenyBackupBucket"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  for_each = local.ci_environments

  name   = "${var.name_prefix}-tofu-plan-${each.key}"
  role   = aws_iam_role.plan[each.key].id
  policy = data.aws_iam_policy_document.plan_permissions[each.key].json
}

resource "aws_iam_role_policy" "apply" {
  for_each = local.ci_environments

  name   = "${var.name_prefix}-tofu-apply-${each.key}"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply_permissions[each.key].json
}

# ---------------------------------------------------------------------------------------------
# The host's own role. The instance reads its ACME contact from SSM at boot and writes its
# encrypted identity archive to the backup bucket. Neither value passes through OpenTofu : the address is delivered by parameter NAME, and the archive is written by the
# host, so no credential and no contact address is ever an OpenTofu input, output or state value.
# ---------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "host_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  for_each = var.environments

  name               = "${var.name_prefix}-pds-host-${each.key}"
  description        = "The ${each.key} PDS instance. Reads its ACME contact from SSM; writes its identity archive."
  assume_role_policy = data.aws_iam_policy_document.host_trust.json
}

data "aws_iam_policy_document" "host_permissions" {
  for_each = var.environments

  # By name, and only this environment's name.
  statement {
    sid       = "ReadOwnContactParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${each.value.contact_ssm_parameter}"]
  }

  statement {
    sid       = "DecryptOwnParameter"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  # bootstrap_account: the host stores its first account's passwords under /<prefix>/<env>/ --
  # these two names only, so it still cannot touch any other parameter.
  dynamic "statement" {
    for_each = var.bootstrap_account ? [each.key] : []
    content {
      sid     = "WriteOwnAccountPasswords"
      effect  = "Allow"
      actions = ["ssm:PutParameter", "ssm:GetParameter"]
      resources = [
        "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${var.name_prefix}/${statement.value}/account-password",
        "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${var.name_prefix}/${statement.value}/cli-app-password",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.bootstrap_account ? [each.key] : []
    content {
      sid       = "EncryptOwnAccountPasswords"
      effect    = "Allow"
      actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  # backup_metrics: the scheduled backup reports success as a PDS/Backup metric. Namespace-bound.
  dynamic "statement" {
    for_each = var.backup_metrics ? [1] : []
    content {
      sid       = "PublishBackupMetric"
      effect    = "Allow"
      actions   = ["cloudwatch:PutMetricData"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "cloudwatch:namespace"
        values   = ["PDS/Backup"]
      }
    }
  }

  # Write-and-read its own identity archive. No delete: a host that is compromised must not be
  # able to remove the backup that recovers from it.
  statement {
    sid    = "WriteOwnIdentityArchive"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/${each.key}/*",
    ]
  }

  statement {
    sid       = "NeverDeleteABackup"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
  }
}

resource "aws_iam_role_policy" "host" {
  for_each = var.environments

  name   = "${var.name_prefix}-pds-host-${each.key}"
  role   = aws_iam_role.host[each.key].id
  policy = data.aws_iam_policy_document.host_permissions[each.key].json
}

# SSM Session Manager: a shell on the host with NO inbound port and no key to manage.
#
# Added after debugging this host blind. SSH is deliberately closed on a machine holding a
# PLC rotation key, which was the right call -- but it left no inspection path at all, so every
# hypothesis about why the PDS was not serving cost a full instance replacement and ten minutes,
# and "Caddy will not start without an ask endpoint" is a one-line answer from `docker logs`.
#
# Session Manager is the correct shape for this: nothing listens, access is IAM-controlled and
# auditable in CloudTrail, and there is no key to lose. The agent ships with Amazon Linux 2023.
# This is an operability fix, not a convenience -- a host that cannot be inspected cannot be
# operated, and this one has to be maintained for as long as the identity on it lives.
resource "aws_iam_role_policy_attachment" "host_ssm" {
  for_each = var.environments

  role       = aws_iam_role.host[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  for_each = var.environments

  name = "${var.name_prefix}-pds-host-${each.key}"
  role = aws_iam_role.host[each.key].name
}
