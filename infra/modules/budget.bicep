// Presupuesto mensual del grupo de recursos: alerta al 80 % de USD 20 (CA-12.2, Art. 9).
// Avisa al rol Owner del grupo sin escribir ningún correo en el repositorio (plan §7 y §13):
// contactRoles = Owner y, como respaldo, un grupo de acciones con un receptor de rol de ARM (Owner).
// Learn pide al menos un correo o un grupo de acciones en el ámbito de grupo de recursos
// (https://learn.microsoft.com/azure/templates/microsoft.consumption/budgets#notification), por eso existe el grupo.

@description('Nombre del presupuesto.')
param name string = 'budget-dsa-demo'

@description('Nombre del grupo de acciones.')
param actionGroupName string = 'ag-dsa-budget'

@description('Monto mensual en la moneda de facturación (USD).')
param amount int = 20

@description('Porcentaje que dispara el aviso.')
@minValue(1)
@maxValue(1000)
param thresholdPercent int = 80

@description('Primer día del mes de inicio (yyyy-MM-01). Por defecto, el mes en curso.')
param startDate string = '${utcNow('yyyy-MM')}-01'

@description('Etiquetas comunes.')
param tags object = {}

// Owner: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged#owner
var ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    groupShortName: 'dsabudget'
    armRoleReceivers: [
      {
        name: 'owner-del-grupo'
        roleId: ownerRoleId
        useCommonAlertSchema: true
      }
    ]
  }
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: thresholdPercent
        thresholdType: 'Actual'
        contactEmails: []
        contactRoles: [
          'Owner'
        ]
        contactGroups: [
          actionGroup.id
        ]
        locale: 'es-es'
      }
    }
  }
}

output name string = budget.name
