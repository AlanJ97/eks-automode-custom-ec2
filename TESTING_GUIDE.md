# Guía de Testing para EKS Auto Mode

## Tipos de Tests Recomendados

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

## Cómo Ejecutar los Tests

### Opción 1: Script Automatizado (Recomendado)
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

## Comandos de Monitoreo Útiles

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

## Métricas de Éxito

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

## Scripts de Limpieza

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

## Interpretación de Resultados

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

## Consideraciones de Costo

**⚠️ IMPORTANTE**: Los tests generarán costo por:
- Instancias EC2 c7i.xlarge ($0.2448/hora por instancia)
- Tráfico de red entre AZs
- Almacenamiento EBS asociado

**Recomendación**: Ejecutar tests en horarios planificados y limpiar recursos inmediatamente después.

## Automatización y CI/CD

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

Esta guía te proporciona un framework completo para validar que tu EKS Auto Mode funciona correctamente con instancias c7i.xlarge.
