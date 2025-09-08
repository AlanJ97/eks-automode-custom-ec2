output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "EKS cluster certificate authority"
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN for the EKS cluster"
  value       = aws_iam_role.eks_cluster.arn
}

output "cluster_iam_role_name" {
  description = "IAM role name for the EKS cluster"
  value       = aws_iam_role.eks_cluster.name
}

output "cluster_sg_id" {
  description = "Security group ID for the EKS cluster"
  value       = data.terraform_remote_state.vpc.outputs.cluster_sg_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the EKS cluster"
  value       = data.terraform_remote_state.vpc.outputs.private_subnet_ids
}
