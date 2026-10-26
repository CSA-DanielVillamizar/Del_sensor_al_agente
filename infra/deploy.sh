#!/usr/bin/env bash
# Despliega la infraestructura de la demo y publica la Function (T-019, CA-04.3, CA-06.4).
# Equivalente en Bash de infra/deploy.ps1. No inicia sesión en az ni escribe identificadores en archivos.
#
# Uso: infra/deploy.sh [-g rg-dsa-demo] [-l eastus2] [-r <región del grupo>] [-s F1|B1] [-a 0|1]
#                      [--what-if] [--skip-publish] [--skip-operator-roles]
set -euo pipefail

RG="rg-dsa-demo"
LOCATION="eastus2"
RG_LOCATION=""
SKU="F1"
ALWAYS_READY="0"
WHAT_IF="false"
SKIP_PUBLISH="false"
SKIP_OPERATOR="false"
GRAPH_SITE_ID="${DSA_GRAPH_SITE_ID:-}"
GRAPH_LIST_ID="${DSA_GRAPH_LIST_ID:-}"
FLOW_URL="${DSA_FLOW_URL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -l|--location) LOCATION="$2"; shift 2 ;;
    -r|--resource-group-location) RG_LOCATION="$2"; shift 2 ;;
    -s|--iothub-sku) SKU="$2"; shift 2 ;;
    -a|--always-ready) ALWAYS_READY="$2"; shift 2 ;;
    --what-if) WHAT_IF="true"; shift ;;
    --skip-publish) SKIP_PUBLISH="true"; shift ;;
    --skip-operator-roles) SKIP_OPERATOR="true"; shift ;;
    *) echo "Argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
RG_LOCATION="${RG_LOCATION:-$LOCATION}"

case "$SKU" in F1|B1) ;; *) echo "iotHubSku debe ser F1 o B1" >&2; exit 2 ;; esac
case "$ALWAYS_READY" in 0|1) ;; *) echo "always ready debe ser 0 o 1" >&2; exit 2 ;; esac
if [[ "$FLOW_URL" == *"sig="* ]]; then echo "La URL del flujo no debe llevar firma SAS (sig=)" >&2; exit 2; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PROVIDERS=(Microsoft.Devices Microsoft.Web Microsoft.KeyVault Microsoft.Storage Microsoft.Insights
           Microsoft.OperationalInsights Microsoft.ManagedIdentity)
CONTRACTS=(schemas/evento-dispositivo.schema.json data/zonas.json sharepoint/columnas.json)

echo "Suscripción: $(az account show --query name --output tsv)"

for ns in "${PROVIDERS[@]}"; do
  state="$(az provider show --namespace "$ns" --query registrationState --output tsv)"
  if [[ "$state" != "Registered" ]]; then
    if [[ "$WHAT_IF" == "true" ]]; then echo "[what-if] Se registraría $ns"; continue; fi
    echo "Registrando $ns..."
    az provider register --namespace "$ns" --wait --output none
  fi
done

if [[ "$(az group exists --name "$RG")" != "true" ]]; then
  if [[ "$WHAT_IF" == "true" ]]; then
    echo "[what-if] Se crearía el grupo $RG en $RG_LOCATION; what-if de la plantilla necesita el grupo."
    exit 0
  fi
  az group create --name "$RG" --location "$RG_LOCATION" --output none
fi

OPERATOR_ID=""
if [[ "$SKIP_OPERATOR" != "true" ]]; then
  OPERATOR_ID="$(az ad signed-in-user show --query id --output tsv)"
fi

PARAMS=(--parameters "$SCRIPT_DIR/main.bicepparam"
        --parameters "location=$LOCATION" "iotHubSku=$SKU" "alwaysReadyCount=$ALWAYS_READY")
[[ -n "$OPERATOR_ID" ]] && PARAMS+=(--parameters "operatorPrincipalId=$OPERATOR_ID")
[[ -n "$GRAPH_SITE_ID" ]] && PARAMS+=(--parameters "graphSiteId=$GRAPH_SITE_ID")
[[ -n "$GRAPH_LIST_ID" ]] && PARAMS+=(--parameters "graphListId=$GRAPH_LIST_ID")
[[ -n "$FLOW_URL" ]] && PARAMS+=(--parameters "agentFlowUrl=$FLOW_URL")

if [[ "$WHAT_IF" == "true" ]]; then
  az deployment group what-if --resource-group "$RG" --name dsa-main \
    --template-file "$SCRIPT_DIR/main.bicep" "${PARAMS[@]}"
  exit 0
fi

az deployment group create --resource-group "$RG" --name dsa-main \
  --template-file "$SCRIPT_DIR/main.bicep" "${PARAMS[@]}" --output none

q() { az deployment group show --resource-group "$RG" --name dsa-main --query "properties.outputs.$1.value" --output tsv; }
FUNC_APP="$(q functionAppName)"
IOT_HUB="$(q iotHubName)"
CLIENT_ID="$(q identityClientId)"
OBJECT_ID="$(q identityPrincipalId)"

if [[ "$SKIP_PUBLISH" == "true" ]]; then
  echo "Publicación omitida (--skip-publish)."
elif [[ ! -f "$REPO_ROOT/function/function_app.py" ]]; then
  echo "Publicación omitida: todavía no existe function/function_app.py."
else
  mkdir -p "$REPO_ROOT/function/_contracts"
  for c in "${CONTRACTS[@]}"; do cp "$REPO_ROOT/$c" "$REPO_ROOT/function/_contracts/"; done
  ZIP="$(mktemp -d)/dsa-function.zip"
  (cd "$REPO_ROOT/function" && zip -qr "$ZIP" . -x '*__pycache__*' '*.pyc' '.venv/*' '.python_packages/*' \
      'tests/*' 'local.settings.json')
  echo "Publicando $FUNC_APP..."
  az functionapp deployment source config-zip --resource-group "$RG" --name "$FUNC_APP" \
    --src "$ZIP" --build-remote true --output none
  rm -f "$ZIP"
fi

cat <<EOF

Function App:        $FUNC_APP
IoT Hub:             $IOT_HUB
Identidad id-dsa-func
  client ID (appId): $CLIENT_ID   -> comando 2 de Sites.Selected
  object ID:         $OBJECT_ID   -> comando 1 y disparador de DisparoAgente

Comandos del administrador del tenant (docs/admin-sites-selected.md). Sustituye <siteId>:
# Sesión del administrador (SharePoint Administrator o superior, miembro del sitio de la demo):
Connect-MgGraph -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All','Sites.FullControl.All'

# Comando 1: asignar el rol de aplicación Sites.Selected de Microsoft Graph a la identidad administrada
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '$OBJECT_ID' -PrincipalId '$OBJECT_ID' -ResourceId (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id -AppRoleId '883ea226-0bf2-4a8f-9f9d-92c9162a727d'

# Comando 2: conceder write solo sobre el sitio de la demo (POST /sites/{siteId}/permissions)
New-MgSitePermission -SiteId '<siteId>' -BodyParameter @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = '$CLIENT_ID'; displayName = 'id-dsa-func' } }) }

Dispositivos: az iot hub device-identity create --hub-name $IOT_HUB --device-id sim-01 --auth-type login
EOF
