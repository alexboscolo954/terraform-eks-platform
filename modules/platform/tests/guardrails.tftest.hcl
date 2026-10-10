# Inputs the platform must refuse before anything reaches AWS.
mock_provider "aws" { source = "./tests/mocks" }

variables {
  name        = "demo"
  environment = "dev"
}

run "defaults_are_accepted" {
  command = plan
}

run "public_endpoint_needs_cidrs" {
  command = plan
  variables { endpoint_public_access = true }
  expect_failures = [var.public_access_cidrs]
}

run "public_endpoint_never_open_to_the_internet" {
  command = plan
  variables {
    endpoint_public_access = true
    public_access_cidrs    = ["0.0.0.0/0"]
  }
  expect_failures = [var.public_access_cidrs]
}

run "public_endpoint_with_office_cidr_is_fine" {
  command = plan
  variables {
    endpoint_public_access = true
    public_access_cidrs    = ["203.0.113.0/24"]
  }
}

run "single_az_is_rejected" {
  command = plan
  variables { az_count = 1 }
  expect_failures = [var.az_count]
}

run "unknown_environment_is_rejected" {
  command = plan
  variables { environment = "staging" }
  expect_failures = [var.environment]
}

run "tiny_vpc_is_rejected" {
  command = plan
  variables { vpc_cidr = "10.0.0.0/24" }
  expect_failures = [var.vpc_cidr]
}

run "patch_version_is_rejected" {
  command = plan
  variables { kubernetes_version = "1.37.2" }
  expect_failures = [var.kubernetes_version]
}

run "extended_support_version_is_rejected" {
  command = plan
  variables { kubernetes_version = "1.31" }
  expect_failures = [var.kubernetes_version]
}

run "admin_must_be_a_role_arn" {
  command = plan
  variables { admin_role_arns = ["arn:aws:iam::123456789012:user/alice"] }
  expect_failures = [var.admin_role_arns]
}

run "bad_name_is_rejected" {
  command = plan
  variables { name = "Demo_Cluster" }
  expect_failures = [var.name]
}
