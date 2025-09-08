# EKS Auto Mode (Proyecto General) - Guía Rápida

## 1. Resumen
Infraestructura compuesta por 3 capas Terraform separadas:
1. VPC (red, subredes, SG con **regla crítica puerto 443 SG→SG**).
2. Cluster (repo1) EKS Auto Mode + Add-ons.
3. Cómputo (repo2) NodeClass / NodePool restringido a `c7i.xlarge`.

Este README SOLO cubre ejecución rápida y pruebas básicas. Para detalle profundo ver los READMEs dentro de cada carpeta.

## 2. Estructura
```
VPC repo/        # Red y SG
repo1/           # Cluster EKS (Auto Mode, Add-ons, Access Entry)
repo2/           # NodeClass & NodePool c7i.xlarge
tests/           # Manifiestos de pruebas (stress, memory, hpa, jobs)
```

## 3. Prerrequisitos
- Terraform >= 1.6
- AWS CLI configurado (perfil con permisos EKS / EC2 / IAM razonables)
- kubectl instalado
- Bucket S3 para estados ya creado (ver backend.tf en cada repo)

## 4. Flujo de Despliegue (PowerShell)
1. VPC:
```powershell
cd "VPC repo"
terraform init
terraform plan -var-file dev-vars.tfvars -out tfplan
terraform apply tfplan
```
2. Cluster (repo1) – primera vez usar `create_node_access_entry = true` (luego en `false` si ya existe):
```powershell
cd ..\repo1
terraform init
terraform plan -var-file dev-vars.tfvars -out tfplan
terraform apply tfplan
```
3. kubeconfig:
```powershell
aws eks update-kubeconfig --region us-west-1 --name eks-auto-mode-demo
kubectl config current-context
```
4. Cómputo (repo2):
```powershell
cd ..\repo2
terraform init
terraform plan -var-file dev-vars.tfvars -out tfplan
terraform apply tfplan
```

## 5. Validación Inicial Rápida
```powershell
kubectl get nodepool,nodeclass
kubectl get nodes
kubectl get nodeclaim
```
Si aún no hay nodos (aparece solo el system), desplegar un workload de prueba (siguiente sección).

## 6. Workloads de Prueba Disponibles
Ubicación: `repo2/` (archivos de arranque) y `tests/` (pruebas de carga).

| Archivo | Tipo | Uso | Efecto Esperado |
|---------|------|-----|-----------------|
| `test-c7i-deployment.yaml` | Deployment + Service | Validación mínima de provisión c7i.xlarge | Crea 1 nodo si no existe. |
| `test-deployment.yaml` | Deployment + Service | Prueba nginx 2 réplicas (etiquetas workload-type) | Puede compartir nodo si hay capacidad. |
| `test-demo.yaml` | Deployment + LB | Expone LoadBalancer (requiere subredes públicas) | Valida integración con LB. |
| `tests/stress-test.yaml` | Deployment + Service | CPU sostenida (6 réplicas) | Escalado inicial agresivo. |
| `tests/memory-test.yaml` | Deployment | Uso intensivo memoria | Fuerza nuevos nodos si falta RAM. |
| `tests/hpa-test.yaml` | HPA | Escalado horizontal dinámico | Aumenta réplicas de `stress-test`. |
| `tests/quick-test.yaml` | Job | Validación corta (2 min) | 3 pods paralelos. |
| `tests/super-quick-test.yaml` | Job | Validación muy corta | 2 pods ~90s. |

## 7. Despliegue Básico de Prueba
```powershell
kubectl apply -f repo2\test-c7i-deployment.yaml
kubectl get pods -w
kubectl get nodes -w
```
Verifica que el nuevo nodo sea `c7i.xlarge`:
```powershell
kubectl get nodes -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels."node.kubernetes.io/instance-type",ZONE:.metadata.labels."topology.kubernetes.io/zone"
```

## 8. Escalado con Carga
```powershell
kubectl apply -f tests\stress-test.yaml
kubectl apply -f tests\memory-test.yaml
kubectl apply -f tests\hpa-test.yaml
```
Monitoreo:
```powershell
watch kubectl get nodes
watch kubectl get nodeclaim
kubectl get events --sort-by=.lastTimestamp | Select-Object -Last 25
```
Límite: El NodePool está configurado para no superar ~24 vCPU totales (≈6 nodos c7i.xlarge).

## 9. Observación y Diagnóstico Rápido
```powershell
kubectl describe nodepool c7i-xlarge-pool | Select-String -Pattern Limit,capacity
kubectl get pods --all-namespaces --field-selector=status.phase=Pending
kubectl top nodes  # si Metrics Server disponible
```

## 10. Access Entry (Resumen Clave)
- Primera ejecución: `create_node_access_entry = true` (repo1) crea entrada.
- Si falla/interrumpe y ya existe en AWS: cambiar a `false` y re-aplicar.
- Evita error 409 `ResourceInUseException`.

## 11. Add-on EBS CSI en Estado DEGRADADO
Si aparece DEGRADADO:
1. Tras ~20 min puedes cancelar `terraform apply` (Ctrl+C) si solo espera el add-on.
2. Continúa con repo2 y aplica workloads: suele recuperarse.
3. Alternativa: esperar timeout (~40 min) y luego re-aplicar cluster.

## 12. Limpieza (Orden Recomendado)
```powershell
# 1. Eliminar workloads de prueba
kubectl delete -f tests --recursive 2>$null
kubectl delete -f repo2\test-c7i-deployment.yaml --ignore-not-found

# 2. Infra de cómputo
cd repo2; terraform destroy -var-file dev-vars.tfvars -auto-approve

# 3. Cluster
cd ..\repo1; terraform destroy -var-file dev-vars.tfvars -auto-approve

# 4. VPC
cd "..\VPC repo"; terraform destroy -var-file dev-vars.tfvars -auto-approve
```

## 13. Problemas Rápidos
| Síntoma | Causa | Acción |
|---------|-------|--------|
| Nodos NotReady | Falta regla 443 SG→SG | Ver README VPC. |
| Error 409 Access Entry | Entrada ya existe | Poner variable en `false` y re-plan. |
| Pods Pending largos | Falta capacidad / límites alcanzados | Revisar NodePool limits. |
| Instancia no c7i.xlarge | Otro NodePool activo | Revisar `kubectl get nodepool`. |
| Add-on EBS DEGRADADO | Lenta convergencia | Ver sección 11. |

## 14. Referencias Detalladas
- Red (VPC): ver `VPC repo/ReadMe.md`
- Cluster: ver `repo1/ReadMe.md`
- Cómputo (NodeClass/NodePool): ver `repo2/ReadMe.md`
- Guía completa de pruebas: `tests/TESTING_GUIDE.md`

## 15. TL;DR
1. Deploy VPC → Cluster (`create_node_access_entry=true` primera vez) → kubeconfig → Cómputo.
2. Aplicar `test-c7i-deployment.yaml` para forzar primer nodo.
3. Añadir `stress-test.yaml` + `memory-test.yaml` (+ HPA) para escalar.
4. Observar `kubectl get nodeclaim,nodes` hasta ~6 nodos.
5. Limpiar en orden inverso para evitar recursos huérfanos.

---
Para cualquier detalle profundo consulta los READMEs específicos en cada carpeta.
