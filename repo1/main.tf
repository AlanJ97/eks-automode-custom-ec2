terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.87.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann"
    key    = "vpc/terraform-vpc.tfstate"
    region = var.region
  }
}

# --------- EKS Cluster Role ----------
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = ["eks.amazonaws.com", "ec2.amazonaws.com"] },
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

locals {
  cluster_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    # Additional broad permissions for testing
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}

resource "aws_iam_role_policy_attachment" "cluster_attach" {
  for_each   = toset(local.cluster_policies)
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.value
}

# Inline policy extra: habilita al plano de control (asumiendo este rol) a lanzar/terminar instancias para Auto Mode
resource "aws_iam_role_policy" "eks_cluster_autoscale_extra" {
  name = "${var.cluster_name}-autoscale-extra"
  role = aws_iam_role.eks_cluster.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:GetInstanceTypesFromInstanceRequirements"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = "*"
      }
    ]
  })
}

# --------- EKS Cluster (Auto Mode enabled) ----------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = data.terraform_remote_state.vpc.outputs.private_subnet_ids
    security_group_ids      = [data.terraform_remote_state.vpc.outputs.cluster_sg_id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  bootstrap_self_managed_addons = false

  compute_config {
    enabled    = true
    node_pools = var.eks_node_pools
    node_role_arn = aws_iam_role.eks_cluster.arn  # Use cluster role for node role
  }

  kubernetes_network_config {
    elastic_load_balancing { enabled = true }
  }

  storage_config {
    block_storage { enabled = true }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_attach,
    aws_iam_role_policy.eks_cluster_autoscale_extra
  ]
}
