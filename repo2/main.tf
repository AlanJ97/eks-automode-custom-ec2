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
      # Evitar asignación de IPs públicas a los nodos (nueva feature Aug 2025)
      advancedNetworking:
        associatePublicIPAddress: false
      # Definimos el volumen root EBS de 25 GB (gp3). Ajustar si se requiere IOPS/Throughput personalizados.
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 25            # GB
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true
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
      weight: 100  # Prioridad alta para ser preferido sobre otros NodePools
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
        cpu: 24       # 6 nodos * 4 vCPU (c7i.xlarge) = 24 vCPU => MAX 6 nodos
        memory: 48Gi  # 6 nodos * 8 Gi = 48 Gi memoria
      # Nota sobre mínimo de 3 nodos: Karpenter/Auto Mode no tiene "min" directo en el NodePool.
      # Para mantener siempre 3 nodos se recomienda:
      # 1) Desplegar un Deployment con 3 réplicas y requests que fuercen la existencia de 3 nodos.
      # 2) O crear cargas de "reservas" (pods placeholder) distribuidas con anti-affinity.
YAML
  depends_on = [kubectl_manifest.nodeclass]
}

# --------- Configuración de NodePools por Defecto (EKS Auto Mode) ----------
# Restricción del NodePool 'system' para evitar c7i.xlarge y limitar recursos
resource "kubectl_manifest" "system_nodepool_patch" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: system
    spec:
      disruption:
        budgets:
        - nodes: 10%
        consolidateAfter: 30s
        consolidationPolicy: WhenEmptyOrUnderutilized
      limits:
        cpu: 8        # Solo 2 nodos máximo para system (c6g.large = 2vCPU cada uno)
        memory: 16Gi  # 2 nodos * 8Gi = 16Gi
      template:
        metadata: {}
        spec:
          expireAfter: 336h
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: default
          requirements:
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand"]
          - key: eks.amazonaws.com/instance-category
            operator: In
            values: ["c", "m", "r"]
          - key: eks.amazonaws.com/instance-generation
            operator: Gt
            values: ["4"]
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64", "arm64"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
          - key: node.kubernetes.io/instance-type  # EXCLUSIÓN CLAVE
            operator: NotIn
            values: ["c7i.xlarge"]  # NO permitir c7i.xlarge en system
          taints:
          - effect: NoSchedule
            key: CriticalAddonsOnly
          terminationGracePeriod: 24h0m0s
YAML
  depends_on = [kubectl_manifest.nodepool]
}

# Restricción del NodePool 'general-purpose' para evitar c7i.xlarge
resource "kubectl_manifest" "general_purpose_nodepool_patch" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: general-purpose
    spec:
      disruption:
        budgets:
        - nodes: 10%
        consolidateAfter: 30s
        consolidationPolicy: WhenEmptyOrUnderutilized
      limits:
        cpu: 4        # Muy limitado para desalentar su uso
        memory: 8Gi
      template:
        metadata: {}
        spec:
          expireAfter: 336h
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: default
          requirements:
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand"]
          - key: eks.amazonaws.com/instance-category
            operator: In
            values: ["c", "m", "r"]
          - key: eks.amazonaws.com/instance-generation
            operator: Gt
            values: ["4"]
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
          - key: node.kubernetes.io/instance-type  # EXCLUSIÓN CLAVE
            operator: NotIn
            values: ["c7i.xlarge"]  # NO permitir c7i.xlarge en general-purpose
          terminationGracePeriod: 24h0m0s
YAML
  depends_on = [kubectl_manifest.nodepool]
}
