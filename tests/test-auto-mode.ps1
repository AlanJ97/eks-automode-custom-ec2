#!/usr/bin/env powershell

# Script de testing para EKS Auto Mode
# Autor: DevOps Team
# Fecha: $(Get-Date)

Write-Host "=== EKS Auto Mode Testing Suite ===" -ForegroundColor Green

# Función para mostrar estado del cluster
function Show-ClusterStatus {
    Write-Host "`n--- Estado inicial del cluster ---" -ForegroundColor Yellow
    kubectl get nodes -o wide
    kubectl get pods --all-namespaces
    kubectl top nodes 2>$null
    kubectl get nodeclaim,nodepool -A
}

# Función para aplicar tests
function Deploy-StressTests {
    Write-Host "`n--- Desplegando tests de estrés ---" -ForegroundColor Yellow
    
    # Test básico de estrés
    Write-Host "Aplicando stress-test.yaml..." -ForegroundColor Cyan
    kubectl apply -f tests/stress-test.yaml
    
    Start-Sleep -Seconds 10
    
    # Test de memoria
    Write-Host "Aplicando memory-test.yaml..." -ForegroundColor Cyan
    kubectl apply -f tests/memory-test.yaml
    
    Start-Sleep -Seconds 10
    
    # HPA
    Write-Host "Aplicando HPA..." -ForegroundColor Cyan
    kubectl apply -f tests/hpa-test.yaml
}

# Función para monitorear escalado
function Monitor-Scaling {
    param([int]$Minutes = 5)  # Reducido a 5 minutos por defecto
    
    Write-Host "`n--- Monitoreando escalado por $Minutes minutos ---" -ForegroundColor Yellow
    
    $endTime = (Get-Date).AddMinutes($Minutes)
    
    while ((Get-Date) -lt $endTime) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host "`n[$timestamp] Estado actual:" -ForegroundColor Green
        
        # Nodos
        $nodeCount = (kubectl get nodes --no-headers | Measure-Object).Count
        Write-Host "Nodos: $nodeCount" -ForegroundColor White
        
        # Pods
        $podCount = (kubectl get pods --field-selector=status.phase=Running --no-headers | Measure-Object).Count
        $pendingPods = (kubectl get pods --field-selector=status.phase=Pending --no-headers | Measure-Object).Count
        Write-Host "Pods Running: $podCount, Pending: $pendingPods" -ForegroundColor White
        
        # NodeClaims
        kubectl get nodeclaim --no-headers 2>$null | ForEach-Object {
            if ($_ -ne $null) {
                $fields = $_ -split '\s+'
                Write-Host "NodeClaim: $($fields[0]) - Type: $($fields[1]) - Zone: $($fields[3])" -ForegroundColor Magenta
            }
        }
        
        # CPU/Memory usage si está disponible
        $topNodes = kubectl top nodes --no-headers 2>$null
        if ($topNodes) {
            Write-Host "Uso de recursos:" -ForegroundColor Cyan
            $topNodes | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
        
        Start-Sleep -Seconds 20  # Reducido a 20 segundos
    }
}

# Función para generar carga adicional
function Generate-Load {
    Write-Host "`n--- Generando carga adicional ---" -ForegroundColor Yellow
    
    # Escalar stress-test para forzar más nodos
    kubectl scale deployment stress-test --replicas=12  # Reducido a 12
    Write-Host "Escalado stress-test a 12 réplicas" -ForegroundColor Cyan
    
    Start-Sleep -Seconds 20  # Reducido tiempo de espera
    
    # Escalar memory-test
    kubectl scale deployment memory-test --replicas=8  # Reducido a 8
    Write-Host "Escalado memory-test a 8 réplicas" -ForegroundColor Cyan
}

# Función para limpiar tests
function Cleanup-Tests {
    Write-Host "`n--- Limpiando tests ---" -ForegroundColor Yellow
    kubectl delete -f tests/stress-test.yaml --ignore-not-found=true
    kubectl delete -f tests/memory-test.yaml --ignore-not-found=true
    kubectl delete -f tests/hpa-test.yaml --ignore-not-found=true
    
    Write-Host "Esperando que los pods se terminen..." -ForegroundColor Cyan
    Start-Sleep -Seconds 60
    
    Write-Host "Estado final del cluster:" -ForegroundColor Yellow
    kubectl get nodes
    kubectl get pods --all-namespaces
}

# Función para mostrar métricas finales
function Show-TestResults {
    Write-Host "`n=== RESULTADOS DEL TEST ===" -ForegroundColor Green
    
    Write-Host "`nNodos creados:" -ForegroundColor Yellow
    kubectl get nodes -o custom-columns="NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,AGE:.metadata.creationTimestamp"
    
    Write-Host "`nNodeClaims:" -ForegroundColor Yellow
    kubectl get nodeclaim -o wide
    
    Write-Host "`nEventos recientes de Karpenter:" -ForegroundColor Yellow
    kubectl get events --sort-by='.lastTimestamp' | Select-Object -Last 20
}

# Menú principal
function Show-Menu {
    Write-Host "`n=== MENU DE TESTING ===" -ForegroundColor Green
    Write-Host "1. Ver estado del cluster"
    Write-Host "2. Ejecutar test completo (recomendado)"
    Write-Host "3. Solo desplegar tests"
    Write-Host "4. Solo monitorear (10 min)"
    Write-Host "5. Generar carga adicional"
    Write-Host "6. Limpiar tests"
    Write-Host "7. Ver resultados"
    Write-Host "8. Salir"
    Write-Host
}

# Función de test completo
function Run-CompleteTest {
    Write-Host "`n=== EJECUTANDO TEST COMPLETO ===" -ForegroundColor Green
    
    Show-ClusterStatus
    Deploy-StressTests
    
    Write-Host "`nEsperando 1 minuto para que se inicien los pods..." -ForegroundColor Cyan
    Start-Sleep -Seconds 60  # Reducido a 1 minuto
    
    Generate-Load
    Monitor-Scaling -Minutes 6  # Total de 6 minutos
    
    Show-TestResults
    
    $cleanup = Read-Host "`n¿Quieres limpiar los tests? (y/n)"
    if ($cleanup -eq 'y') {
        Cleanup-Tests
    }
}

# Main script
Clear-Host
Write-Host "EKS Auto Mode Testing Suite" -ForegroundColor Green
Write-Host "============================" -ForegroundColor Green

# Verificar que estamos conectados al cluster correcto
$currentContext = kubectl config current-context 2>$null
if ($currentContext) {
    Write-Host "Contexto actual: $currentContext" -ForegroundColor Cyan
} else {
    Write-Host "Error: No hay contexto de kubectl configurado" -ForegroundColor Red
    exit 1
}

# Loop del menú
do {
    Show-Menu
    $choice = Read-Host "Selecciona una opción (1-8)"
    
    switch ($choice) {
        "1" { Show-ClusterStatus }
        "2" { Run-CompleteTest }
        "3" { Deploy-StressTests }
        "4" { Monitor-Scaling -Minutes 5 }
        "5" { Generate-Load }
        "6" { Cleanup-Tests }
        "7" { Show-TestResults }
        "8" { 
            Write-Host "¡Hasta luego!" -ForegroundColor Green
            break 
        }
        default { 
            Write-Host "Opción inválida. Por favor selecciona 1-8." -ForegroundColor Red 
        }
    }
    
    if ($choice -ne "8") {
        Read-Host "`nPresiona Enter para continuar..."
    }
} while ($choice -ne "8")
