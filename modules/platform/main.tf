# Opinionated EKS platform on top of the community modules
# (terraform-aws-modules/vpc and /eks). This module owns the decisions:
# secure defaults, guardrails on inputs, and dev/prod profiles. The community
# modules own the resource wiring.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  profiles = {
    dev = {
      single_nat_gateway  = true # one NAT for the VPC: cheaper, AZ outage = no egress
      log_retention_days  = 30
      log_types           = ["api", "audit", "authenticator"]
      deletion_protection = false
      nodes               = { min = 1, max = 3, desired = 2 }
    }
    prod = {
      single_nat_gateway  = false # one NAT per AZ: egress survives an AZ outage
      log_retention_days  = 365
      log_types           = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
      deletion_protection = true
      nodes               = { min = 3, max = 10, desired = 3 }
    }
  }
  profile = local.profiles[var.environment]

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  # /16 example: private 10.0.0.0/19 x3 (nodes + pods), public 10.0.96.0/22 x3 (load balancers)
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 6, 24 + i)]

  tags = merge(var.tags, {
    environment = var.environment
    cluster     = var.name
    managed-by  = "terraform"
  })
}

################################################################################
# Network
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = local.profile.single_nat_gateway
  one_nat_gateway_per_az = !local.profile.single_nat_gateway
  enable_dns_hostnames   = true

  # VPC flow logs, encrypted, same retention as the control plane logs.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = local.profile.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.logs.arn

  # Subnet discovery for the AWS Load Balancer Controller.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}

################################################################################
# Log encryption: control plane and flow logs share one CMK
################################################################################

data "aws_iam_policy_document" "logs_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${var.name} CloudWatch log encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_key.json
  tags                    = local.tags
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name                = var.name
  kubernetes_version  = var.kubernetes_version
  deletion_protection = local.profile.deletion_protection

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # nodes never get public IPs

  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access ? var.public_access_cidrs : []

  # Access entries only: no aws-auth ConfigMap, and the identity running
  # Terraform does not silently become cluster-admin.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    for i, arn in var.admin_role_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Secrets envelope encryption with a module-managed KMS key (module default),
  # control plane logs encrypted with the logs CMK.
  enabled_log_types                      = local.profile.log_types
  cloudwatch_log_group_retention_in_days = local.profile.log_retention_days
  cloudwatch_log_group_kms_key_id        = aws_kms_key.logs.arn

  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    coredns                = {}
    kube-proxy             = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = local.profile.nodes.min
      max_size       = local.profile.nodes.max
      desired_size   = local.profile.nodes.desired
      # IMDSv2 only, hop limit 1: pods can't reach the node's instance role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  tags = local.tags
}

# IAM for the EBS CSI driver via EKS Pod Identity (no IRSA/OIDC trust policies).
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                      = "${var.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
  tags                      = local.tags
}
