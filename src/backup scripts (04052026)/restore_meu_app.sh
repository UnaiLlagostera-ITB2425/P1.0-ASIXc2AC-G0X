#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="meu"
DEPLOYMENT="meu-app"
DO_RESTORE="false"
BACKUP_FILE=""
CLEAN_FILE="/tmp/${DEPLOYMENT}-restore-clean.yaml"

usage() {
  cat <<USAGE
Uso:
  $(basename "$0") --file /ruta/al/backup.yaml --restore
  $(basename "$0") --file /ruta/al/backup.yaml --plan
  $(basename "$0") --help

Opciones:
  --file       Ruta explícita al backup YAML a restaurar.
  --restore    Ejecuta la restauración real.
  --plan       Solo valida y muestra lo que se haría, sin aplicar cambios.
  --help       Muestra esta ayuda.

Comportamiento seguro:
  - El script NO usa ningún backup por defecto.
  - Si no pasas --restore, NO aplica cambios.
USAGE
}

PLAN_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      BACKUP_FILE="${2:-}"
      shift 2
      ;;
    --restore)
      DO_RESTORE="true"
      shift
      ;;
    --plan)
      PLAN_ONLY="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: opción no reconocida: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BACKUP_FILE" ]]; then
  echo "ERROR: debes indicar el backup con --file" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: no existe el backup: $BACKUP_FILE" >&2
  exit 1
fi

if [[ "$DO_RESTORE" != "true" && "$PLAN_ONLY" != "true" ]]; then
  echo "Modo seguro: no se aplicará nada." >&2
  echo "Usa --plan para previsualizar o --restore para ejecutar." >&2
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl no está instalado o no está en PATH" >&2
  exit 1
fi

echo "[1/4] Verificando acceso al cluster..."
kubectl cluster-info >/dev/null

echo "[2/4] Limpiando metadatos no aplicables del backup..."
awk '
  /^status:/ {skip=1}
  skip==1 {next}
  /creationTimestamp:/ {next}
  /resourceVersion:/ {next}
  /uid:/ {next}
  /generation:/ {next}
  /selfLink:/ {next}
  /managedFields:/ {skipmf=1; next}
  skipmf==1 {
    if ($0 ~ /^[^[:space:]]/) {skipmf=0} else {next}
  }
  {print}
' "$BACKUP_FILE" > "$CLEAN_FILE"

echo "[3/4] Resumen del restore:"
echo "  Namespace:     $NAMESPACE"
echo "  Deployment:    $DEPLOYMENT"
echo "  Backup origen: $BACKUP_FILE"
echo "  YAML limpio:   $CLEAN_FILE"

echo "  Primeras líneas del YAML limpio:"
head -n 30 "$CLEAN_FILE"

if [[ "$PLAN_ONLY" == "true" ]]; then
  echo
  echo "Plan completado. No se aplicaron cambios."
  exit 0
fi

read -r -p "Confirmas la restauración real de ${DEPLOYMENT} en ${NAMESPACE}? escribe 'RESTORE' para continuar: " CONFIRM
if [[ "$CONFIRM" != "RESTORE" ]]; then
  echo "Cancelado por el usuario."
  exit 1
fi

echo "[4/4] Ejecutando restore..."
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o yaml > "$HOME/${DEPLOYMENT}-pre-restore-$(date +%Y%m%d%H%M%S).yaml" || true
kubectl apply -f "$CLEAN_FILE"
kubectl rollout restart deployment/"$DEPLOYMENT" -n "$NAMESPACE"
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=180s || true

echo
echo "Estado final:"
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -o wide
