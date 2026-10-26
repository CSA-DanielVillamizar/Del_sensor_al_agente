// Identidad administrada asignada por el usuario de la Function (ADR-005 §1, ADR-007 §2).
// Se crea antes que la app para que los roles y la referencia de Key Vault estén listos en el primer arranque.

@description('Región de los recursos.')
param location string

@description('Nombre de la identidad. ADR-007 lo fija en id-dsa-func.')
param name string = 'id-dsa-func'

@description('Etiquetas comunes.')
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

// Identificadores públicos de la identidad, no son secretos.
output id string = identity.id
output name string = identity.name
output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
