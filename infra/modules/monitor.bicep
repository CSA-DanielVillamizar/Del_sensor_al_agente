// Log Analytics con límite diario de ingesta y Application Insights sin autenticación local (ADR-007 §2).
// Límite diario: https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap

@description('Región de los recursos.')
param location string

@description('Nombre del área de trabajo de Log Analytics.')
param workspaceName string

@description('Nombre del recurso de Application Insights.')
param appInsightsName string

@description('Límite diario de ingesta en GB (protege el presupuesto, Art. 9).')
param dailyQuotaGb string = '0.05'

@description('Retención en días (30 días entran en la retención incluida).')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Principal ID de id-dsa-func (Monitoring Metrics Publisher).')
param functionPrincipalId string

@description('Etiquetas comunes.')
param tags object = {}

// Monitoring Metrics Publisher: https://learn.microsoft.com/azure/azure-functions/manage-connections#grant-permissions-to-an-identity
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: json(dailyQuotaGb)
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    IngestionMode: 'LogAnalytics'
  }
}

resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, functionPrincipalId, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output workspaceName string = workspace.name
output appInsightsName string = appInsights.name
output appInsightsId string = appInsights.id
// La cadena de conexión de Application Insights no se trata como secreto según Learn
// (https://learn.microsoft.com/azure/azure-monitor/app/connection-strings#is-the-connection-string-a-secret),
// pero no se expone como salida: el módulo de la Function la lee con una referencia al recurso existente.
