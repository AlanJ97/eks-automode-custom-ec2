# Guía de Testing para EKS Auto Mode

## 0. Prerrequisitos
Antes de iniciar:
- Clúster EKS (repo1) listo y accesible (contexto de `kubectl` correcto).
- NodeClass / NodePool (repo2) aplicados (NodePool con límite CPU=24 / Mem=48Gi).
- Regla **puerto 443 SG→SG** existente (desde VPC) para que los nodos se registren.
- (Opcional) Métricas habilitadas (`kubectl top`) vía Metrics Server si se desean datos de uso.

Si la carpeta de manifiestos cambió a `test/` en vez de `tests/`, sustituye la ruta en los comandos (ambos nombres se mencionan aquí). Verifica con:
```bash
ls -1 test 2>/dev/null || ls -1 tests
```

## 1. Tipos de Tests Recomendados

### 1. **Tests de Escalado Horizontal (Node Provisioning)**
Objetivo: Validar que Karpenter provisiona nuevos nodos c7i.xlarge cuando hay demanda.

**Indicadores a medir:**
- Tiempo de provisión de nuevos nodos
- Correcta selección del tipo de instancia (c7i.xlarge)
- Distribución entre zonas de disponibilidad
- Capacidad on-demand vs spot (si aplica)

### 2. **Tests de Estrés de CPU/Memoria**
Objetivo: Verificar que los nodos manejan cargas intensivas y escalan apropiadamente.

**Métricas importantes:**
- Utilización de CPU/memoria por nodo
- Latencia de respuesta bajo carga
- Estabilidad del cluster durante picos

### 3. **Tests de Escalado Dinámico (HPA)**
Objetivo: Validar que el Horizontal Pod Autoscaler funciona correctamente con Auto Mode.

**Comportamientos esperados:**
- Scale-up cuando la utilización supera umbrales
- Scale-down gradual cuando la carga disminuye
- Respeto a límites mínimos/máximos

### 4. **Tests de Resiliencia**
Objetivo: Verificar recuperación ante fallos y comportamiento en escenarios adversos.

**Escenarios a probar:**
- Terminación abrupta de nodos
- Pods sin recursos suficientes
- Network partitions temporales

## 2. Flujo Sugerido de Prueba de Escalado Máximo (Paso a Paso) ⭐
Objetivo: Forzar creación de nodos hasta alcanzar el límite (≈ 6 nodos c7i.xlarge) y validar consolidación.

1. Estado inicial (cero o pocos nodos de workload):
  ```bash
  kubectl get nodes -o wide
  kubectl get nodeclaim,nodepool -A
  ```
2. Aplicar despliegue de estrés base (crea 6 réplicas con CPU sostenida):
  ```bash
  kubectl apply -f tests/stress-test.yaml
  # o si está en carpeta singular
  kubectl apply -f test/stress-test.yaml
  ```
3. Esperar 1–3 minutos y observar NodeClaims creados:
  ```bash
  watch -n 15 'kubectl get nodeclaim; echo "---"; kubectl get nodes -o wide | grep c7i'
  ```
4. Añadir carga de memoria para diversificar uso de recursos:
  ```bash
  kubectl apply -f tests/memory-test.yaml
  ```
5. Activar HPA para inducir aumentos de réplicas dinámicos (sobre el deployment stress-test):
  ```bash
  kubectl apply -f tests/hpa-test.yaml
  ```
6. (Opcional) Escalar manualmente para acelerar demanda:
  ```bash
  kubectl scale deployment stress-test --replicas=12
  kubectl scale deployment memory-test --replicas=8
  ```
7. Validar que no se superen los límites del NodePool (observa que, al alcanzar ~24 vCPU solicitados, se detiene el incremento de nodos):
  ```bash
  kubectl describe nodepool c7i-xlarge-pool | grep -i limit -A3
  ```
8. Confirmar distribución multi-AZ (etiqueta `topology.kubernetes.io/zone`):
  ```bash
  kubectl get nodes -L topology.kubernetes.io/zone -o wide
  ```
9. Revisar eventos recientes (creación / consolidación / underutilized):
  ```bash
  kubectl get events --sort-by=.lastTimestamp | grep -i -E 'Karpenter|Consolidat' | tail -30
  ```
10. (Tras la prueba) Reducir réplicas para observar consolidación (si no hay carga, nodos se liberan):
   ```bash
   kubectl scale deployment stress-test --replicas=0
   kubectl scale deployment memory-test --replicas=0
   ```
11. Esperar periodo de `consolidateAfter` (60s) + tiempo de terminación y verificar nodos removidos:
   ```bash
   watch -n 20 'kubectl get nodes; echo "---"; kubectl get nodeclaim'
   ```

📌 Nota: La consolidación solo elimina nodos cuando están vacíos o infrautilizados según lógica de Karpenter.

## 3. Cómo Ejecutar los Tests

### Opción 1: Script Automatizado (Recomendado)
Dispones de dos variantes según el sistema:

| Script | Entorno | Ejemplo de uso |
|--------|---------|----------------|
| `test-auto-mode.ps1` | Windows PowerShell | `./test-auto-mode.ps1` |
| `test-auto-mode.sh`  | Linux / macOS / Git Bash | `bash tests/test-auto-mode.sh --menu` |

Modos del script bash:
```
--quick      # Jobs rápidos (super / quick)
--stress     # stress + memory + hpa (~5 min monitoreo)
--complete   # Flujo completo (estado, despliegue, escala, resultados)
--cleanup    # Limpieza de workloads
--menu       # Menú interactivo (por defecto)
```
Ejemplo rápido (Git Bash):
```bash
chmod +x tests/test-auto-mode.sh
bash tests/test-auto-mode.sh --stress
```
Si `kubectl` no se detecta en Git Bash, asegúrate de que esté en el PATH o ejecuta primero desde PowerShell para confirmar acceso.
```powershell
# Ejecutar el suite completo de tests
.\test-auto-mode.ps1
```

### Opción 2: Tests Manuales

#### Test Ultra-Rápido (3 minutos)
```bash
# 1. Estado inicial
kubectl get nodes
kubectl get nodeclaim,nodepool

# 2. Aplicar test super rápido
kubectl apply -f tests/super-quick-test.yaml

# 3. Monitorear
kubectl get pods -w
# En otra terminal: kubectl get nodes -w

# 4. Limpiar
kubectl delete -f tests/super-quick-test.yaml
```

#### Test Rápido (5 minutos)
```bash
# 1. Estado inicial
kubectl get nodes
kubectl get nodeclaim,nodepool

# 2. Aplicar test rápido
kubectl apply -f tests/quick-test.yaml

# 3. Monitorear
kubectl get pods -w
kubectl get nodes -w

# 4. Limpiar
kubectl delete -f tests/quick-test.yaml
```

#### Test de Estrés (7 minutos máximo)
```bash
# 1. Aplicar cargas de trabajo
kubectl apply -f tests/stress-test.yaml
kubectl apply -f tests/memory-test.yaml

# 2. Monitorear escalado
watch -n 30 'kubectl get nodes; echo "---"; kubectl get pods; echo "---"; kubectl top nodes'

# 3. Generar más carga (opcional)
kubectl scale deployment stress-test --replicas=12

# 4. Observar provisión de nodos
kubectl get events --sort-by='.lastTimestamp' | tail -20
```

#### Test con HPA (7 minutos máximo)
```bash
# 1. Aplicar HPA
kubectl apply -f tests/hpa-test.yaml

# 2. Generar carga variable
kubectl apply -f tests/stress-test.yaml

# 3. Monitorear comportamiento
kubectl get hpa -w
kubectl get pods -w
```

## 4. Comandos de Monitoreo Útiles

### Estado General
```bash
# Nodos y capacidad
kubectl get nodes -o wide
kubectl describe nodes

# NodeClaims de Karpenter
kubectl get nodeclaim -o wide
kubectl describe nodeclaim

# Utilización de recursos
kubectl top nodes
kubectl top pods
```

### Eventos y Logs
```bash
# Eventos recientes de Karpenter
kubectl get events --sort-by='.lastTimestamp' | grep -i karpenter

# Logs de Karpenter (si accesible)
kubectl logs -n karpenter deployment/karpenter

# Estado de los NodePools
kubectl describe nodepool c7i-xlarge-pool
```

### Debugging
```bash
# Pods que no pueden ser programados
kubectl get pods --field-selector=status.phase=Pending

# Describe pod para ver razones
kubectl describe pod <pod-name>

# Ver restricciones de nodos
kubectl get nodes --show-labels
```

## 5. Métricas de Éxito

### ✅ Indicadores Positivos
- **Tiempo de provisión**: Nuevos nodos c7i.xlarge aparecen en < 5 minutos
- **Precisión de tipo**: Solo instancias c7i.xlarge son provisionadas
- **Distribución de zona**: Nodos se distribuyen entre us-west-1a y us-west-1b
- **Programación de pods**: Pods pendientes se programan rápidamente
- **Estabilidad**: No hay crashloops o errores persistentes

### ❌ Señales de Problemas
- Nodos de tipos incorrectos (no c7i.xlarge)
- Tiempo de provisión > 10 minutos
- Pods que permanecen en estado Pending > 5 minutos
- Errores de autorización en eventos de Karpenter
- Nodos que no se unen al cluster

## 6. Scripts de Limpieza

### Limpiar Tests Específicos
```bash
kubectl delete -f tests/stress-test.yaml
kubectl delete -f tests/memory-test.yaml
kubectl delete -f tests/hpa-test.yaml
kubectl delete -f tests/quick-test.yaml
```

### Limpiar Nodos Manualmente (Si Necesario)
```bash
# Ver NodeClaims activos
kubectl get nodeclaim

# Eliminar NodeClaim específico (forzará terminación del nodo)
kubectl delete nodeclaim <nodeclaim-name>
```

## 7. Interpretación de Resultados

### Escenario Normal
```
NODES: 2-3 nodos c7i.xlarge
PODS: La mayoría en estado Running
EVENTS: "Successfully launched nodeclaim"
TIMING: Nuevos nodos en 3-5 minutos
```

### Escenario con Problemas
```
NODES: Nodos no aparecen o tipos incorrectos
PODS: Muchos en estado Pending
EVENTS: Errores de autorización o límites
TIMING: > 10 minutos sin provisión
```

## 8. Consideraciones de Costo

**⚠️ IMPORTANTE**: Los tests generarán costo por:
- Instancias EC2 c7i.xlarge ($0.2448/hora por instancia)
- Tráfico de red entre AZs
- Almacenamiento EBS asociado

**Recomendación**: Ejecutar tests en horarios planificados y limpiar recursos inmediatamente después.

## 9. Automatización y CI/CD

Para integrar estos tests en pipelines:

```yaml
# Ejemplo para GitHub Actions o similar
test-auto-mode:
  steps:
    - name: Deploy test workloads
      run: kubectl apply -f tests/
    
    - name: Wait for scaling
      run: sleep 300
    
    - name: Validate nodes
      run: |
        NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
        if [ $NODE_COUNT -lt 2 ]; then
          echo "ERROR: Expected at least 2 nodes"
          exit 1
        fi
    
    - name: Cleanup
      run: kubectl delete -f tests/
      if: always()
```

## 10. Buenas Prácticas Operativas
| Práctica | Razón |
|----------|-------|
| Limitar replicas iniciales | Evita picos de costo inesperados |
| Revisar eventos antes de escalar más | Detecta throttling / permisos |
| Registrar tiempos de provisión | Métrica clave para SLO interno |
| Limpiar workloads tras cada experimento | Minimiza gastos |
| Verificar `kubectl get nodeclaim` vs `kubectl get nodes` | Detecta retrasos de join |

## 11. Notas sobre Add-on EBS CSI DEGRADADO
Si en la consola el add-on EBS CSI aparece DEGRADADO pero el clúster y NodePool están operativos:
- Puedes proceder con estas pruebas: la actividad (creación de pods con volúmenes futuros) y/o un re-aplicar del módulo de clúster suelen normalizarlo.
- Si Terraform quedó esperando más de 20 minutos, cancelar (Ctrl+C) y continuar con pruebas no afecta este flujo.

---
Esta guía proporciona un framework completo para validar que tu EKS Auto Mode funciona correctamente con instancias c7i.xlarge y límites definidos.
