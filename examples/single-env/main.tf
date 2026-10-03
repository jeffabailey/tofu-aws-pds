# A minimal consumer: one environment, applied from a laptop, after modules/pds-bootstrap has
# been applied in its own root (it creates the host instance profile, the backup bucket and,
# if needed, the default VPC this module looks up).
#
# A real consumer pins the module by tag:
#   source = "git::https://github.com/jeffabailey/tofu-aws-pds.git//modules/pds?ref=v1.1.0"
# This example uses a relative path so CI validates it against the code in this commit.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # backend "s3" {
  #   bucket       = "<your-state-bucket>"
  #   key          = "example/pds/prod.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

locals {
  descriptor = jsondecode(file("${path.module}/environments/prod.json"))
}

provider "aws" {
  region = local.descriptor.aws_region

  default_tags {
    tags = {
      Project     = "example"
      Environment = local.descriptor.environment
      ManagedBy   = "opentofu"
    }
  }
}

variable "hosted_zone_id" {
  description = "bootstrap output hosted_zone_id"
  type        = string
}

variable "instance_profile_name" {
  description = "bootstrap output host_instance_profile_names[\"prod\"]"
  type        = string
}

variable "backup_bucket" {
  description = "bootstrap output backup_bucket"
  type        = string
}

module "pds" {
  source = "../../modules/pds"

  name_prefix = "example"
  project     = "example"

  descriptor            = local.descriptor
  hosted_zone_id        = var.hosted_zone_id
  instance_profile_name = var.instance_profile_name
  backup_bucket         = var.backup_bucket
}

output "pds_url" { value = module.pds.pds_url }
output "public_ip" { value = module.pds.public_ip }
output "data_volume_id" { value = module.pds.data_volume_id }
