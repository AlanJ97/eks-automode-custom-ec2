terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.87.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann"
    key    = "repo1/terraform-ekscluster.tfstate"
    region = var.region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubectl" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}

# Note: No custom IAM role needed - EKS Auto Mode provides default node permissions

# --------- NodeClass ----------
resource "kubectl_manifest" "nodeclass" {
  yaml_body = <<-YAML
    apiVersion: eks.amazonaws.com/v1
    kind: NodeClass
    metadata:
      name: ${var.node_class_name}
    spec:
      role: ${data.terraform_remote_state.eks.outputs.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            "kubernetes.io/cluster/${data.terraform_remote_state.eks.outputs.cluster_name}": "shared"
            "kubernetes.io/role/internal-elb": "1"
      securityGroupSelectorTerms:
        - id: ${data.terraform_remote_state.eks.outputs.cluster_sg_id}
      amiFamily: Bottlerocket
  YAML
}

# --------- NodePool ----------
resource "kubectl_manifest" "nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: ${var.node_pool_name}
    spec:
      template:
        metadata:
          labels:
            workload-type: web
        spec:
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: ${var.node_class_name}
          requirements:
            - key: "node.kubernetes.io/instance-type"
              operator: In
              values: ["c7i.xlarge"]
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter : 60s
      limits:
        cpu: 24
        memory: 48Gi
  YAML
  depends_on = [kubectl_manifest.nodeclass]
}
