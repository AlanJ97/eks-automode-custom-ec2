# EKS Auto Mode (Cluster) - Documentación

## 1. Objetivo
Definir el **clúster EKS en modo Auto Mode** (versión `1.33`) separando responsabilidades de red (definidas en el repositorio VPC) y de cómputo/gestión (este repositorio). Aquí se habilitan los Node Pools (`system`, `general-purpose`), Add-ons críticos y las políticas IAM mínimas sin usar `EC2FullAccess`.

## 2. Alcance de Este Repositorio
Este repositorio SOLO cubre:
- Creación del clúster `aws_eks_cluster` con `compute_config` (Auto Mode habilitado).
- Roles IAM: uno para el clúster y otro independiente para nodos.
- Políticas administradas y una política inline mínima para operaciones de ciclo de vida de instancias.
- Add-ons: `aws-ebs-csi-driver` y `eks-pod-identity-agent`.
- (Opcional) Creación y/o asociación de Access Entry y Access Policy para el rol de nodos.


## 3. Componentes Clave
| Componente | Recurso | Descripción |
|------------|---------|-------------|
| Cluster Role | `aws_iam_role.eks_cluster` | Rol que EKS usa para gestionar si mismo y recursos asociados. |
| Node Role | `aws_iam_role.eks_node` | Rol asumido por instancias/nodos (Auto Mode). |
| Política Inline | `aws_iam_role_policy.eks_cluster_autoscale_extra` | Permisos mínimos para Run/Terminate/Describe instancias y Launch Templates. |
| EKS Cluster | `aws_eks_cluster.this` | Clúster con `authentication_mode = API` y Auto Mode activado. |
| Add-on EBS CSI | `aws_eks_addon.ebs_csi_driver` | Gestión de volúmenes persistentes (requerido en Auto Mode). |
| Add-on Pod Identity Agent | `aws_eks_addon.pod_identity_agent` | Soporta Pod Identity en lugar de KIAM/IRSA tradicional. |
| Access Entry (opcional) | `aws_eks_access_entry.nodes` | Entrada de autenticación para el rol de nodos. |
| Access Policy Association | `aws_eks_access_policy_association.nodes_auto_mode` | Asocia `AmazonEKSAutoNodePolicy` al rol de nodos. |

## 4. Auto Mode y Node Pools
Se habilita Auto Mode mediante el bloque `compute_config`:
```
compute_config {
  enabled       = true
  node_pools    = ["system", "general-purpose"]
  node_role_arn = aws_iam_role.eks_node.arn
}
```
Los Node Pools lógicos permiten que el plano de control cree nodos con distintos propósitos. La restricción a tipos de instancia (ej: `c7i.xlarge`) se maneja aguas abajo (en manifiestos de NodeClass/NodePool dentro de otro repositorio de cómputo o mediante constraints posteriores).

## 5. REGLA CRÍTICA DEL PUERTO 443 (REFERENCIA)
Aunque no se define aquí, el clúster depende de la **regla de ingreso 443 SG→SG** creada en la VPC para que los nodos (que adjuntan el Security Group del clúster) puedan establecer la conexión TLS con el API Server. Sin ella:
- Los nodos pueden quedar en `NotReady`.
- Los NodeClaims Auto Mode pueden no completar bootstrap.

➡ Ver en el repositorio VPC: recurso `aws_security_group_rule.cluster_api_self_ingress`.

## 6. Access Entry (MUY IMPORTANTE) ✅
El acceso de los nodos al plano de control se maneja con dos recursos:
1. `aws_eks_access_entry` (crea la entrada principal de autenticación).
2. `aws_eks_access_policy_association` (asocia una política de acceso).

### Variable de Control: `create_node_access_entry`
| Valor | Uso Recomendado | Efecto |
|-------|------------------|--------|
| `true` | Primera vez que se crea el clúster y el Access Entry aún NO existe | Terraform crea el Access Entry y luego la asociación de política. |
| `false` | Cuando el Access Entry ya existe (ej: quedó tras un apply previo o fue creado manualmente) | Evita error `ResourceInUseException` (409) por intento de duplicado. Solo se gestiona la asociación de política. |

⚠ Si se interrumpe un `terraform apply` mientras crea el Access Entry, puede quedar creado en AWS pero no en el estado local. En ese caso: poner `create_node_access_entry = false` y re-ejecutar el plan para que sólo gestione la asociación.

### Tipo Correcto
`type = "EC2"` para Auto Mode (no usar `EC2_LINUX` aquí a menos que se trate de self-managed nodes tradicionales).

## 7. IAM Mínimo (Sin EC2FullAccess)
La política inline agrega únicamente acciones necesarias:
- Lanzar/terminar instancias: `ec2:RunInstances`, `ec2:TerminateInstances`.
- Describir tipos / subredes / SG / volúmenes.
- Crear y versionar Launch Templates.
- `iam:PassRole` restringido a servicios `ec2.amazonaws.com` y `eks.amazonaws.com`.
Esto reemplaza la necesidad de `AmazonEC2FullAccess`, reduciendo superficie de permisos.

## 8. Add-ons Críticos
| Add-on | Razón |
|--------|-------|
| aws-ebs-csi-driver | Provisión dinámica de volúmenes (Auto Mode exige soporte almacenamiento). |
| eks-pod-identity-agent | Sustituye uso directo de IRSA en ciertos flujos y habilita Pod Identity. |

Se establece `resolve_conflicts_on_create = "OVERWRITE"` para evitar fallos si existe versión previa.

### 8.1 Manejo del estado `DEGRADED` del Add-on EBS CSI (CASO ESPECIAL) ⚠️
En algunas ejecuciones iniciales el add-on `aws-ebs-csi-driver` puede mostrarse como **DEGRADED** en la consola de AWS EKS mientras Terraform aún "espera". Esto suele ocurrir cuando la creación del clúster terminó bien, pero el add-on tarda más (ciclo interno del controlador) o hubo una interrupción temporal.

Acción recomendada (elige UNA de dos):
1. (Rápida) **Si ya pasaron ~20 minutos** desde que comenzó `terraform apply`, TODO lo demás (roles, cluster, otro add-on) está creado y SOLO sigue el add-on esperando: presiona `Ctrl + C` en la terminal para cancelar la espera de Terraform. El estado del clúster queda usable. Luego continúa con el repositorio de NodeClass/NodePool (repo2) y despliega la app: esto forzará actividad y normalmente el add-on pasará a `ACTIVE` tras algunos minutos.
2. (Lenta) Esperar a que Terraform alcance el timeout natural (~40 minutos) y falle la operación del add-on; después ejecutar de nuevo `terraform apply` (reemplaza/recupera el add-on) o continuar con repo2. El deployment de workloads también suele desencadenar la recuperación.

✅ Ambas rutas permiten continuar: la recuperación del estado `DEGRADED` se resuelve al aplicar de nuevo o al generar tráfico/provisión de volúmenes.

**IMPORTANTE:** No destruyas el clúster solo por ver `DEGRADED` temprano; verifica primero que el resto de recursos ya existe y opta por una de las dos estrategias anteriores.

## 9. Autenticación y `authentication_mode = API`
Se usa `access_config.authentication_mode = "API"`, lo cual:
- Centraliza autorización vía Access Entries (en vez de mapRoles en ConfigMap). 
- Facilita control declarativo (creación, edición y revocación) y auditoría.

## 10. Backend de Estado
`backend.tf` utiliza el mismo bucket S3 que la VPC pero con `key` distinto (`repo1/terraform-ekscluster.tfstate`). Separar estados simplifica destrucciones parciales.

## 11. Variables Principales
```
region         = "us-west-1"
cluster_name   = "eks-auto-mode-demo"
eks_version    = "1.33"
eks_node_pools = ["system", "general-purpose"]
create_node_access_entry = false
```

## 12. Flujo de Despliegue Recomendado
1. Aplicar VPC (asegura regla 443 y subredes).
2. Aplicar este repo con `create_node_access_entry = true` la PRIMERA vez.
3. Si un apply se interrumpe y el Access Entry ya existe: cambiar a `false` y reintentar.
4. Luego aplicar el repo de NodeClass/NodePool (cómputo específico c7i.xlarge).

## 13. Comandos Terraform (PowerShell Windows)
Inicializar:
```powershell
terraform init
```
Validar:
```powershell
terraform validate
```
Plan (usando archivo de variables):
```powershell
terraform plan -var-file="dev-vars.tfvars" -out tfplan
```
Aplicar:
```powershell
terraform apply tfplan
```
Ver outputs:
```powershell
terraform output
```

## 14. Destrucción Segura
Antes de destruir este clúster:
1. Elimina recursos dependientes (NodePools/NodeClass, workloads, volúmenes persistentes). 
2. Ejecuta:
```powershell
terraform destroy -var-file="dev-vars.tfvars" -auto-approve
```
3. Si falla por Add-ons en estado inconsistente: reintenta `apply` para recrear y luego `destroy`.

## 15. Errores Frecuentes
| Error | Causa | Solución |
|-------|-------|----------|
| `ResourceInUseException` al crear Access Entry | Ya existe | Poner `create_node_access_entry=false` y re-plan. |
| Nodos no se registran | Falta regla 443 SG→SG (en VPC) | Confirmar regla y SG usado. |
| Add-on EBS en estado `DEGRADED` | Lenta convergencia o interrupción apply | (a) Cancelar tras 20m con Ctrl+C y seguir con repo2, luego re-apply opcional; o (b) esperar timeout (~40m) y re-apply. |
| Permisos insuficientes al escalar | Falta acción EC2 específica | Revisar política inline `eks_cluster_autoscale_extra`. |

## 16. Mantenimiento / Mejora Futura
- Importar el Access Entry a estado (`terraform import`) si se desea volver a gestionarlo tras crearse fuera del control de Terraform.
- Añadir control de versiones de Add-ons (variable) para upgrades controlados.
- Integrar validaciones con `aws eks describe-cluster` en un pipeline CI.

## 17. TL;DR
1. Este repo crea el clúster EKS Auto Mode con roles IAM mínimos.
2. **Access Entry:** usar `create_node_access_entry=true` solo la primera vez; luego `false` para evitar duplicados.
3. **Puerto 443 intra-SG** (en VPC) es indispensable para registro de nodos.
4. Add-ons: EBS CSI + Pod Identity Agent obligatorios.
5. Comandos: init → plan → apply → output; destroy solo tras apagar cómputo asociado.

---
Documentación enfocada en el CLÚSTER (repo1) para EKS Auto Mode.
