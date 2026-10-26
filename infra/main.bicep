// Infraestructura de Azure de "Del sensor al agente" (HU-04, HU-12).
// Ámbito: grupo de recursos. Región de los recursos por parámetro (por defecto eastus2),
// independiente de la región del grupo. Sin secretos en parámetros ni en salidas (CA-04.4).
// Decisiones: ADR-005 (hosting), ADR-006 (tablas), ADR-007 (identidad y permisos).

targetScope = 'resourceGroup'

@description('Región de los recursos (CA-04.1). Puede diferir de la región del grupo de recursos.')
param location string = 'eastus2'

@description('Prefijo corto de los nombres.')
@minLength(2)
@maxLength(6)
param namePrefix string = 'dsa'

@description('SKU de IoT Hub: F1 (gratis) o B1 si la suscripción ya tiene un hub F1 (CA-04.1).')
@allowed([
  'F1'
  'B1'
])
param iotHubSku string = 'F1'

@description('Memoria por instancia de la Function en MB (ADR-005).')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 512

@description('Máximo de instancias bajo demanda (ADR-005).')
@minValue(1)
param maximumInstanceCount int = 1

@description('Instancias always ready de function:ingest_event: 0 reposo, 1 ensayo o sesión (ADR-005 §2).')
@minValue(0)
@maxValue(1)
param alwaysReadyCount int = 0

@description('Máximo de incidentes creados por minuto (CA-12.1).')
@minValue(1)
param maxIncidentsPerMinute int = 10

@description('Object ID del operador (Daniel). Lo pasa infra/deploy desde la sesión de az; nunca se versiona. Vacío = sin roles de operador.')
param operatorPrincipalId string = ''

@description('Clave de func-reader que usa el secreto: primary o secondary (rotación, ADR-005 §3).')
@allowed([
  'primary'
  'secondary'
])
param iotHubKeySlot string = 'primary'

@description('ID del sitio de SharePoint de la demo para Graph. Vacío hasta T-024.')
param graphSiteId string = ''

@description('ID de la lista Eventos de seguridad. Vacío hasta T-029.')
param graphListId string = ''

@description('URL del disparador HTTP de DisparoAgente (OAuth de Entra ID, sin SAS). Vacía hasta T-035.')
param agentFlowUrl string = ''

@description('Monto del presupuesto mensual en USD (Art. 9).')
param budgetAmount int = 20

@description('Porcentaje del aviso de presupuesto (CA-12.2).')
param budgetThresholdPercent int = 80

@description('Límite diario de ingesta de Log Analytics en GB.')
param logDailyQuotaGb string = '0.05'

var token = uniqueString(resourceGroup().id, namePrefix)
var tags = {
  proyecto: 'del-sensor-al-agente'
  entorno: 'demo'
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    name: 'id-${namePrefix}-func'
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    name: take('st${namePrefix}${token}', 24)
    functionPrincipalId: identity.outputs.principalId
    operatorPrincipalId: operatorPrincipalId
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    name: take('kv-${namePrefix}-${token}', 24)
    functionPrincipalId: identity.outputs.principalId
    tags: tags
  }
}

module monitor 'modules/monitor.bicep' = {
  name: 'monitor'
  params: {
    location: location
    workspaceName: 'log-${namePrefix}-${token}'
    appInsightsName: 'appi-${namePrefix}-${token}'
    dailyQuotaGb: logDailyQuotaGb
    functionPrincipalId: identity.outputs.principalId
    tags: tags
  }
}

module iotHub 'modules/iothub.bicep' = {
  name: 'iothub'
  params: {
    location: location
    name: 'iot-${namePrefix}-${token}'
    sku: iotHubSku
    operatorPrincipalId: operatorPrincipalId
    tags: tags
  }
}

module iotHubSecret 'modules/iothub-secret.bicep' = {
  name: 'iothub-secret'
  params: {
    iotHubName: iotHub.outputs.name
    keyVaultName: keyVault.outputs.name
    keySlot: iotHubKeySlot
  }
}

module functionApp 'modules/function.bicep' = {
  name: 'function'
  params: {
    location: location
    name: 'func-${namePrefix}-${token}'
    planName: 'asp-${namePrefix}-${token}'
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    storageAccountName: storage.outputs.name
    deploymentContainerUrl: storage.outputs.deploymentContainerUrl
    tableEndpoint: storage.outputs.tableEndpoint
    appInsightsName: monitor.outputs.appInsightsName
    keyVaultName: keyVault.outputs.name
    iotHubSecretName: iotHubSecret.outputs.secretName
    instanceMemoryMB: instanceMemoryMB
    maximumInstanceCount: maximumInstanceCount
    alwaysReadyCount: alwaysReadyCount
    maxIncidentsPerMinute: maxIncidentsPerMinute
    graphSiteId: graphSiteId
    graphListId: graphListId
    agentFlowUrl: agentFlowUrl
    tags: tags
  }
}

module budget 'modules/budget.bicep' = {
  name: 'budget'
  params: {
    amount: budgetAmount
    thresholdPercent: budgetThresholdPercent
    tags: tags
  }
}

// Salidas: solo nombres e identificadores públicos. Ninguna clave, cadena de conexión ni URI de secreto.
output functionAppName string = functionApp.outputs.name
output iotHubName string = iotHub.outputs.name
output keyVaultName string = keyVault.outputs.name
output storageAccountName string = storage.outputs.name
output appInsightsName string = monitor.outputs.appInsightsName
output identityName string = identity.outputs.name
output identityClientId string = identity.outputs.clientId
output identityPrincipalId string = identity.outputs.principalId
output budgetName string = budget.outputs.name
