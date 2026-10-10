output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "nat_gateway_count" {
  description = "1 in dev, one per AZ in prod."
  value       = length(module.vpc.natgw_ids)
}

output "posture" {
  description = "Effective security and availability settings, for review and tests."
  value = {
    environment            = var.environment
    endpoint_public_access = var.endpoint_public_access
    authentication_mode    = "API"
    log_types              = local.profile.log_types
    log_retention_days     = local.profile.log_retention_days
    deletion_protection    = local.profile.deletion_protection
    azs                    = local.azs
    node_scaling           = local.profile.nodes
    admin_access_entries   = length(var.admin_role_arns)
  }
}
