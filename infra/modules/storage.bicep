// Cuenta de almacenamiento del host, del paquete de despliegue y de las tablas dedup y ratelimit (ADR-006).
// Sin claves: allowSharedKeyAccess = false; todo el acceso es con Entra ID (Art. 4).

@description('Región de los recursos.')
param location string

@description('Nombre de la cuenta (3-24 caracteres, minúsculas y números).')
@minLength(3)
@maxLength(24)
param name string

@description('Contenedor del paquete de la Function (Flex Consumption).')
param deploymentContainerName string = 'deploymentpackage'

@description('Principal ID de id-dsa-func.')
param functionPrincipalId string

@description('Object ID del operador para demo/reset (Storage Table Data Contributor). Vacío = no se asigna.')
param operatorPrincipalId string = ''

@description('Etiquetas comunes.')
param tags object = {}

// Roles integrados: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }

  resource blobServices 'blobServices' = {
    name: 'default'
    resource deploymentContainer 'containers' = {
      name: deploymentContainerName
      properties: {
        publicAccess: 'None'
      }
    }
  }

  resource tableServices 'tableServices' = {
    name: 'default'
    resource dedup 'tables' = {
      name: 'dedup'
    }
    resource ratelimit 'tables' = {
      name: 'ratelimit'
    }
  }
}

resource blobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionPrincipalId, storageBlobDataOwnerRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource tableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionPrincipalId, storageTableDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(storage.id, operatorPrincipalId, storageTableDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: operatorPrincipalId
    principalType: 'User'
  }
}

output name string = storage.name
output id string = storage.id
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output tableEndpoint string = storage.properties.primaryEndpoints.table
output deploymentContainerUrl string = '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
