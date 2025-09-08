# VPC para EKS Auto Mode (c7i.xlarge)

## 1. Objetivo
Proveer la **red base** para un clúster EKS (Auto Mode) usando únicamente instancias `c7i.xlarge`, asegurando: subredes públicas/privadas balanceadas, NAT Gateway único para optimizar costos, etiquetado correcto para balanceadores de Kubernetes y una **regla crítica de puerto 443** que permite que los nodos (a través del Security Group del clúster) se comuniquen con el API Server.

## 2. Componentes Principales
| Componente | Recurso Terraform | Descripción breve |
|------------|-------------------|-------------------|
| VPC | `aws_vpc.main` | Espacio de direcciones principal (`vpc_cidr`). |
| Subredes Públicas | `aws_subnet.public[*]` | Para LoadBalancers públicos (etiqueta `kubernetes.io/role/elb=1`). |
| Subredes Privadas | `aws_subnet.private[*]` | Donde residen los nodos/Pods (etiqueta `kubernetes.io/role/internal-elb=1`). |
| Internet Gateway | `aws_internet_gateway.main` | Salida/entrada de Internet para subredes públicas. |
| NAT Gateway | `aws_nat_gateway.main` + `aws_eip.nat` | Permite tráfico saliente desde subredes privadas. |
| Route Tables | `aws_route_table.public` / `aws_route_table.private` | Rutas 0.0.0.0/0 a IGW (públicas) y NAT (privadas). |
| Security Group del Clúster | `aws_security_group.cluster` | Base para control de tráfico del plano de datos. |
| REGLA CRÍTICA 443 | `aws_security_group_rule.cluster_api_self_ingress` | Autoriza nodos → API Server vía Security Group del clúster. |

## 3. Diseño de Subredes
- CIDR VPC: definido por `var.vpc_cidr` (ej: `10.0.0.0/16`).
- Subredes públicas (ej: `/24`) en AZs: `var.availability_zones`.
- Subredes privadas (ej: `/24`) emparejadas con las públicas para alta disponibilidad.
- Etiquetas obligatorias para que EKS/AWS Load Balancer Controller detecten y programen LoadBalancers:
  - `kubernetes.io/cluster/<cluster_name> = shared`
  - Públicas: `kubernetes.io/role/elb = 1`
  - Privadas: `kubernetes.io/role/internal-elb = 1`

## 4. Flujo de Tráfico
1. Usuarios externos → Load Balancer público (en subred pública) → Servicio → Pods (en subred privada).
2. Pods / nodos en subred privada → Internet (dependencias, imágenes) vía NAT Gateway.
3. API Server (endpoint de EKS) es accedido por nodos usando el Security Group del clúster.

## 5. REGLA CRÍTICA DEL PUERTO 443 (DESTACADA)
Esta regla permite que los nodos (que heredan o están asociados al **Security Group del clúster**) se comuniquen con el **API Server de EKS** sobre HTTPS (puerto 443). Sin esta regla, los nodos pueden quedarse en estado NotReady o no registrar componentes críticos.

Recurso: `aws_security_group_rule.cluster_api_self_ingress`

| Campo | Valor |
|-------|-------|
| Protocolo | TCP |
| Puerto | 443 |
| Origen | Mismo Security Group (`source_security_group_id = aws_security_group.cluster.id`) |
| Motivo | Permitir tráfico interno SG→SG hacia el endpoint del API Server |

⚠ Importante: Se movió esta regla al repositorio de la **VPC** para que exista antes de que el clúster intente registrar nodos, evitando carreras de creación.

## 6. Variables Principales
| Variable | Descripción |
|----------|-------------|
| `region` | Región AWS (ej: `us-west-1`). |
| `cluster_name` | Prefijo de nombres y etiquetas compartidas. |
| `vpc_cidr` | CIDR de la VPC. |
| `public_subnet_cidrs` | Lista CIDRs subredes públicas. |
| `private_subnet_cidrs` | Lista CIDRs subredes privadas. |
| `availability_zones` | AZs a utilizar (orden correlativo con listas de CIDR). |

Archivo de ejemplo (`dev-vars.tfvars`):
```
region               = "us-west-1"
cluster_name         = "eks-auto-mode-demo"
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones   = ["us-west-1a", "us-west-1b"]
```

## 7. Backend de Estado Remoto
El archivo `backend.tf` define un backend S3:
```
bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann"
key    = "vpc/terraform-vpc.tfstate"
region = "us-west-1"
```
Asegura consistencia y bloqueo remoto (si se usa DynamoDB opcionalmente para locking).

## 8. Etiquetado y Buenas Prácticas
- Prefijo consistente con `cluster_name` para facilitar limpieza.
- Una sola NAT Gateway (optimiza costo vs. NAT en cada AZ). Considerar alta disponibilidad según SLA requerido.
- Mantener subredes privadas para nodos; evita exposición directa.
- Etiquetas de subred correctas son requisito para que controladores de AWS creen balanceadores.

## 9. Pasos de Ejecución (Terraform)
Ejecutar siempre desde la carpeta del repositorio de VPC.

Inicialización (descarga proveedores y configura backend):
```powershell
terraform init
```

Validación opcional de sintaxis:
```powershell
terraform validate
```

Plan con variables de entorno (archivo tfvars):
```powershell
terraform plan -var-file="dev-vars.tfvars" -out tfplan
```

Aplicar cambios planificados:
```powershell
terraform apply tfplan
```

Ver salidas:
```powershell
terraform output
```

## 10. Destrucción Segura
1. Asegúrate de que dependencias (clúster EKS, NodePool, etc.) ya fueron destruidas para liberar Elastic IP / NAT / subredes.
2. Ejecuta:
```powershell
terraform destroy -var-file="dev-vars.tfvars" -auto-approve
```
3. Si falla por dependencias (ej: Endpoint EC2 Instance Connect, interfaces ENI residuales), elimínalas manualmente y reintenta.

## 11. Errores Frecuentes y Soluciones
| Problema | Causa Probable | Acción |
|----------|----------------|--------|
| Subred no se elimina | ENI o Endpoint asociado | Eliminar recurso dependiente y reintentar destroy. |
| Nodos NotReady | Falta regla 443 SG→SG | Verificar `aws_security_group_rule.cluster_api_self_ingress`. |
| Balanceador no se crea | Falta etiqueta en subred | Revisar etiquetas `kubernetes.io/role/elb` o `internal-elb`. |
| NAT Gateway caro | Uso en entornos dev | Considerar reemplazar por endpoints privados o apagar entorno. |

## 12. Mantenimiento / Próximos Pasos
- Añadir tabla de costos estimados (EIP + NAT) si el uso crece.
- Evaluar usar múltiples NAT Gateways en producción multi-AZ crítica.
- Integrar `aws_flow_log` para auditoría de tráfico si se requiere seguridad avanzada.

## 13. Resumen Rápido (TL;DR)
1. Crear VPC con subredes públicas/privadas etiquetadas.
2. NAT único para salida desde privadas.
3. Security Group del clúster creado aquí.
4. REGRA CLAVE: **Puerto 443 intra-SG** habilitado (nodos → API Server) = funcionamiento correcto de EKS.
5. Ejecutar: init → plan → apply; destruir solo tras eliminar dependencias aguas arriba.

---
Documentación enfocada únicamente en la capa de **red (VPC)** para el entorno EKS Auto Mode c7i.xlarge.
