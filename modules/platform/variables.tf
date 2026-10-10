variable "name" {
  description = "Cluster name, also used to name the VPC and supporting resources."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 chars of lowercase letters, digits and dashes."
  }
}

variable "environment" {
  description = "dev or prod. Selects the sizing, availability and retention profile."
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, in standard support (extended support costs extra per cluster-hour)."
  type        = string
  default     = "1.37"
  validation {
    # Standard support per the EKS version calendar (checked 2026-10-10):
    # 1.34 until 2026-12-02, 1.35 until 2027-03-27, 1.36 until 2027-08-02,
    # 1.37 until 2027-12-01. Update this list as versions age out.
    condition     = contains(["1.34", "1.35", "1.36", "1.37"], var.kubernetes_version)
    error_message = "kubernetes_version must be in EKS standard support: 1.34, 1.35, 1.36 or 1.37."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR. /16 to /20; subnets are carved out automatically."
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition = (
      can(cidrhost(var.vpc_cidr, 0)) &&
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 20
    )
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /20."
  }
}

variable "az_count" {
  description = "Availability zones to spread subnets and nodes over."
  type        = number
  default     = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3: one AZ is not highly available."
  }
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly. Off by default: reach it through the VPC (VPN, bastion, CI runners in the VPC)."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint. Required, and never 0.0.0.0/0, when endpoint_public_access is true."
  type        = list(string)
  default     = []
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "public_access_cidrs must not contain 0.0.0.0/0."
  }
  validation {
    condition     = !var.endpoint_public_access || length(var.public_access_cidrs) > 0
    error_message = "endpoint_public_access needs at least one entry in public_access_cidrs."
  }
}

variable "admin_role_arns" {
  description = "IAM roles granted cluster-admin through EKS access entries (no aws-auth ConfigMap)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.admin_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+", arn))])
    error_message = "admin_role_arns must be IAM role ARNs."
  }
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group (several types improve Spot/On-Demand capacity odds)."
  type        = list(string)
  default     = ["m7i.large", "m6i.large"]
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
