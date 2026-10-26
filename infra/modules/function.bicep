// Function App en Flex Consumption (ADR-005 §1 y §2, CA-04.1, CA-04.4).
// Linux, Python 3.11, 512 MB, máximo 1 instancia, always ready por parámetro.
// Plantilla de referencia: https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code?pivots=flex-consumption-plan

@description('Región de los recursos.')
param location string

@description('Nombre de la Function App.')
param name string

@description('Nombre del plan Flex Consumption.')
param planName string

@description('Resource ID de id-dsa-func.')
param identityId string

@description('Client ID de id-dsa-func.')
param identityClientId string

@description('Nombre de la cuenta de almacenamiento del host.')
param storageAccountName string

@description('URL del contenedor del paquete de despliegue.')
param deploymentContainerUrl string

@description('Endpoint de tablas (dedup, ratelimit).')
param tableEndpoint string

@description('Nombre de Application Insights.')
param appInsightsName string

@description('Nombre del Key Vault con el secreto de IoT Hub.')
param keyVaultName string

@description('Nombre del secreto con la cadena de func-reader.')
param iotHubSecretName string

@description('Memoria por instancia en MB (ADR-005: 512).')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 512

@description('Máximo de instancias bajo demanda (ADR-005: 1). Las always ready no cuentan.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 1

@description('Instancias always ready para function:ingest_event (0 reposo, 1 ensayo o sesión).')
@minValue(0)
@maxValue(1)
param alwaysReadyCount int = 0

@description('Nombre de la función con disparador de IoT Hub (grupo de escalado function:<nombre>).')
param functionName string = 'ingest_event'

@description('Máximo de incidentes creados por minuto (CA-12.1).')
@minValue(1)
param maxIncidentsPerMinute int = 10

@description('ID del sitio de SharePoint de la demo para Graph ({hostname},{siteCollectionId},{webId}). Vacío hasta T-024.')
param graphSiteId string = ''

@description('ID de la lista Eventos de seguridad. Vacío hasta T-029.')
param graphListId string = ''

@description('URL del disparador HTTP del flujo DisparoAgente (autenticación Entra ID, sin firma SAS). Vacía hasta T-035.')
param agentFlowUrl string = ''

@description('Etiquetas comunes.')
param tags object = {}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

// Sin secretos en la configuración: el almacenamiento y Application Insights usan la identidad;
// la única cadena (IoT Hub) es una referencia a Key Vault.
var appSettings = [
  { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'AzureWebJobsStorage__clientId', value: identityClientId }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'ClientId=${identityClientId};Authorization=AAD' }
  { name: 'IoTHubConnection', value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${iotHubSecretName})' }
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
  { name: 'DSA_TABLE_ENDPOINT', value: tableEndpoint }
  { name: 'DSA_MAX_INCIDENTS_PER_MINUTE', value: string(maxIncidentsPerMinute) }
  { name: 'DSA_GRAPH_SITE_ID', value: graphSiteId }
  { name: 'DSA_GRAPH_LIST_ID', value: graphListId }
  { name: 'DSA_FLOW_URL', value: agentFlowUrl }
]

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Las referencias de Key Vault se resuelven con id-dsa-func, no con una identidad del sistema.
    keyVaultReferenceIdentity: identityId
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: appSettings
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentContainerUrl
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identityId
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
        alwaysReady: alwaysReadyCount > 0
          ? [
              {
                name: 'function:${functionName}'
                instanceCount: alwaysReadyCount
              }
            ]
          : []
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
  }
}

// Desactiva la publicación con credenciales básicas (FTP y SCM); el despliegue usa Entra ID.
resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

output name string = app.name
output id string = app.id
output defaultHostName string = app.properties.defaultHostName
