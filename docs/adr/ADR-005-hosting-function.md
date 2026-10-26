# ADR-005 — Hosting de la Function: Flex Consumption, instancias *always ready* por escenario y conexión a IoT Hub (DEC-03)

| Campo | Valor |
| --- | --- |
| Estado | Aceptado ("aprobado fase 2" de Daniel, 2026-10-26) |
| Fecha | 2026-10-09 |
| Decisión relacionada | DEC-03 en `specs/01-especificacion.md` §7 |
| Historias | HU-04 (CA-04.1, CA-04.4, CA-04.5), HU-05 (CA-05.5), RNF-01, R-06 |
| Responsables | arquitecto-cloud; revisión: revisor-seguridad |

## Contexto

- CA-04.1 fija Flex Consumption, Python 3.11 y región `eastus2`. Flex Consumption es Linux, admite Python 3.10 a 3.14, escala a cero y ofrece instancias *always ready* opcionales para reducir el arranque en frío ([Flex Consumption plan hosting](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)).
- Tamaños de instancia: 512 MB (0,25 núcleos), 2 048 MB (1 núcleo) y 4 096 MB (2 núcleos); se puede cambiar en cualquier momento ([Instance sizes](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#instance-sizes)).
- *Always ready* se asigna por grupo de escalado o por función. Las funciones que no son HTTP, Blob ni Durable escalan por separado con el nombre `function:<nombre>`; el valor por defecto es 0 ([Per-function scaling](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#per-function-scaling), [Always ready instances](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#always-ready-instances), [Set always ready instance counts](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#set-always-ready-instance-counts)).
- Facturación: en modo *on demand* solo se paga la memoria mientras se ejecuta, con concesión gratuita mensual; con *always ready* se paga además una **línea base** por la memoria de esas instancias todo el tiempo que estén asignadas, sin concesión gratuita. La ejecución mínima facturable es 1 000 ms ([Billing](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#billing), [precios de Azure Functions](https://azure.microsoft.com/pricing/details/functions/)).
- El número máximo de instancias más bajo admitido es 1 ([Considerations](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#considerations)).
- **El disparador de IoT Hub no admite conexiones basadas en identidad.** Learn propone dos caminos: guardar la cadena de conexión en Key Vault y usar una referencia, o enrutar a un Event Hubs propio y leerlo con identidad administrada ([IoT Hub trigger — Connections](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#connections), [Manage connections — Bindings](https://learn.microsoft.com/azure/azure-functions/manage-connections#define-connections)). El endpoint integrado de IoT Hub solo se lee con clave de acceso compartido, no con Entra ID ([Control access to IoT Hub by using Microsoft Entra ID](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-azure-ad#permissions-for-iot-hub-service-apis)).
- Las referencias de Key Vault usan la identidad asignada por el sistema salvo que se indique `keyVaultReferenceIdentity`; se recomienda una identidad asignada por el usuario cuando la aplicación necesita leer el secreto al crearse ([Key Vault references](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#access-vaults-with-a-user-assigned-identity)). El valor se cachea y se vuelve a leer cada 24 horas o al reiniciar la app ([Understand rotation](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#understand-rotation)).
- Flex Consumption admite identidad administrada completa para el almacenamiento del host (`AzureWebJobsStorage__*`) y no usa Azure Files ([Manage connections — Host required](https://learn.microsoft.com/azure/azure-functions/manage-connections#define-connections)).

## Decisión

### 1. Plan y tamaño

| Parámetro | Valor | Motivo |
| --- | --- | --- |
| Plan | Flex Consumption (`FC1`), Linux, Python 3.11, modelo v2 | CA-04.1, RNF-02 |
| Memoria por instancia | **512 MB** (parámetro `instanceMemoryMB`) | La Function es de E/S (Table, Graph, HTTP). Con 512 MB la línea base de *always ready* cuesta la cuarta parte que con 2 048 MB (tabla de costos). Si las pruebas de carga del tramo 1 muestran problemas de memoria o CPU, se sube a 2 048 MB y se recalcula el costo |
| Máximo de instancias | **1** (parámetro `maximumInstanceCount`) | Una demo con un dispositivo no necesita más; acota el costo y reduce la concurrencia. Las instancias *always ready* no cuentan para este máximo ([Maximum instance count](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#maximum-instance-count-the-ceiling)) |
| Almacenamiento del host | `AzureWebJobsStorage__accountName` + `__credential=managedidentity` + `__clientId`, sin claves (`allowSharedKeyAccess: false`) | Sin secretos (Art. 4) |
| Identidad | **Asignada por el usuario** `id-dsa-func`, la misma para host, Key Vault, Table, Graph y el flujo (ADR-007) | Existe antes que la app, así que los roles y la referencia de Key Vault están listos en el primer arranque |

### 2. Instancias *always ready* por escenario

Se configuran sobre `function:ingest_event` con un parámetro de Bicep (`alwaysReadyCount`) y un script de cambio rápido, `infra/set-always-ready.ps1 -Scenario <reposo|ensayo|sesion>`, que no requiere redesplegar.

| Escenario | Instancias | Cuándo | Horas al mes (supuesto) | Costo de línea base* |
| --- | --- | --- | --- | --- |
| Reposo | 0 | Todo el tiempo fuera de ensayos y sesión | — | USD 0 |
| Ensayo | 1 | Desde 15 min antes hasta el final de cada ensayo | 10 ensayos × 2 h = 20 h | USD 0,14 |
| Sesión | 1 | Del ensayo general al final del evento: 2 h antes hasta 1 h después de la sesión, más el ensayo general | 2 × 4 h = 8 h | USD 0,06 |
| Olvido (peor caso) | 1 | Encendida todo el mes por error | 730 h | **USD 5,26** con 512 MB; USD 21,02 con 2 048 MB |

\* Medidor *Always Ready Baseline* en `eastus2`: USD 0,000004 por GB-s, según la [página de precios](https://azure.microsoft.com/pricing/details/functions/) consultada el 2026-10-09 con la API de precios minoristas de Azure. 512 MB = 0,5 GB → USD 0,0072 por hora.

Controles: `demo/preflight` muestra el valor actual (amarillo si es 1 fuera de una ventana de ensayo o sesión); `demo/reset` no lo cambia; la alerta de presupuesto al 80 % (CA-12.2) cubre el peor caso. **El olvido con 2 048 MB rompería el presupuesto**: por eso 512 MB es parte de la decisión, no un detalle.

### 3. Conexión del disparador con IoT Hub

Como el disparador de IoT Hub **no admite identidad**, se usa la opción que Learn da para ese caso y que CA-04.4 ya pide:

1. IoT Hub tiene una política de acceso compartido **dedicada**, `func-reader`, solo con `ServiceConnect` (nunca `iothubowner`) ([IoT hub-level shared access policies](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-sas#access-control-and-permissions)). El endpoint integrado solo muestra políticas con `ServiceConnect` ([Connect to the built-in endpoint](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-messages-read-builtin#connect-to-the-built-in-endpoint)).
2. Bicep compone la cadena compatible con Event Hubs (`Endpoint=…;SharedAccessKeyName=func-reader;SharedAccessKey=…;EntityPath=…`) dentro del módulo de Key Vault con `listKeys()` y la escribe como secreto `iothub-func-reader`. **No sale en ninguna salida (`output`) del despliegue.**
3. La app setting `IoTHubConnection` vale `@Microsoft.KeyVault(VaultName=…;SecretName=iothub-func-reader)` (sin versión, para que la rotación se tome sola) y `keyVaultReferenceIdentity` apunta a `id-dsa-func`, que tiene *Key Vault Secrets User* sobre el almacén.
4. Rotación: `infra/rotate-iothub-key.ps1` regenera la clave de `func-reader`, actualiza el secreto y fuerza la recarga de referencias (`POST …/config/configreferences/appsettings/refresh`, [Understand rotation](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#understand-rotation)).

Esta es la **deuda consciente** que CA-11.2 pide documentar: la alternativa de producción es enrutar IoT Hub a un Event Hubs propio y leerlo con identidad administrada, a un costo fijo de unos USD 11 al mes por una unidad de procesamiento Basic (USD 0,015 por hora en `eastus2`, [precios de Event Hubs](https://azure.microsoft.com/pricing/details/event-hubs/)), que en esta demo sería más de la mitad del presupuesto.

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Consumption (Linux) | Learn la marca como heredada y en retiro; no tiene *always ready* ([Consumption plan hosting](https://learn.microsoft.com/azure/azure-functions/consumption-plan)) |
| Premium (Elastic) | Mínimo de una instancia siempre facturada; supera el presupuesto |
| *Always ready* = 1 todo el mes | USD 5,26 con 512 MB: cabe, pero paga 700 horas sin uso. Se prefiere encenderlo por escenario |
| 2 048 MB por defecto (recomendación general de Learn) | El olvido costaría USD 21 al mes; la carga de la demo no lo justifica. Se revisa si las pruebas lo piden |
| Identidad asignada por el sistema | Se crea con la app; la referencia de Key Vault y los roles no estarían listos en el primer arranque, y su object ID cambia si se recrea la app, obligando a reconfigurar el disparador del flujo y `Sites.Selected` |
| Ruta IoT Hub → Event Hubs con identidad | Correcta para producción, pero suma ~USD 11 al mes y una pieza más |

## Consecuencias

- **A favor:** arranque en frío controlado en ensayos y sesión (R-06) con costo de centavos; sin claves en la configuración de la app; una sola identidad para todo.
- **En contra:** la cadena de IoT Hub existe como secreto en Key Vault (deuda documentada); alguien debe cambiar el escenario antes y después de cada ensayo (el runbook y el preflight lo recuerdan).
- **Riesgo R-15:** 512 MB podría quedarse corto para Python con `azure-identity`, `azure-data-tables`, `jsonschema` y `requests`. Prueba: 30 eventos seguidos con el escenario `ensayo`, sin errores de memoria y con el tramo 1 en p90 ≤ 10 s. Si falla, 2 048 MB y el escenario de olvido pasa a vigilarse con la alerta de presupuesto.
- **No verificado en Learn:** cuánto tarda una Function de Flex Consumption en despertar desde cero con un disparador de Event Hubs. No se necesita para la sesión (habrá una instancia *always ready*), pero el preflight lo mide en reposo para documentarlo.
