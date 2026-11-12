// IoT Hub de la demo (CA-04.1, CA-04.4, ADR-005 §3).
// Única política de acceso compartido: func-reader, solo ServiceConnect (nunca iothubowner).
// Ruta analítica de IA DAY (HU-15, DEC-IA-02 v2): con enableAnalyticsRoute y los datos del Eventstream,
// el hub reenvía los mensajes a Microsoft Fabric con su identidad administrada asignada por el sistema.
// Ese endpoint solo admite Microsoft Entra ID, así que no hay ninguna clave que manejar
// (https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-endpoints#custom-endpoints-for-message-routing).
// Al existir rutas propias, la ruta to-func lleva explícitamente todos los mensajes al endpoint integrado
// que lee la Function; así la Function sigue recibiendo todo.
// API 2026-05-01-preview: la primera con endpoints eventStreams que el Bicep local valida; la estable
// 2026-11-01 también los tiene y se puede usar al actualizar Bicep (az bicep upgrade).
// Este módulo no tiene ninguna salida con claves.

@description('Región de los recursos.')
param location string

@description('Nombre del hub (globalmente único).')
param name string

@description('SKU del hub. F1 es gratis (uno por suscripción); B1 si la suscripción ya tiene un hub F1.')
@allowed([
  'F1'
  'B1'
])
param sku string = 'F1'

@description('Object ID del operador: recibe IoT Hub Registry Contributor para crear los dispositivos con --auth-type login. Vacío = no se asigna.')
param operatorPrincipalId string = ''

@description('Ruta analítica de IA DAY (HU-15): identidad administrada del hub y ruta hacia Fabric Eventstream, sin claves. Apagada por defecto.')
param enableAnalyticsRoute bool = false

@description('Datos del punto de conexión personalizado del Eventstream (analytics/fabric-setup.ps1). Sin secretos.')
param fabricEventstream object = {
  endpointUri: ''
  entityPath: ''
  workspaceId: ''
  eventStreamId: ''
  sourceId: ''
}

@description('Etiquetas comunes.')
param tags object = {}

// IoT Hub Registry Contributor: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/internet-of-things#iot-hub-registry-contributor
var iotHubRegistryContributorRoleId = '4ea46cd5-c1b2-4a8e-910b-273211f9ce47'

var fabricRouteOn = enableAnalyticsRoute && !empty(fabricEventstream.endpointUri)
var fabricEndpointName = 'fabric-eventstream'

resource hub 'Microsoft.Devices/IotHubs@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: 1
  }
  // La identidad del hub solo existe con la ruta analítica: es la que se autentica ante Fabric.
  identity: {
    type: enableAnalyticsRoute ? 'SystemAssigned' : 'None'
  }
  properties: {
    eventHubEndpoints: {
      events: {
        // F1 exige 2 particiones; 1 día de retención basta para la demo.
        partitionCount: 2
        retentionTimeInDays: 1
      }
    }
    // Lista completa de políticas del hub: solo func-reader. La administración del registro
    // se hace con Entra ID (rol del operador), no con iothubowner.
    authorizationPolicies: [
      {
        keyName: 'func-reader'
        rights: 'ServiceConnect'
      }
    ]
    // Los dispositivos se autentican con su clave simétrica propia (CA-01.4), así que la autenticación local sigue activa.
    disableLocalAuth: false
    routing: {
      endpoints: fabricRouteOn
        ? {
            eventStreams: [
              {
                name: fabricEndpointName
                authenticationType: 'identityBased'
                endpointUri: fabricEventstream.endpointUri
                entityPath: fabricEventstream.entityPath
                workspaceId: fabricEventstream.workspaceId
                eventStreamId: fabricEventstream.eventStreamId
                sourceId: fabricEventstream.sourceId
              }
            ]
          }
        : {}
      routes: fabricRouteOn
        ? [
            {
              name: 'to-func'
              source: 'DeviceMessages'
              condition: 'true'
              endpointNames: [
                'events'
              ]
              isEnabled: true
            }
            {
              name: 'to-fabric'
              source: 'DeviceMessages'
              condition: 'true'
              endpointNames: [
                fabricEndpointName
              ]
              isEnabled: true
            }
          ]
        : []
      // Sin rutas propias, la ruta de respaldo lleva los mensajes del dispositivo al endpoint integrado
      // que lee la Function. Si se omite, la plantilla la deja desactivada y los mensajes no llegan.
      fallbackRoute: {
        name: '$fallback'
        source: 'DeviceMessages'
        condition: 'true'
        endpointNames: [
          'events'
        ]
        isEnabled: true
      }
    }
  }
}

// Grupo de consumidores dedicado de la Function (ADR-004 §1): function/function_app.py usa consumer_group="func".
resource funcConsumerGroup 'Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups@2026-05-01-preview' = {
  name: '${hub.name}/events/func'
  properties: {
    name: 'func'
  }
}

resource operatorRegistry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(hub.id, operatorPrincipalId, iotHubRegistryContributorRoleId)
  scope: hub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', iotHubRegistryContributorRoleId)
    principalId: operatorPrincipalId
    principalType: 'User'
  }
}

output name string = hub.name
output id string = hub.id
output hostName string = hub.properties.hostName
@description('Object ID de la identidad del hub (vacío sin ruta analítica): recibe Colaborador en el área de trabajo de Fabric.')
output principalId string = enableAnalyticsRoute ? hub.identity.principalId : ''
