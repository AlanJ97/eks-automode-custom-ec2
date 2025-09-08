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

variable "create_node_access_entry" {
  description = "Whether to create the access entry for the node IAM role. Set false if an entry already exists."
  type        = bool
  default     = false
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

# --------- EKS Node Role (Separate from Cluster Role) ----------
resource "aws_iam_role" "eks_node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = ["ec2.amazonaws.com"] },
      Action    = ["sts:AssumeRole"]
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
    # EBS CSI Driver Policy (Critical for Auto Mode - from GitHub issue #7917)
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]
  
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy", 
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]
}

resource "aws_iam_role_policy_attachment" "cluster_attach" {
  for_each   = toset(local.cluster_policies)
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "node_attach" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# Inline policy extra: permisos específicos para EKS Auto Mode (sin EC2FullAccess)
resource "aws_iam_role_policy" "eks_cluster_autoscale_extra" {
  name = "${var.cluster_name}-autoscale-extra"
  role = aws_iam_role.eks_cluster.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          # EC2 Instance Management
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          # EC2 Describe Operations
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeInstanceStatus",
          # Launch Template Management
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateLaunchTemplateVersion",
          "ec2:DeleteLaunchTemplate",
          "ec2:ModifyLaunchTemplate",
          # Network Resources
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeAvailabilityZones",
          # AMI Management
          "ec2:DescribeImages",
          "ec2:DescribeSnapshots",
          # Instance Requirements
          "ec2:GetInstanceTypesFromInstanceRequirements",
          # Volume Management
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus",
          "ec2:CreateVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DeleteVolume",
          # Key Pairs
          "ec2:DescribeKeyPairs"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = "*",
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "ec2.amazonaws.com",
              "eks.amazonaws.com"
            ]
          }
        }
      },
      {
        Effect = "Allow",
        Action = [
          # Auto Scaling permissions if needed
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities"
        ],
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
    node_role_arn = aws_iam_role.eks_node.arn  # Use dedicated node role
  }

  kubernetes_network_config {
    elastic_load_balancing { enabled = true }
  }

  storage_config {
    block_storage { enabled = true }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_attach,
    aws_iam_role_policy_attachment.node_attach,
    aws_iam_role_policy.eks_cluster_autoscale_extra
  ]
}

# --------- EKS Add-ons (Critical for EKS Auto Mode - from GitHub issue #7917) ----------
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.37.0-eksbuild.1"
  resolve_conflicts_on_create = "OVERWRITE"
  
  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"  
  addon_version               = "v1.3.4-eksbuild.1"
  resolve_conflicts_on_create = "OVERWRITE"
  
  depends_on = [aws_eks_cluster.this]
}

# --------- Network rule: allow API (443) from cluster SG to itself ----------
# Auto Mode nodes attach the cluster SG; allow them to reach the private API endpoint.
// SG self-ingress rule moved to VPC repo to keep networking concerns localized.

# --------- EKS Access Entry for Node Role (required for node registration) ----------
# Grants the node IAM role permissions to authenticate to the API server.
resource "aws_eks_access_entry" "nodes" {
  count         = var.create_node_access_entry ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.eks_node.arn

  # For Auto Mode custom NodeClasses, type should be EC2. If you are
  # creating entries for self-managed nodes instead, use EC2_LINUX.
  type = "EC2"

  depends_on = [aws_eks_cluster.this]
}

# Associate the AmazonEKSAutoNodePolicy to the node role at the cluster scope
resource "aws_eks_access_policy_association" "nodes_auto_mode" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.eks_node.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"

  access_scope {
    type = "cluster"
  }

  # No hard dependency; attaches to existing access entry if already present
}
