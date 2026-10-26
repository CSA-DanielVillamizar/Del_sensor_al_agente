// Parámetros versionados de la demo. Sin secretos ni identificadores reales (CA-04.4, Art. 4).
// operatorPrincipalId, graphSiteId, graphListId y agentFlowUrl los pasa infra/deploy en la línea de comandos.
using 'main.bicep'

param location = 'eastus2'
param namePrefix = 'dsa'
param iotHubSku = 'F1'
param instanceMemoryMB = 512
param maximumInstanceCount = 1
param alwaysReadyCount = 0
param maxIncidentsPerMinute = 10
param budgetAmount = 20
param budgetThresholdPercent = 80
param logDailyQuotaGb = '0.05'
