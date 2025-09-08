#!/usr/bin/env bash
# EKS Auto Mode Testing Suite (Bash)
# Equivalent (simplificado) de test-auto-mode.ps1 para entornos Linux/macOS.
# Modos:
#   --quick     Ejecuta prueba ultra-rápida (super-quick + quick jobs si existen)
#   --stress    Despliega stress + memory + hpa y monitorea ~5m
#   --complete  Flujo completo (estado, stress, scale, monitoreo, resultados)
#   --cleanup   Elimina workloads de prueba
#   --menu      Menú interactivo (por defecto si no hay flags)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${SCRIPT_DIR}"  # carpeta tests

COLOR_GREEN='\e[32m'; COLOR_YELLOW='\e[33m'; COLOR_RED='\e[31m'; COLOR_CYAN='\e[36m'; COLOR_RESET='\e[0m'

req_cmds=(kubectl awk sed grep)
for c in "${req_cmds[@]}"; do
  command -v "$c" >/dev/null 2>&1 || { echo -e "${COLOR_RED}Falta comando requerido: $c${COLOR_RESET}"; exit 1; }
done

echo -e "${COLOR_GREEN}=== EKS Auto Mode Testing Suite (bash) ===${COLOR_RESET}" 

log() { echo -e "${COLOR_CYAN}[$(date +%H:%M:%S)]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

check_context() {
  if ! kubectl config current-context >/dev/null 2>&1; then
    err "kubectl sin contexto. Ejecuta aws eks update-kubeconfig ..."
    exit 1
  fi
}

show_cluster_status() {
  log "Estado inicial del cluster"
  kubectl get nodes -o wide || true
  kubectl get nodeclaim,nodepool -A || true
  kubectl get pods -A --field-selector=status.phase=Pending || true
}

deploy_stress_tests() {
  log "Aplicando stress-test.yaml"
  kubectl apply -f "${TEST_DIR}/stress-test.yaml"
  sleep 5
  log "Aplicando memory-test.yaml"
  kubectl apply -f "${TEST_DIR}/memory-test.yaml"
  sleep 5
  log "Aplicando hpa-test.yaml"
  kubectl apply -f "${TEST_DIR}/hpa-test.yaml" || warn "HPA pudo fallar (verificar API autoscaling/v2)"
}

deploy_quick_tests() {
  if [[ -f "${TEST_DIR}/super-quick-test.yaml" ]]; then
    log "Aplicando super-quick-test.yaml"
    kubectl apply -f "${TEST_DIR}/super-quick-test.yaml"
  fi
  if [[ -f "${TEST_DIR}/quick-test.yaml" ]]; then
    log "Aplicando quick-test.yaml"
    kubectl apply -f "${TEST_DIR}/quick-test.yaml"
  fi
}

generate_load() {
  log "Escalando stress-test a 12 réplicas (si existe)"
  kubectl scale deployment stress-test --replicas=12 2>/dev/null || warn "stress-test no encontrado"
  sleep 15
  log "Escalando memory-test a 8 réplicas (si existe)"
  kubectl scale deployment memory-test --replicas=8 2>/dev/null || warn "memory-test no encontrado"
}

monitor_scaling() {
  local loops=${1:-15}  # 15 * 20s = ~5m
  log "Monitoreando escalado (${loops} iteraciones de 20s)"
  for ((i=1;i<=loops;i++)); do
    echo "--- Iteración $i / $loops ---"
    kubectl get nodes -o wide | grep -E "NAME|c7i" || true
    kubectl get nodeclaim || true
    kubectl get pods -A --field-selector=status.phase=Pending | head -20 || true
    sleep 20
  done
}

show_results() {
  log "Resultados finales"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels."node.kubernetes.io/instance-type",ZONE:.metadata.labels."topology.kubernetes.io/zone",AGE:.metadata.creationTimestamp
  echo
  kubectl get nodeclaim -o wide || true
  echo
  kubectl get events --sort-by=.lastTimestamp | tail -20 || true
}

cleanup_tests() {
  log "Eliminando workloads de prueba"
  kubectl delete -f "${TEST_DIR}/stress-test.yaml" --ignore-not-found
  kubectl delete -f "${TEST_DIR}/memory-test.yaml" --ignore-not-found
  kubectl delete -f "${TEST_DIR}/hpa-test.yaml" --ignore-not-found
  kubectl delete -f "${TEST_DIR}/quick-test.yaml" --ignore-not-found
  kubectl delete -f "${TEST_DIR}/super-quick-test.yaml" --ignore-not-found
  kubectl delete deployment nginx-c7i-test --ignore-not-found
  log "Esperando terminación de pods (40s)"
  sleep 40 || true
  kubectl get nodes || true
}

run_complete() {
  show_cluster_status
  deploy_stress_tests
  log "Esperando 60s para bootstrap inicial"
  sleep 60
  generate_load
  monitor_scaling 18  # ~6min
  show_results
}

run_quick() {
  show_cluster_status
  deploy_quick_tests
  monitor_scaling 6  # 2 minutos
  show_results
}

run_stress() {
  show_cluster_status
  deploy_stress_tests
  monitor_scaling 15
  show_results
}

show_menu() {
  echo -e "${COLOR_GREEN}\n=== MENU TESTING (bash) ===${COLOR_RESET}"
  echo "1) Estado cluster"
  echo "2) Quick test"
  echo "3) Stress test"
  echo "4) Complete test"
  echo "5) Generar carga extra"
  echo "6) Ver resultados"
  echo "7) Cleanup"
  echo "8) Salir"
}

interactive_loop() {
  while true; do
    show_menu
    read -rp "Opción: " opt
    case "$opt" in
      1) show_cluster_status;;
      2) run_quick;;
      3) run_stress;;
      4) run_complete;;
      5) generate_load;;
      6) show_results;;
      7) cleanup_tests;;
      8) exit 0;;
      *) warn "Opción inválida";;
    esac
  done
}

main() {
  check_context
  case "${1:-}" in
    --quick) run_quick;;
    --stress) run_stress;;
    --complete) run_complete;;
    --cleanup) cleanup_tests;;
    --menu|"") interactive_loop;;
    *) echo "Uso: $0 [--quick|--stress|--complete|--cleanup|--menu]"; exit 1;;
  esac
}

main "$@"
