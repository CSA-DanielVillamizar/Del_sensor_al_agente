# Costos de Azure de la demo

| Campo | Valor |
| --- | --- |
| Tarea | T-022 (HU-04, CA-04.5; HU-12, CA-12.2; Art. 9; OBJ-5) |
| Fecha de los precios | 2026-10-26, [API de precios minoristas de Azure](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), región `eastus2`, USD, precio de lista sin descuentos |
| Plantilla | `infra/main.bicep` con `infra/main.bicepparam` |
| Decisiones | [ADR-005](adr/ADR-005-hosting-function.md) (hosting y *always ready*), [ADR-006](adr/ADR-006-deduplicacion.md) (Table Storage) |

Los Copilot Credits y las licencias de Microsoft 365 no entran en estos USD 20: tienen su propio presupuesto ([ADR-001](adr/ADR-001-facturacion-creditos-copilot-studio.md), CA-12.4).

**Resultado:** un mes normal de la demo cuesta **≈ USD 0,40**. El peor caso razonable, *always ready* olvidado todo el mes con IoT Hub `B1`, cuesta **≈ USD 17,90**. Ambos quedan por debajo de USD 20, y el aviso de presupuesto al 80 % (USD 16) llega antes de pasar el límite.

## 1. Precios unitarios usados

| Recurso | Medidor | Precio | Gratis | Fuente |
| --- | --- | --- | --- | --- |
| IoT Hub `F1` | Free Unit | USD 0 | 8 000 mensajes/día, un hub `F1` por suscripción | [Precios de IoT Hub](https://azure.microsoft.com/pricing/details/iot-hub/), [IoT Hub quotas and throttling](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-quotas-throttling) |
| IoT Hub `B1` | B1 Unit | USD 10 por unidad al mes | — | [Precios de IoT Hub](https://azure.microsoft.com/pricing/details/iot-hub/) |
| Functions Flex Consumption | Always Ready Baseline | USD 0,000004 por GB-s | — | [Precios de Azure Functions](https://azure.microsoft.com/pricing/details/functions/), [Billing](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#billing) |
| | Always Ready Execution Time | USD 0,000016 por GB-s | — | Ídem |
| | On Demand Execution Time | USD 0,000026 por GB-s | 100 000 GB-s al mes | Ídem |
| | On Demand Total Executions | USD 0,40 por millón | 250 000 al mes | Ídem |
| Storage Standard LRS, tablas | Operaciones | USD 0,00036 por 10 000 | — | [Precios de Table Storage](https://azure.microsoft.com/pricing/details/storage/tables/) |
| Storage Standard LRS, blob Hot | Escritura y listado / otras | USD 0,05 / USD 0,004 por 10 000 | — | [Precios de Blob Storage](https://azure.microsoft.com/pricing/details/storage/blobs/) |
| | Datos almacenados | USD 0,0184 por GB al mes | — | Ídem |
| Key Vault Standard | Operaciones con secretos | USD 0,03 por 10 000 | — | [Precios de Key Vault](https://azure.microsoft.com/pricing/details/key-vault/) |
| Log Analytics | Ingesta, Analytics Logs | USD 2,76 por GB | 5 GB por cuenta de facturación al mes | [Precios de Azure Monitor](https://azure.microsoft.com/pricing/details/monitor/) |
| Grupo de acciones (aviso por rol de ARM) | Correo | — | 1 000 correos al mes | [Precios de Azure Monitor](https://azure.microsoft.com/pricing/details/monitor/) |
| Presupuesto de Cost Management | — | USD 0 | — | [Tutorial: Create and manage budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets) |

Línea base de *always ready* con 512 MB: 0,5 GB × 3 600 s × USD 0,000004 = **USD 0,0072 por hora**.

## 2. Supuestos de uso

| Supuesto | Valor |
| --- | --- |
| Eventos por mes | 2 000 (10 ensayos con ráfagas de 20, pruebas de carga de R-15, preflight y sesión). Cada uno es una ejecución de ~1 s con 512 MB = 0,5 GB-s |
| Operaciones de Table por evento | 2 a 4 (ADR-006) → < 10 000 al mes |
| Paquete de la Function | < 100 MB en el contenedor `deploymentpackage` |
| Key Vault | Una lectura por reinicio de la app y cada 24 h ([Understand rotation](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#understand-rotation)) → < 500 al mes |
| Ingesta de registros | < 0,5 GB al mes con el volumen de la demo; tope duro de **0,05 GB por día** (`logDailyQuotaGb`, [Daily cap](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap)) = 1,55 GB al mes como máximo |
| Horas con *always ready* = 1 | Ensayos: 10 × 2 h = 20 h. Sesión: 2 × 4 h = 8 h (ADR-005 §2) |
| Almacenamiento con una instancia activa | Estimación propia, **no verificada en Learn**: el disparador de Event Hubs equilibra particiones y renueva su propiedad en blobs del host cada ~10 s; con 2 particiones, del orden de 500 000 operaciones de blob al mes si la instancia queda encendida todo el mes. Se toma el precio más alto (USD 0,05 por 10 000) → hasta USD 2,60 al mes, proporcional a las horas encendida |

## 3. Escenarios

Valores mensuales en USD. Los centavos se redondean hacia arriba.

| Concepto | Reposo | Ensayos (20 h) | Sesión (8 h) | Mes normal = reposo + ensayos + sesión | Olvido (730 h) |
| --- | --- | --- | --- | --- | --- |
| IoT Hub `F1` | 0,00 | 0,00 | 0,00 | 0,00 | 0,00 |
| Function, línea base *always ready* | 0,00 | 0,15 | 0,06 | 0,21 | 5,26 |
| Function, ejecuciones (dentro de la concesión gratuita o a USD 0,000016 por GB-s) | 0,00 | 0,01 | 0,01 | 0,02 | 0,02 |
| Storage: blobs del host con la instancia encendida (estimación) | 0,00 | 0,08 | 0,03 | 0,11 | 2,60 |
| Storage: tablas y paquete | 0,01 | 0,01 | 0,01 | 0,01 | 0,01 |
| Key Vault | 0,01 | 0,01 | 0,01 | 0,01 | 0,01 |
| Log Analytics (< 0,5 GB; dentro de los 5 GB gratis, o a lo sumo USD 1,38 si la cuenta ya los gastó) | 0,00 | 0,00 | 0,00 | 0,00 | 0,00 |
| Presupuesto y grupo de acciones | 0,00 | 0,00 | 0,00 | 0,00 | 0,00 |
| **Total con `F1`** | **0,02** | **0,26** | **0,12** | **≈ 0,40** | **≈ 7,90** |
| **Total con `B1`** (+ USD 10) | 10,02 | — | — | **≈ 10,40** | **≈ 17,90** |

### Caso de esfuerzo: todo mal a la vez

Si además la ingesta llegara al tope diario todos los días (1,55 GB) y la cuenta de facturación ya hubiera gastado sus 5 GB gratis: + USD 4,28.

| Combinación | Total |
| --- | --- |
| `F1` + olvido + tope de registros pagado | ≈ USD 12,20 |
| `B1` + olvido + tope de registros pagado | **≈ USD 22,20 — supera los USD 20** |

Esa combinación exige tres fallas simultáneas y no se espera. Si ocurre, la detectan antes del límite:

1. El **aviso de presupuesto al 80 %** (USD 16) al rol *Owner* del grupo de recursos (CA-12.2, `infra/modules/budget.bicep`).
2. `demo/preflight`, que muestra en amarillo *always ready* = 1 fuera de una ventana de ensayo o sesión (ADR-005 §2).
3. `infra/set-always-ready.ps1 -Scenario reposo` lo apaga en segundos sin redesplegar.

Bajar `logDailyQuotaGb` a 0,02 deja incluso esa combinación en ≈ USD 19,60, pero corre el riesgo de cortar la telemetría de un ensayo y con ella la medición del tramo 1. Se prefiere 0,05.

## 4. Caso `B1`

La suscripción solo admite un IoT Hub `F1` ([IoT Hub quotas and throttling](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-quotas-throttling)). Si ya existe uno, se despliega con `./infra/deploy.ps1 -IotHubSku B1`. `B1` cubre lo que usa la demo (telemetría dispositivo-nube, identidad por dispositivo, endpoint integrado, [Choose the right IoT Hub tier](https://learn.microsoft.com/azure/iot-hub/iot-hub-scaling#choose-your-features-basic-and-standard-tiers)) y suma USD 10 fijos al mes. Antes de desplegar con `B1`, vuelve a consultar la [página de precios](https://azure.microsoft.com/pricing/details/iot-hub/).

## 5. Alternativa de producción no incluida

Enrutar IoT Hub a un Event Hubs propio y leerlo con identidad administrada (deuda de ADR-005 §3) sumaría una unidad de procesamiento Basic: USD 0,015 por hora ≈ **USD 10,95 al mes** ([Precios de Event Hubs](https://azure.microsoft.com/pricing/details/event-hubs/)). Con `F1` cabría (≈ USD 11,35 en un mes normal); con `B1` el mes normal pasaría a ≈ USD 21,35 y rompería el presupuesto. Por eso queda para la guía de producción.

## 6. Controles de costo en la plantilla

| Control | Dónde | Valor |
| --- | --- | --- |
| Memoria por instancia | `instanceMemoryMB` | 512 MB (con 2 048 MB el olvido costaría USD 21,02 solo en línea base, ADR-005) |
| Máximo de instancias bajo demanda | `maximumInstanceCount` | 1 |
| *Always ready* por defecto | `alwaysReadyCount` | 0; se cambia por escenario con `infra/set-always-ready.ps1` |
| Límite de incidentes | `DSA_MAX_INCIDENTS_PER_MINUTE` | 10 por minuto (CA-12.1) |
| Ingesta de registros | `logDailyQuotaGb` | 0,05 GB por día |
| Presupuesto | `budgetAmount`, `budgetThresholdPercent` | USD 20, aviso al 80 % al rol *Owner* |
| Eliminación | `infra/destroy.ps1` / `infra/destroy.sh` | Borra el grupo completo (Art. 9) |

## 7. Cómo recalcular

1. Consulta los precios vigentes de `eastus2` en la API de precios minoristas, por ejemplo con el filtro `serviceName eq 'Functions' and armRegionName eq 'eastus2'`.
2. Revisa el gasto real en **Cost Management → Análisis de costos**, con alcance en `rg-dsa-demo`.
3. Si cambias `instanceMemoryMB`, multiplica la línea base por la nueva memoria en GB: 2 048 MB = USD 0,0288 por hora.
