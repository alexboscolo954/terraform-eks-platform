# dev vs prod, asserted on what the community modules actually build
# (mocked apply: no AWS account involved).
mock_provider "aws" { source = "./tests/mocks" }

run "dev_profile" {
  command = apply
  variables {
    name        = "demo"
    environment = "dev"
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "dev should share one NAT gateway"
  }
  assert {
    condition     = module.vpc.private_subnets_cidr_blocks == tolist(["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"])
    error_message = "private subnets: ${jsonencode(module.vpc.private_subnets_cidr_blocks)}"
  }
  assert {
    condition     = module.vpc.public_subnets_cidr_blocks == tolist(["10.0.96.0/22", "10.0.100.0/22", "10.0.104.0/22"])
    error_message = "public subnets: ${jsonencode(module.vpc.public_subnets_cidr_blocks)}"
  }
  assert {
    condition     = module.eks.cluster_version == "1.37"
    error_message = "cluster version"
  }
  assert {
    condition     = length(module.eks.access_entries) == 0
    error_message = "no implicit admin: the Terraform identity must not get an access entry"
  }
  assert {
    condition     = aws_kms_key.logs.enable_key_rotation
    error_message = "log CMK must rotate"
  }
  assert {
    condition     = output.posture.log_retention_days == 30 && !output.posture.deletion_protection
    error_message = "dev retention / deletion protection"
  }
}

run "prod_profile" {
  command = apply
  variables {
    name            = "demo"
    environment     = "prod"
    admin_role_arns = ["arn:aws:iam::123456789012:role/platform-admins", "arn:aws:iam::123456789012:role/break-glass"]
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 3
    error_message = "prod needs one NAT gateway per AZ"
  }
  assert {
    condition     = length(module.eks.access_entries) == 2
    error_message = "one access entry per admin role"
  }
  assert {
    condition = alltrue([
      for k, v in module.eks.access_policy_associations :
      v.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    ])
    error_message = "admins get the cluster admin access policy"
  }
  assert {
    condition     = length(output.posture.log_types) == 5 && output.posture.log_retention_days == 365
    error_message = "prod logs every control plane component for a year"
  }
}

run "two_az_dev" {
  command = apply
  variables {
    name        = "demo"
    environment = "dev"
    az_count    = 2
    vpc_cidr    = "10.20.0.0/18"
  }

  assert {
    condition     = module.vpc.private_subnets_cidr_blocks == tolist(["10.20.0.0/21", "10.20.8.0/21"])
    error_message = "subnets scale with the VPC: ${jsonencode(module.vpc.private_subnets_cidr_blocks)}"
  }
  assert {
    condition     = length(module.vpc.azs) == 2
    error_message = "two AZs"
  }
}
