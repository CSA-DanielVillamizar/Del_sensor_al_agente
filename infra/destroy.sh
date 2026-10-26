#!/usr/bin/env bash
# Elimina el grupo de recursos completo de la demo (CA-04.3, Art. 9). Equivalente de infra/destroy.ps1.
# Uso: infra/destroy.sh [-g rg-dsa-demo] [--yes] [--keep-deleted-vault]
set -euo pipefail

RG="rg-dsa-demo"
ASSUME_YES="false"
KEEP_VAULT="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES="true"; shift ;;
    --keep-deleted-vault) KEEP_VAULT="true"; shift ;;
    *) echo "Argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(az group exists --name "$RG")" != "true" ]]; then
  echo "El grupo $RG no existe. Nada que borrar."
  exit 0
fi

mapfile -t VAULTS < <(az keyvault list --resource-group "$RG" --query '[].name' --output tsv)
echo "Recursos en $RG:"
az resource list --resource-group "$RG" --query '[].{tipo:type, nombre:name}' --output table

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Escribe el nombre del grupo para confirmar el borrado: " answer
  [[ "$answer" == "$RG" ]] || { echo "Cancelado."; exit 1; }
fi

az group delete --name "$RG" --yes --output none
echo "Grupo $RG eliminado. Al redesplegar, repite los dos comandos del administrador (ADR-007)."

if [[ "$KEEP_VAULT" != "true" ]]; then
  for v in "${VAULTS[@]}"; do
    [[ -z "$v" ]] && continue
    echo "Purgando el Key Vault $v (solo guardaba la cadena de func-reader)..."
    az keyvault purge --name "$v" --output none
  done
fi
