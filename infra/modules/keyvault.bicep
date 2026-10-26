// Key Vault con modelo RBAC. Solo guarda el secreto iothub-func-reader (ADR-005 §3).
// id-dsa-func recibe Key Vault Secrets User sobre este almacén y nada más.

@description('Región de los recursos.')
param location string

@description('Nombre del almacén (3-24 caracteres).')
@minLength(3)
@maxLength(24)
param name string

@description('Principal ID de id-dsa-func.')
param functionPrincipalId string

@description('Días de retención del borrado temporal (mínimo 7).')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 7

@description('Etiquetas comunes.')
param tags object = {}

// Key Vault Secrets User: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Sin protección de purga: infra/destroy purga el almacén para poder redesplegar con el mismo nombre.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, functionPrincipalId, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = vault.name
output id string = vault.id
