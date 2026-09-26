# One PDS environment. Every name comes from the environment descriptor (ADR-012 §1); this
# module invents none of them, which is what lets `test` and `prod` be the same code.
#
# The load-bearing decision is the separation of the instance from its volume (ADR-011): the
# instance is cattle and may be replaced at will, the volume holds /pds -- the SQLite repo, the
# PLC rotation key, the account -- and carries prevent_destroy. A did:plc is permanent and
# public; records can be re-imported, an identity cannot be re-minted.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  env       = var.descriptor.environment
  hostname  = var.descriptor.pds_hostname
  namespace = var.descriptor.atproto_namespace
  handle    = var.descriptor.handle

  name = "trb-pds-${local.env}"

  tags = {
    Project     = "the-reality-base"
    Environment = local.env
    ManagedBy   = "opentofu"
    Hostname    = local.hostname
  }

  # ADR-012 §2, checked here as well as in CI. These are arithmetic, so a mismatch is a refusal
  # rather than a discovery six steps later in a published record's $type.
  reversed_namespace = join(".", reverse(split(".", local.namespace)))
}

# A mismatch between the namespace and the hostname is the largest horizontal-integration risk
# in the feature (Gap 3). It is caught at plan time, before any resource exists.
resource "terraform_data" "name_invariants" {
  lifecycle {
    precondition {
      condition     = local.reversed_namespace == local.hostname
      error_message = "reverse(atproto_namespace) must equal pds_hostname. Got '${local.reversed_namespace}' vs '${local.hostname}' in the ${local.env} descriptor."
    }
    precondition {
      condition     = endswith(local.handle, ".${local.hostname}")
      error_message = "handle must be a subdomain of pds_hostname, so it resolves through the PDS's own .well-known endpoint. Got '${local.handle}' against '${local.hostname}'."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# Network. The default VPC, deliberately: a purpose-built VPC here would add a NAT gateway at
# $32/month -- more than the entire cost ceiling -- to solve a problem one public subnet and a
# security group already solve for a single internet-facing host.
# ---------------------------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

# THE SUBNET MUST BE IN AN AZ THAT ACTUALLY OFFERS THE INSTANCE TYPE.
#
# This previously took `sort(subnet_ids)[0]` -- the lowest subnet id, which is deterministic but
# arbitrary. In this account that is us-east-1e, and us-east-1e offers no t4g at all:
#
#   Unsupported: Your requested instance type (t4g.small) is not supported in your requested
#   Availability Zone (us-east-1e).
#
# It plans perfectly and fails at APPLY, after the security group and the data volume already
# exist -- the worst place to find it, because the volume carries prevent_destroy and an EBS
# volume cannot change AZ, so recovery needs the guard lifted in a commit.
#
# Graviton availability is per-AZ and not uniform, so the AZ set is ASKED FOR rather than
# assumed, and the filter is pushed into the EC2 query rather than done locally: one round trip,
# no per-subnet reads, and the usable set is what the API says it is.
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.descriptor.instance_type]
  }
}

# Every default subnet, used only to tell "no subnets at all" from "no subnets in a usable AZ".
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# The subnets that can actually run this instance type.
data "aws_subnets" "usable" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = sort(tolist(data.aws_ec2_instance_type_offerings.supported.locations))
  }
}

# Sorted so the choice is stable across plans. Selecting by lowest subnet id did not even
# guarantee that -- a new default subnet could sort ahead of the current one and silently move
# the environment.
data "aws_subnet" "chosen" {
  id = sort(data.aws_subnets.usable.ids)[0]
}

# Fail at PLAN time, naming the offered AZs, rather than at apply with an EC2 error after half
# the environment exists.
resource "terraform_data" "instance_type_is_available" {
  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.usable.ids) > 0
      error_message = "No default subnet sits in an availability zone offering ${var.descriptor.instance_type}. It is offered in: ${join(", ", sort(tolist(data.aws_ec2_instance_type_offerings.supported.locations)))}. Default subnets exist in this VPC: ${length(data.aws_subnets.default.ids)}."
    }
  }
}

resource "aws_security_group" "pds" {
  name        = local.name
  description = "PDS ${local.env}: public HTTP/HTTPS, SSH only from the operator."
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(local.tags, { Name = local.name })
}

# 80 is not optional: it is how the ACME HTTP-01 challenge is answered.
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.pds.id
  description       = "ACME HTTP-01 challenge and the redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.pds.id
  description       = "The PDS itself, and the firehose"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Absent by default. SSH is for a drill or an incident, opened deliberately to one address, not
# left open to the internet on a host holding an unrecoverable private key.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.ssh_ingress_cidr == null ? 0 : 1

  security_group_id = aws_security_group.pds.id
  description       = "Operator SSH"
  cidr_ipv4         = var.ssh_ingress_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.pds.id
  description       = "Image pulls, ACME, PLC directory, package updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------------------------
# The volume that must outlive everything else.
# ---------------------------------------------------------------------------------------------

resource "aws_ebs_volume" "pds_data" {
  availability_zone = data.aws_subnet.chosen.availability_zone
  size              = var.descriptor.data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, { Name = "${local.name}-data" })

  # ==========================================================================================
  # TEMPORARY -- prevent_destroy LIFTED for one apply. RESTORE IT IMMEDIATELY AFTER.
  #
  # The first apply of this environment failed part way: the subnet was chosen by lowest id,
  # which is us-east-1e, and us-east-1e offers no t4g. The security group and THIS VOLUME were
  # created before the instance failed. The fix moves the environment to an AZ that offers the
  # instance type, and an EBS volume cannot change AZ -- so it must be replaced.
  #
  # `prevent_destroy` blocked that, correctly. It is being lifted deliberately, through a
  # commit, which is the procedure ADR-013 §4 requires, rather than worked around with
  # `state rm` and an out-of-band delete. The difference matters: the guard's whole purpose is
  # to force this decision into a reviewable change, and the next time it fires the volume will
  # hold a `did:plc` that cannot be re-minted.
  #
  # Safe exactly once, and only because of what this specific volume is:
  #   vol-05513365b73690528, 20 GB, us-east-1e, state "available" (never attached),
  #   created 2026-09-26T17:46Z by the failed apply. No PDS has ever run against it, so it
  #   holds no account, no repository and no rotation key.
  #
  # RESTORE `prevent_destroy = true` in the commit immediately after this apply succeeds.
  # ==========================================================================================
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_volume_attachment" "pds_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.pds_data.id
  instance_id = aws_instance.pds.id

  # Detach on instance replacement rather than blocking it. The volume survives; that is the
  # entire point of keeping it in a separate resource.
  stop_instance_before_detaching = true
}

# ---------------------------------------------------------------------------------------------
# The instance. Cattle.
# ---------------------------------------------------------------------------------------------

# VER-1 (resolved 2026-09-25): the pinned PDS digest is an OCI image index carrying both
# linux/amd64 and linux/arm64, so Graviton is available and t4g is the cheapest way to the
# required RAM.
#
# WHY DescribeImages AND NOT THE SSM PUBLIC PARAMETER:
#   The usual recipe is `/aws/service/ami-al2023-latest/al2023-ami-kernel-6.1-arm64`. That
#   namespace does not resolve here -- SSM answers "No access to /aws/ namespace:
#   aws/service/ami-al2023-latest is not a valid namespace", and it says the same to a laptop
#   identity with broad permissions. Other public parameters in the same namespace DO resolve
#   (/aws/service/ami-amazon-linux-latest/... returns an AMI id), so this is not an account
#   restriction and not IAM -- the al2023 path simply is not there to read.
#
#   Reading it as an SSM parameter cost a permission on both CI roles for nothing. DescribeImages
#   needs no new permission at all: `ec2:Describe*` is already granted because plan has to read
#   the instance anyway. Fewer moving parts, one less grant, and it fails loudly if no image
#   matches instead of returning something unexpected.
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_instance" "pds" {
  ami                    = coalesce(var.ami_id, data.aws_ami.al2023_arm64.id)
  instance_type          = var.descriptor.instance_type
  subnet_id              = data.aws_subnet.chosen.id
  vpc_security_group_ids = [aws_security_group.pds.id]
  iam_instance_profile   = var.instance_profile_name
  key_name               = var.ssh_key_name

  # `standard` rather than `unlimited`: an exhausted burst budget throttles the import, which is
  # visible and recoverable. `unlimited` turns the same event into a surprise on the bill, which
  # is neither. RISK-D3.
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # the container reads the instance role
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    hostname              = local.hostname
    handle                = local.handle
    namespace             = local.namespace
    environment           = local.env
    pds_image             = var.pds_image
    contact_ssm_parameter = var.descriptor.contact_ssm_parameter
    backup_bucket         = var.backup_bucket
    aws_region            = var.descriptor.aws_region
  })

  # Replacing the host on every new Amazon Linux release would be a surprise, not a decision.
  # The AMI is upgraded by setting var.ami_id in a commit.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.tags, { Name = local.name })
}

# ---------------------------------------------------------------------------------------------
# Address and DNS.
# ---------------------------------------------------------------------------------------------

resource "aws_eip" "pds" {
  domain   = "vpc"
  instance = aws_instance.pds.id
  tags     = merge(local.tags, { Name = local.name })

  # The address appears in the DID document's service endpoint by way of the hostname. Losing it
  # is not fatal, but re-issuing certificates and waiting on DNS is avoidable pain.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "pds" {
  zone_id = var.hosted_zone_id
  name    = local.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.pds.public_ip]
}

# The handle is a subdomain of the hostname (ADR-012 §2), so it needs to resolve too. A wildcard
# covers the handle and anything else served under Caddy's wildcard site block, with no second
# apply and no DNS TXT record to keep in sync.
resource "aws_route53_record" "wildcard" {
  zone_id = var.hosted_zone_id
  name    = "*.${local.hostname}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.pds.public_ip]
}
