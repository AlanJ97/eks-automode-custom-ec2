# EKS Auto Mode con NodePools Personalizados - Guía Técnica

## 📋 Resumen Ejecutivo

Este proyecto demuestra la implementación de **Amazon EKS Auto Mode** con NodePools personalizados utilizando Terraform. La solución está diseñada para provisionar únicamente instancias **c7i.xlarge** de manera automática, siguiendo las mejores prácticas de seguridad y gestión de infraestructura como código.

## 🏗️ Arquitectura de la Solución

### Componentes Principales

1. **repo1**: Cluster EKS con Auto Mode habilitado
2. **repo2**: NodeClass y NodePool personalizados para instancias c7i.xlarge

### Flujo de Arquitectura

```
┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐
│    repo1    │───▶│   EKS Cluster   │───▶│   Auto Mode     │
│             │    │   (v1.33)       │    │   Enabled       │
└─────────────┘    └─────────────────┘    └──────────────────┘
                            │
                            ▼
┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐
│    repo2    │───▶│   NodeClass     │───▶│   c7i.xlarge     │
│             │    │   + NodePool    │    │   Instances      │
└─────────────┘    └─────────────────┘    └──────────────────┘
```

## 🚀 repo1: Configuración del Cluster EKS

### Propósito
Crear y configurar un cluster de Amazon EKS con Auto Mode habilitado, incluyendo todas las políticas IAM necesarias para la gestión automática de nodos.

### Componentes Técnicos

#### 1. Rol IAM del Cluster
```hcl
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"
  # Permite a EKS y EC2 asumir este rol
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = ["eks.amazonaws.com", "ec2.amazonaws.com"] },
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}
```

**¿Por qué ambos servicios?**
- `eks.amazonaws.com`: Para operaciones del plano de control de EKS
- `ec2.amazonaws.com`: Para que las instancias EC2 (nodos) puedan asumir este rol

#### 2. Políticas IAM Completas
```hcl
locals {
  cluster_policies = [
    # Políticas básicas de EKS Auto Mode
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    
    # Políticas adicionales para gestión completa
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}
```

**Explicación de Políticas:**
- **AmazonEKSComputePolicy**: Gestión automática de nodos
- **AmazonEKSBlockStoragePolicy**: Provisión de volúmenes EBS
- **AmazonEKSLoadBalancingPolicy**: Gestión de Load Balancers
- **AmazonEKSNetworkingPolicy**: Configuración de red CNI
- **AmazonEC2FullAccess**: Permisos completos para gestión de instancias

#### 3. Configuración de Auto Mode
```hcl
compute_config {
  enabled    = true
  node_pools = var.eks_node_pools
  node_role_arn = aws_iam_role.eks_cluster.arn  # Usa el mismo rol para simplicidad
}
```

**Decisión Técnica Clave:**
- **Un solo rol**: Simplifica la gestión de permisos
- **Auto Mode**: EKS gestiona automáticamente Karpenter y otras herramientas
- **node_role_arn requerido**: Obligatorio cuando se especifican NodePools personalizados

### Mejores Prácticas Implementadas

1. **Gestión de Estado Remoto**: Backend S3 con versionado
2. **Separación de Responsabilidades**: VPC, Cluster y NodePools en repositorios separados
3. **Autenticación API**: Modo `API` para mejor control de acceso
4. **Configuración de Red**: Endpoints público y privado habilitados

## 🎯 repo2: NodeClass y NodePool Personalizados

### Propósito
Crear NodeClass y NodePool específicos para provisionar únicamente instancias c7i.xlarge, garantizando control granular sobre el tipo de infraestructura.

### Componentes Técnicos

#### 1. NodeClass - Especificación del Nodo
```yaml
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: c7i-xlarge-class
spec:
  role: eks-auto-mode-demo-cluster-role  # Referencia al rol del cluster
  subnetSelectorTerms:
    - tags:
        "kubernetes.io/cluster/eks-auto-mode-demo": "shared"
        "kubernetes.io/role/internal-elb": "1"
  securityGroupSelectorTerms:
    - id: ${cluster_sg_id}
  amiFamily: Bottlerocket  # AMI optimizada para contenedores
```

**Configuraciones Clave:**
- **role**: Usa el rol del cluster (decisión técnica para simplicidad)
- **subnetSelectorTerms**: Selecciona subnets privadas automáticamente
- **securityGroupSelectorTerms**: Utiliza el security group del cluster
- **amiFamily: Bottlerocket**: Sistema operativo optimizado para contenedores

#### 2. NodePool - Política de Provisión
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: c7i-xlarge-pool
spec:
  template:
    spec:
      requirements:
        - key: "eks.amazonaws.com/instance-category"
          operator: In
          values: ["c"]  # Solo familia compute-optimized
        - key: "eks.amazonaws.com/instance-family"
          operator: In
          values: ["c7i"]  # Solo c7i (última generación)
        - key: "eks.amazonaws.com/instance-size"
          operator: In
          values: ["xlarge"]  # Solo xlarge
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["on-demand"]  # Sin spot instances
```

**Restricciones Implementadas:**
- **Categoría**: Solo `c` (compute-optimized)
- **Familia**: Solo `c7i` (7ª generación Intel)
- **Tamaño**: Solo `xlarge` (4 vCPUs, 8 GB RAM)
- **Tipo**: Solo `on-demand` (mayor disponibilidad)

### Gestión de Acceso y Permisos

#### ¿Por qué No Necesitamos Access Entries Manuales?

1. **Rol Unificado**: El NodeClass usa el mismo rol que el cluster EKS
2. **Permisos Heredados**: EKS ya autoriza este rol para operaciones del cluster
3. **Simplicidad**: Evita complejidad de múltiples roles y access entries

## 📋 Instrucciones de Despliegue

### Prerrequisitos
- Terraform >= 1.6.0
- AWS CLI configurado
- kubectl instalado
- Permisos IAM para crear recursos EKS

### Pasos de Implementación

#### 1. Desplegar el Cluster (repo1)
```bash
cd repo1
terraform init
terraform plan --var-file dev-vars.tfvars -out=tfplan
terraform apply "tfplan"
```

#### 2. Configurar kubectl
```bash
aws eks update-kubeconfig --region us-west-1 --name eks-auto-mode-demo
```

#### 3. Desplegar NodeClass/NodePool (repo2)
```bash
cd repo2
terraform init
terraform plan --var-file dev-vars.tfvars
terraform apply --var-file dev-vars.tfvars -auto-approve
```

#### 4. Verificar Estado
```bash
kubectl get nodeclass,nodepool
kubectl get nodes
```

### Prueba de Funcionamiento

#### Aplicación de Prueba
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-c7i-test
spec:
  replicas: 2
  template:
    spec:
      nodeSelector:
        app-tier: web  # Activa el NodePool personalizado
      containers:
      - name: nginx
        image: nginx:latest
```

#### Comandos de Verificación
```bash
# Aplicar la aplicación de prueba
kubectl apply -f test-demo.yaml

# Monitorear provisión de nodos
kubectl get nodes -w

# Verificar tipo de instancia
kubectl get nodes -o wide
```

## 🔧 Configuración de Variables

### Variables Requeridas
```hcl
# dev-vars.tfvars (repo1)
cluster_name = "eks-auto-mode-demo"
region = "us-west-1"
eks_version = "1.33"
eks_node_pools = ["system", "general-purpose"]

# dev-vars.tfvars (repo2)
region = "us-west-1"
node_class_name = "c7i-xlarge-class"
node_pool_name = "c7i-xlarge-pool"
```

## 🛡️ Consideraciones de Seguridad

### IAM y Permisos
1. **Principio de Menor Privilegio**: Aunque usamos políticas amplias para testing, en producción se deben restringir
2. **Rol Unificado**: Simplifica gestión pero concentra permisos
3. **Autenticación API**: Modo más seguro que ConfigMap

### Red y Conectividad
1. **Subnets Privadas**: Nodos desplegados en subnets privadas únicamente
2. **Security Groups**: Utilizan el SG del cluster con reglas restrictivas
3. **Endpoints**: Acceso público al API pero nodos en red privada

## 📊 Monitoreo y Troubleshooting

### Comandos Útiles de Diagnóstico
```bash
# Estado de NodeClass y NodePool
kubectl describe nodeclass c7i-xlarge-class
kubectl describe nodepool c7i-xlarge-pool

# Eventos del cluster
kubectl get events --sort-by=.metadata.creationTimestamp

# Estado de NodeClaims (nodos siendo provisionados)
kubectl get nodeclaim

# Logs de pods problemáticos
kubectl describe pod <pod-name>
```

### Problemas Comunes y Soluciones

#### 1. NodeClass no Ready
- **Síntoma**: `InstanceProfileReady: False`
- **Causa**: Problemas de permisos IAM
- **Solución**: Verificar políticas del rol y access entries

#### 2. Pods en estado Pending
- **Síntoma**: Pods no programados
- **Causa**: No hay nodos disponibles o restricciones no cumplidas
- **Solución**: Verificar nodeSelector y requirements del NodePool

#### 3. Instancias incorrectas
- **Síntoma**: Se crean instancias que no son c7i.xlarge
- **Causa**: Requirements mal configurados
- **Solución**: Revisar y ajustar especificaciones del NodePool

## 🎯 Beneficios de Esta Implementación

### Técnicos
1. **Control Granular**: Solo instancias c7i.xlarge
2. **Auto-scaling**: Provisión automática basada en demanda
3. **Optimización de Costos**: Nodos se crean y destruyen según necesidad
4. **Gestión Simplificada**: EKS Auto Mode reduce complejidad operacional

### Operacionales
1. **IaC Completo**: Toda la infraestructura como código
2. **Separación de Responsabilidades**: Repos independientes
3. **Reproducibilidad**: Despliegues consistentes
4. **Versionado**: Control de cambios en infraestructura

## 🔄 Limpieza de Recursos

### Orden de Destrucción
```bash
# 1. Eliminar aplicaciones
kubectl delete -f test-demo.yaml

# 2. Destruir NodeClass/NodePool (repo2)
cd repo2
terraform destroy --var-file dev-vars.tfvars

# 3. Destruir cluster (repo1)
cd repo1
terraform destroy --var-file dev-vars.tfvars
```

## 📚 Referencias Técnicas

- [Amazon EKS Auto Mode Documentation](https://docs.aws.amazon.com/eks/latest/userguide/auto-mode.html)
- [Karpenter NodePool Configuration](https://karpenter.sh/docs/concepts/nodepools/)
- [EKS Access Entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
- [Bottlerocket OS](https://aws.amazon.com/bottlerocket/)

---

## 💡 Notas del Desarrollador

Esta implementación representa un enfoque práctico para EKS Auto Mode, priorizando la simplicidad y funcionalidad. En entornos de producción, considere:

1. **Segregación de roles IAM** más granular
2. **Múltiples NodePools** para diferentes tipos de workloads
3. **Políticas de red** más restrictivas
4. **Monitoring y alerting** avanzado
5. **Backup y disaster recovery** estrategias

La solución ha sido probada y funciona correctamente, proporcionando una base sólida para implementaciones de EKS Auto Mode en entornos reales.
