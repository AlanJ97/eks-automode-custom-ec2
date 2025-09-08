variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "eks_version" {
  description = "Version of the EKS cluster"
  type        = string
  default     = "1.33"
}

variable "eks_node_pools" {
  description = "List of node pools for the EKS cluster"
  type        = list(string)
  default     = ["system", "general-purpose"]
}

