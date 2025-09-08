# EKS Auto Mode - Capa de Cómputo (NodeClass / NodePool)

## 1. Objetivo
Proveer la definición de **cómputo dinámico** para el clúster EKS (ya creado en repo1) limitando la provisión únicamente a instancias `c7i.xlarge`, con control explícito de escalado (límite de CPU/Memoria) y políticas de consolidación para optimizar costos.

## 2. Alcance de Este Repositorio
Incluye únicamente:
- Manifiesto `NodeClass` (selección de subredes privadas y Security Group del clúster).
- Manifiesto `NodePool` (restricciones de tipo de instancia, etiquetas, límites de capacidad, política de consolidación).
- Backend Terraform separado para mantener estado independiente.

NO incluye (intencionalmente en esta fase):
- Workloads / Deployments de prueba.
- Instrucciones operativas con comandos `kubectl` (se agregarán después).

## 3. Dependencias
Este módulo depende de que ya existan (via estados remotos S3):
1. VPC (repo VPC) con subredes privadas etiquetadas y **regla SG puerto 443 intra-SG** (crítica para registro de nodos).
2. Clúster EKS (repo1) con Auto Mode habilitado y Access Entry correcto.

## 4. Componentes Clave
| Componente | Recurso Terraform | Función |
|------------|------------------|---------|
| NodeClass | `kubectl_manifest.nodeclass` | Define rol IAM de nodos, subredes privadas y SG a usar. |
| NodePool  | `kubectl_manifest.nodepool`  | Define restricciones, límites y política de consolidación. |

## 5. Diseño del NodeClass
Especifica:
- `role`: reutiliza el rol IAM de nodos del clúster (estado remoto repo1).
- `subnetSelectorTerms`: filtra subredes privadas vía etiquetas `kubernetes.io/cluster/<cluster_name>=shared` + `kubernetes.io/role/internal-elb=1`.
- `securityGroupSelectorTerms`: fuerza uso del Security Group del clúster (que ya permite tráfico 443 SG→SG definido en VPC).
- `amiFamily: Bottlerocket` para menor superficie y arranque rápido.

## 6. Diseño del NodePool
Puntos relevantes del manifiesto:
- `requirements` restringe a:
	- Tipo de instancia: SOLO `c7i.xlarge` (control de costo y benchmark estable).
	- Arquitectura: `amd64`.
	- `capacity-type`: `on-demand` (predecible; considerar spot luego si se desea ahorro adicional).
- `labels` agrega `workload-type=web` (útil para afinidades y monitoreo).
- `limits`: `cpu: 24`, `memory: 48Gi`.
	- Cada `c7i.xlarge` ≈ 4 vCPU / 8 GiB → Máximo efectivo ≈ 6 nodos (24 / 4 = 6) antes de detener escalado.
	- Mantiene techo claro de costo y evita crecimiento no planificado.
- `disruption`:
	- `consolidationPolicy: WhenEmptyOrUnderutilized` permite consolidar nodos con baja ocupación.
	- `consolidateAfter: 60s` acelera liberación temprana de capacidad sobrante.

## 7. Control de Costos y Riesgos
| Mecanismo | Beneficio |
|----------|-----------|
| Restricción a `c7i.xlarge` | Uso consistente y medible. |
| Límites de CPU/Memoria | Evita escalado ilimitado. |
| Consolidación 60s | Libera nodos infrautilizados rápido. |
| Subredes privadas | Reduce superficie de ataque. |
| Reutilización SG clúster | Menos objetos de red dispersos; aplica regla 443 crítica. |

## 8. Variables Principales
Archivo `dev-vars.tfvars` ejemplo:
```
region          = "us-west-1"
node_class_name = "c7i-xlarge-class"
node_pool_name  = "c7i-xlarge-pool"
```

## 9. Backend de Estado
`backend.tf`:
```
bucket = "eks-auto-mode-c7i-xlarge-tfstate-alann"
key    = "repo2/terraform-custom-automode.tfstate"
region = "us-west-1"
```
Separado de VPC y clúster para permitir recreación selectiva.

## 10. Flujo de Despliegue Recomendado
1. Confirmar clúster (repo1) listo; add-ons en estado normal (o manejado según guía si EBS estuvo DEGRADADO, ya que se recupera al desplegar workloads).
2. Ajustar nombres en `dev-vars.tfvars` si se desea aislar múltiples entornos.
3. Ejecutar Terraform (ver comandos abajo).
4. Validación posterior (NO incluida aquí): se hará más adelante con herramientas de inspección (kubectl / observabilidad).

## 11. Comandos Terraform (PowerShell Windows)
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
Ver (si se definen en el futuro) outputs:
```powershell
terraform output
```

## 12. Destrucción Segura
1. Asegurarse que workloads no requieran nodos (escala a 0 si aplica con futuras herramientas / etiquetas / desasignación).
2. Ejecutar:
```powershell
terraform destroy -var-file="dev-vars.tfvars" -auto-approve
```
3. Luego destruir clúster (repo1) y finalmente VPC si se requiere apagar todo.

## 13. Errores Frecuentes
| Situación | Causa | Acción |
|-----------|-------|--------|
| NodePool no crea nodos | Falta demanda (no hay pods pendientes) | Desplegar workloads (se documentará luego). |
| NodeClass rechazado | Etiquetas de subred ausentes | Revisar etiquetas en VPC repo. |
| Nodos NotReady | Falta regla 443 SG→SG (VPC) | Verificar SG en repo VPC. |
| Escalado se detiene antes de lo esperado | Límite CPU/Memoria alcanzado | Ajustar `limits` tras análisis de costos. |
| Instancias diferente tipo | Otro NodePool en cluster | Revisar existencia de NodePools heredados o default. |

## 14. Mantenimiento / Mejora Futura
- Añadir segundo NodePool (ej: spot) con límites inferiores para trabajos batch.
- Parametrizar `requirements` y `limits` vía variables para distintos sabores de entorno (dev / perf / prod).
- Incorporar métricas (Prometheus / CloudWatch) para ajustar `consolidateAfter` más allá de 60s si genera churn.
- Agregar outputs útiles (ej: nombres de NodeClass/NodePool) cuando se requiera integración en pipelines.

## 15. TL;DR
1. Este repo añade capacidad dinámica (Auto Mode) acotada a `c7i.xlarge`.
2. NodeClass selecciona subred privada + SG del clúster (regla 443 ya definida en VPC).
3. NodePool limita escalado (24 CPU / 48Gi) ≈ 6 nodos máx.
4. Consolidación rápida (60s) para optimizar costo.
5. Ejecutar: init → plan → apply; destruir antes de eliminar clúster para ciclo ordenado.

---
Documentación enfocada en la CAPA DE CÓMPUTO (repo2) sin incluir todavía pasos operativos kubectl.

