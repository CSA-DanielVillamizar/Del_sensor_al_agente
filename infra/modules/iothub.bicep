// IoT Hub de la demo (CA-04.1, CA-04.4, ADR-005 §3).
// Política de acceso compartido: func-reader, solo ServiceConnect (nunca iothubowner).
// Con enableAnalyticsRoute (HU-15, DEC-IA-02) se agrega fabric-reader, también solo ServiceConnect,
// y el grupo de consumidores fabric, para que Fabric Eventstream lea sin tocar el de la Function.
// ServiceConnect no es de solo lectura: además de leer eventos permitiría enviar mensajes a los dispositivos
// e invocar métodos directos (https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-sas#iot-hub-permissions).
// Mitigación (T-058): simulator/ y device/ no implementan manejadores de mensajes de la nube, métodos ni gemelos;
// infra/tests/DsaInfra.Tests.ps1 falla si alguien los agrega.
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

@description('Ruta analítica de IA DAY (HU-15): grupo de consumidores fabric y política fabric-reader, solo ServiceConnect (lee eventos; también permitiría enviar mensajes a los dispositivos e invocar métodos). Apagada por defecto.')
param enableAnalyticsRoute bool = false

@description('Etiquetas comunes.')
param tags object = {}

// IoT Hub Registry Contributor: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/internet-of-things#iot-hub-registry-contributor
var iotHubRegistryContributorRoleId = '4ea46cd5-c1b2-4a8e-910b-273211f9ce47'

resource hub 'Microsoft.Devices/IotHubs@2023-06-30' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: 1
  }
  properties: {
    eventHubEndpoints: {
      events: {
        // F1 exige 2 particiones; 1 día de retención basta para la demo.
        partitionCount: 2
        retentionTimeInDays: 1
      }
    }
    // Lista completa de políticas del hub: func-reader y, solo con la ruta analítica, fabric-reader.
    // Ninguna tiene RegistryWrite ni DeviceConnect. La administración del registro se hace con
    // Entra ID (rol del operador), no con iothubowner.
    authorizationPolicies: concat([
      {
        keyName: 'func-reader'
        rights: 'ServiceConnect'
      }
    ], enableAnalyticsRoute ? [
      {
        keyName: 'fabric-reader'
        rights: 'ServiceConnect'
      }
    ] : [])
    // Los dispositivos se autentican con su clave simétrica propia (CA-01.4), así que la autenticación local sigue activa.
    disableLocalAuth: false
    // Sin rutas propias, la ruta de respaldo lleva los mensajes del dispositivo al endpoint integrado
    // que lee la Function. Si se omite, la plantilla la deja desactivada y los mensajes no llegan.
    routing: {
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
resource funcConsumerGroup 'Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups@2023-06-30' = {
  name: '${hub.name}/events/func'
  properties: {
    name: 'func'
  }
}

// Grupo de consumidores de la ruta analítica (HU-15, CA-15.3): Fabric Eventstream lee aquí y no
// compite con la Function por los mensajes.
resource fabricConsumerGroup 'Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups@2023-06-30' = if (enableAnalyticsRoute) {
  name: '${hub.name}/events/fabric'
  properties: {
    name: 'fabric'
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
