// Compone la cadena compatible con Event Hubs de la política func-reader y la guarda en Key Vault
// como secreto iothub-func-reader (ADR-005 §3, CA-04.4). La clave nunca sale del despliegue:
// este módulo no tiene salidas con valores sensibles.
// También lo usa infra/rotate-iothub-key.ps1 para reescribir el secreto tras renovar la clave,
// de modo que la clave nunca pasa por la consola del operador.

@description('Nombre del IoT Hub existente.')
param iotHubName string

@description('Nombre del Key Vault existente.')
param keyVaultName string

@description('Nombre de la política dedicada.')
param policyName string = 'func-reader'

@description('Nombre del secreto.')
param secretName string = 'iothub-func-reader'

@description('Qué clave de la política se usa: primary o secondary (la rotación alterna entre ambas).')
@allowed([
  'primary'
  'secondary'
])
param keySlot string = 'primary'

resource hub 'Microsoft.Devices/IotHubs@2023-06-30' existing = {
  name: iotHubName
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Si la política no existe, el índice falla y el despliegue se detiene: es el comportamiento deseado.
var policy = filter(hub.listkeys().value, p => p.keyName == policyName)[0]
var events = hub.properties.eventHubEndpoints.events

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: secretName
  properties: {
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
    value: 'Endpoint=${events.endpoint};SharedAccessKeyName=${policyName};SharedAccessKey=${keySlot == 'primary' ? policy.primaryKey : policy.secondaryKey};EntityPath=${events.path}'
  }
}

// Solo el nombre del secreto, nunca su valor ni su URI con versión.
output secretName string = secret.name
