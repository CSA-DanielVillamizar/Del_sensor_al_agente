# Del sensor al agente

## Manual técnico de reproducción, paso a paso

Este manual lleva desde un tenant y una suscripción vacíos hasta la solución completa funcionando: un evento de un sensor llega a Teams como una propuesta del agente, y la decisión de una persona queda registrada.

Cada paso explica **qué se hace, por qué y cómo se comprueba**. Cuando un paso usa código del repositorio, el manual explica qué hace ese código y para qué sirve, de modo que se pueda reproducir cada configuración entendiendo cada decisión.

| Documento | Para qué sirve |
| --- | --- |
| Este manual | Reproducir la solución completa y entender cada pieza |
| [README](../README.md) | Resumen del despliegue en 8 pasos |
| [agent/GUIA-CONFIGURACION.md](../agent/GUIA-CONFIGURACION.md) | Detalle del agente y de sus flujos en Copilot Studio |
| [docs/admin-sites-selected.md](admin-sites-selected.md) | Comandos del administrador para el permiso de Graph |
| [docs/videos.md](videos.md) | Videos de la solución funcionando, como referencia visual |
| [docs/adr/](adr/) | Decisiones de arquitectura, con sus alternativas |
| [docs/gobernanza.md](gobernanza.md) | Qué cambiar para llevar el patrón a producción |

---

## Contenido

- [Cómo leer este manual](#cómo-leer-este-manual)
- [Parte 1 · La solución en una página](#parte-1--la-solución-en-una-página)
- [Parte 2 · Antes de empezar](#parte-2--antes-de-empezar)
- [Parte 3 · Montaje paso a paso](#parte-3--montaje-paso-a-paso)
  - [Paso 1. Preparar el equipo local](#paso-1-preparar-el-equipo-local)
  - [Paso 2. Preparar Microsoft 365](#paso-2-preparar-microsoft-365)
  - [Paso 3. Aprovisionar SharePoint](#paso-3-aprovisionar-sharepoint)
  - [Paso 4. Desplegar Azure](#paso-4-desplegar-azure)
  - [Paso 5. Conceder Sites.Selected](#paso-5-conceder-sitesselected)
  - [Paso 6. Preparar Power Platform](#paso-6-preparar-power-platform)
  - [Paso 7. Crear el agente](#paso-7-crear-el-agente)
  - [Paso 8. Herramienta LeerIncidente](#paso-8-herramienta-leerincidente)
  - [Paso 9. Herramienta PublicarIncidente](#paso-9-herramienta-publicarincidente)
  - [Paso 10. Flujo DisparoAgente](#paso-10-flujo-disparoagente)
  - [Paso 11. Publicar el agente](#paso-11-publicar-el-agente)
  - [Paso 12. Conectar Azure con Microsoft 365](#paso-12-conectar-azure-con-microsoft-365)
  - [Paso 13. Registrar los dispositivos](#paso-13-registrar-los-dispositivos)
  - [Paso 14. Prueba de punta a punta](#paso-14-prueba-de-punta-a-punta)
- [Parte 4 · El código, archivo por archivo](#parte-4--el-código-archivo-por-archivo)
- [Parte 5 · Operación diaria](#parte-5--operación-diaria)
- [Parte 6 · Solución de problemas](#parte-6--solución-de-problemas)
- [Parte 7 · Limpieza](#parte-7--limpieza)
- [Referencias](#referencias)

---

## Cómo leer este manual

- **Marcadores.** Todo lo que aparece entre `<...>` es un valor de tu entorno: `<iotHub>`, `<siteId>`, `<clientId>`. El repositorio no contiene ningún identificador real; tú los obtienes en el paso indicado.
- **Consola.** Todos los comandos se ejecutan en **PowerShell 7**, desde la raíz del repositorio, salvo que el paso diga otra cosa. Los scripts de `infra/` también tienen versión en Bash (`deploy.sh`, `destroy.sh`).
- **Comprobación.** Cada paso termina con un bloque **✅ Siga cuando**. No avances si no se cumple: los pasos siguientes dependen de ese resultado.
- **Tiempo total.** Unos 90 minutos la primera vez, con el tenant, la suscripción y las licencias disponibles.
- **Configuración recomendada.** El manual describe la configuración recomendada. La demo en vivo de la sesión usó otra, por las razones de [ADR-002](adr/ADR-002-entorno-demo-en-vivo.md), y las diferencias se señalan donde aplican.

---

## Parte 1 · La solución en una página

### Qué hace

Un sensor reporta un evento: una puerta forzada, movimiento en una zona restringida o accesos denegados repetidos. Azure recibe la señal, descarta duplicados y la enriquece. Microsoft 365 la convierte en un incidente auditado. Un agente de Copilot Studio lee el incidente, consulta el protocolo y propone una severidad. El supervisor decide en una tarjeta de Teams, y la decisión queda registrada con quién, qué y cuándo.

**El agente propone; la persona decide.** Ningún componente ejecuta una acción física ni contacta a nadie.

### El recorrido de un evento

| # | Dónde | Qué pasa |
| --- | --- | --- |
| 1 | Simulador → IoT Hub | El simulador envía un JSON de 7 campos por MQTT, con la clave propia del dispositivo |
| 2 | IoT Hub → Function | La Function `ingest_event` recibe el mensaje desde el endpoint integrado de IoT Hub |
| 3 | Function | Valida el evento contra el esquema, lo deduplica (ventana de 60 s), aplica el tope de 10 incidentes por minuto y calcula la severidad inicial con el catálogo de zonas |
| 4 | Function → SharePoint | Crea el incidente en la lista `Eventos de seguridad` con Microsoft Graph, en estado `Nuevo` |
| 5 | Function → Power Automate | Llama al flujo `DisparoAgente` con un solo dato, el `eventId` |
| 6 | Flujo → Agente | El flujo ejecuta el Agente de Operaciones con el mensaje `Nuevo incidente <eventId>` |
| 7 | Agente | Llama a `LeerIncidente`, consulta el protocolo en la biblioteca `Protocolos` y propone severidad, resumen y pasos |
| 8 | Agente → Teams | Llama a `PublicarIncidente`, que deja el incidente en `Pendiente de decisión` y publica la tarjeta en el canal |
| 9 | Teams → SharePoint | El supervisor pulsa un botón. La decisión, quién y cuándo quedan en la lista. Si nadie responde en 15 minutos, el estado pasa a `Sin respuesta` |

### Los componentes

| Componente | Dónde vive | Para qué sirve |
| --- | --- | --- |
| Simulador | `simulator/` | Hace de sensor. Envía eventos ficticios |
| IoT Hub | Azure | Puerta de entrada de los dispositivos, cada uno con su identidad |
| Azure Function | `function/`, Azure | Valida, deduplica, enriquece, registra y dispara al agente |
| Table Storage | Azure | Memoria corta de la Function: ventanas de deduplicación y cupo por minuto |
| Identidad administrada `id-dsa-func` | Azure | Identidad de la Function ante Storage, Key Vault, Graph y el flujo, sin contraseñas |
| Key Vault | Azure | Guarda el único secreto de la nube: la cadena para leer IoT Hub |
| Application Insights | Azure | Registros de cada paso, con el `eventId` como hilo |
| Presupuesto | Azure | Aviso de costo al 80 % de USD 20 al mes |
| Lista `Eventos de seguridad` | SharePoint | Registro de auditoría de cada incidente |
| Biblioteca `Protocolos` | SharePoint | Un protocolo por tipo de evento; conocimiento del agente |
| Flujo `DisparoAgente` | Power Automate | Recibe el `eventId` y ejecuta el agente. Solo lo puede llamar la Function |
| Agente de Operaciones | Copilot Studio | Lee, clasifica, resume y propone |
| `LeerIncidente` y `PublicarIncidente` | Copilot Studio | Las dos únicas herramientas del agente |
| Tarjeta adaptativa | `cards/`, Teams | Muestra la propuesta y recoge la decisión |
| Cuenta de servicio `agente-dsa` | Microsoft Entra ID | Dueña del agente, los flujos y las conexiones |

El diagrama completo está en el [README](../README.md#arquitectura).

---

## Parte 2 · Antes de empezar

### 2.1 Cuentas, tenant y licencias

| Necesitas | Por qué |
| --- | --- |
| Un tenant de Microsoft 365 **de pruebas**, con Teams y SharePoint | La solución crea listas, flujos y un agente. Un tenant de pruebas evita mezclar la demo con datos reales |
| Una persona con rol de **administrador de SharePoint** (o superior) | Concede el permiso `Sites.Selected` del paso 5 ([admin-sites-selected.md](admin-sites-selected.md)) |
| Una suscripción de Azure **en el mismo tenant**, con rol *Owner* sobre el grupo de recursos | La identidad administrada solo existe en el tenant de su suscripción. Sin el mismo tenant, la Function no puede pedir tokens para Graph ni para el flujo. *Owner* hace falta porque la plantilla asigna roles |
| Una cuenta de servicio `agente-dsa`, **sin roles de administrador** | Es la dueña del agente y de las conexiones. El agente actúa con los permisos de su creador, así que no debe ser una cuenta personal ni de administrador ([Data protection for agents with triggers](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#data-protection-for-agents-with-triggers)) |
| Una licencia que permita **publicar** el agente para `agente-dsa` | Licencia de usuario de Copilot Studio con créditos asignados al entorno, o Microsoft 365 Copilot. Las licencias de prueba no habilitan la publicación ([FAQ de facturación](https://learn.microsoft.com/microsoft-copilot-studio/faq-billing-licensing)) |
| Una cuenta `Supervisor Demo`, sin roles de administrador | Es quien responde las tarjetas. Así la decisión queda a nombre de una cuenta de demostración, no de una persona real |
| Copilot Credits | Las ejecuciones del agente y de sus flujos consumen créditos. Recomendado: pago por uso con presupuesto propio ([Set up pay-as-you-go](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan), [ADR-001](adr/ADR-001-facturacion-creditos-copilot-studio.md)) |
| La app *Workflows* permitida en Teams | La tarjeta se publica como *Flow bot*, que depende de esa app ([Teams connector, known issues](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)) |

### 2.2 Herramientas locales

| Herramienta | Versión | Instalación | Para qué |
| --- | --- | --- | --- |
| PowerShell | 7 o superior | `winget install --id Microsoft.PowerShell --source winget` ([Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)) | Todos los scripts de `infra/`, `sharepoint/` y `demo/` |
| Python | 3.11 o superior | [python.org](https://www.python.org/downloads/) | El simulador, las pruebas y el generador del flujo `PublicarIncidente`. La Function corre en Python 3.11 en Azure |
| Azure CLI | La más reciente | [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | Despliegue, roles, dispositivos y tokens |
| Bicep para Azure CLI | La más reciente | `az bicep install` ([Install Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install)) | Compilar `infra/main.bicep` |
| Extensión de IoT de Azure CLI | La más reciente | `az extension add --name azure-iot` ([az iot hub device-identity](https://learn.microsoft.com/cli/azure/iot/hub/device-identity)) | Crear las identidades de los dispositivos |
| Módulo Microsoft Graph | 2.x | `Install-Module Microsoft.Graph -Scope CurrentUser` ([Install the Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/installation)) | Aprovisionar SharePoint y los scripts de operación |
| Git | Cualquiera reciente | — | Clonar el repositorio |

✅ **Siga cuando:** `pwsh --version`, `python --version`, `az version`, `az bicep version` y `git --version` responden sin error, y `Get-Module Microsoft.Graph -ListAvailable` muestra el módulo.

---

## Parte 3 · Montaje paso a paso

### Paso 1. Preparar el equipo local

**Qué se hace:** clonar el repositorio, crear un entorno de Python aislado, instalar las dependencias, correr las pruebas y crear el archivo `.env`.

```powershell
git clone https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente C:\src\del-sensor-al-agente
cd C:\src\del-sensor-al-agente
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.txt
python -m pytest -q
Copy-Item .env.example .env
```

**Línea por línea:**

| Comando | Qué hace | Por qué |
| --- | --- | --- |
| `git clone ... C:\src\...` | Copia el repositorio en una ruta corta | Algunas dependencias de Python tienen rutas largas. En carpetas profundas, la instalación falla si Windows no tiene activadas las rutas largas |
| `python -m venv .venv` | Crea un entorno de Python solo para este proyecto | Las versiones de las dependencias quedan fijas y no chocan con otros proyectos |
| `.\.venv\Scripts\Activate.ps1` | Activa ese entorno en la consola | Desde aquí, `python` y `pip` son los del entorno |
| `pip install -r requirements-dev.txt` | Instala las dependencias de la Function, del simulador y de las pruebas | `requirements-dev.txt` incluye `function/requirements.txt` y `simulator/requirements.txt`, más `pytest`, `ruff` y `python-docx` |
| `python -m pytest -q` | Corre todas las pruebas | Las pruebas no necesitan Azure ni el tenant: validan esquemas, tarjetas, la lógica de la Function y las instrucciones del agente. Si fallan aquí, fallarán en la nube |
| `Copy-Item .env.example .env` | Crea tu archivo de configuración local | `.env` está en `.gitignore`: guarda nombres, rutas y las claves de los dispositivos, y nunca se versiona |

**Las variables de `.env`.** Se llenan a medida que avanzas. Ninguna se versiona.

| Variable | Se llena en | Para qué |
| --- | --- | --- |
| `IOTHUB_DEVICE_CONNECTION_STRING` | Paso 13 | Cadena del dispositivo `sim-01`. La usa el simulador |
| `IOTHUB_PREFLIGHT_CONNECTION_STRING` | Paso 13 | Cadena del dispositivo `preflight-01`. La usa `demo/preflight.ps1`; sus eventos quedan marcados como prueba |
| `DSA_RESOURCE_GROUP` | Paso 4 | Grupo de recursos de Azure (`rg-dsa-demo`) |
| `DSA_SITE_URL` | Paso 2 | URL del sitio de SharePoint de la demo |
| `DSA_LIST_NAME` | Ya viene | `Eventos de seguridad` |
| `DSA_TEAM_NAME`, `DSA_CHANNEL_NAME` | Paso 2 | Equipo y canal de Teams |
| `DSA_ENVIRONMENT_KIND` | Paso 6 | `sandbox` (recomendado) o `default` |
| `DSA_FLOW_URL` | Paso 10 | URL del disparador de `DisparoAgente`. No es un secreto, porque el disparador exige un token de Entra ID, pero identifica tu tenant |
| `DSA_TEAM_ID`, `DSA_CHANNEL_ID` | Opcional | Evitan que `demo/measure.ps1` busque el equipo y el canal por nombre |
| `DSA_DATAVERSE_URL`, `DSA_CREDITS_*`, `DSA_TRIAL_END`, `DSA_NEW_INFRA`, `DSA_SESSION_DATE` | Paso 6 | Datos que el preflight compara y que no se pueden leer con una API documentada |

**Cargar `.env` en la consola.** Los scripts de `demo/` leen las variables del entorno de la sesión. Este comando las carga desde el archivo:

```powershell
Get-Content .env | Where-Object { $_ -match '^[A-Z_]+=.+' } | ForEach-Object { $n, $v = $_ -split '=', 2; Set-Item "env:$n" $v }
```

Lee cada línea con forma `NOMBRE=valor` (ignora comentarios y líneas vacías), la divide en el primer `=` y crea la variable de entorno del proceso. Las variables viven solo en esa consola: al cerrarla, desaparecen.

✅ **Siga cuando:** `pytest` termina con todas las pruebas en verde y existe `.env` en la raíz.

---

### Paso 2. Preparar Microsoft 365

**Qué se hace:** crear en el portal, con una cuenta de administrador, los lugares donde vivirá la solución.

1. **Crea el sitio de SharePoint de la demo.** Ahí van la lista de incidentes y la biblioteca de protocolos. Copia su URL en `DSA_SITE_URL`.
2. **Crea un segundo sitio vacío, `DSA-Control`.** No guarda nada. Sirve para **probar** que la Function no puede escribir fuera del sitio de la demo: en el paso 5, la escritura en `DSA-Control` debe fallar con 403.
3. **Crea el equipo privado `DSA-Demo`** con un canal **estándar** llamado `Centro de operaciones`. Debe ser estándar porque el conector de Teams no publica en canales privados ([Teams connector, known issues](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)). Opcional: un segundo canal estándar, `Pruebas spike`, para probar tarjetas sin ensuciar el canal de la demo.
4. **Agrega como miembros del equipo** a `agente-dsa` y a `Supervisor Demo`. La tarjeta se publica con la conexión de `agente-dsa`, y el supervisor necesita ver el canal para responder.

Completa en `.env`: `DSA_SITE_URL`, `DSA_TEAM_NAME=DSA-Demo` y `DSA_CHANNEL_NAME=Centro de operaciones`.

✅ **Siga cuando:** los dos sitios existen, `DSA-Control` está vacío, y las dos cuentas ven el canal `Centro de operaciones`.

---

### Paso 3. Aprovisionar SharePoint

**Qué se hace:** crear la lista `Eventos de seguridad` con sus 24 columnas y la biblioteca `Protocolos` con los tres protocolos, a partir de los archivos del repositorio.

```powershell
./sharepoint/provision.ps1
```

**Qué hace el script, en orden:**

1. Lee `DSA_SITE_URL` (del parámetro `-SiteUrl`, del entorno o de `.env`, en ese orden de prioridad).
2. Abre una **sesión delegada** de Microsoft Graph con tu cuenta. Pide solo dos permisos:
   - `Sites.Manage.All`: crear listas y bibliotecas y agregar columnas. Learn lo indica como el menor privilegio para crear una lista en modo delegado; `Sites.ReadWrite.All` no alcanza ([Create list — permissions](https://learn.microsoft.com/graph/api/list-create#permissions)).
   - `Files.ReadWrite.All`: subir los `.docx` a la biblioteca de un sitio. `Files.ReadWrite` solo cubre tus archivos ([Upload content — permissions](https://learn.microsoft.com/graph/api/driveitem-put-content#permissions)).
3. Valida el contrato de columnas `sharepoint/columnas.json` y lo compara con lo que ya existe en el tenant. **Solo agrega lo que falta.**
4. Crea la biblioteca `Protocolos` si no existe.
5. Convierte cada protocolo de `protocols/*.md` a `.docx` (con `sharepoint/build-protocols.py`) y lo sube solo si cambió. Para saberlo, guarda el hash de la fuente en la columna `HashFuente` del documento.
6. Comprueba que `DSA-Control` existe y está vacío. No lo crea: si falta, lo informa en rojo y sigue.

**Por qué es idempotente.** Una segunda ejecución seguida no crea nada: todo lo compara antes de escribir. Así puedes correrlo de nuevo si algo falla a mitad de camino, sin duplicar columnas ni documentos.

**Opciones útiles:**

| Opción | Para qué |
| --- | --- |
| `-WhatIf` | Muestra lo que haría, sin escribir nada en el tenant |
| `-LocalOnly` | Valida solo la parte local (contrato, metadatos y hashes), sin abrir sesión. Sirve sin acceso al tenant |
| `-SkipProtocols` | Crea o completa la lista y la biblioteca sin subir documentos |

**El contrato de columnas.** `sharepoint/columnas.json` es la **única fuente** de las columnas. Lo usan el script de aprovisionamiento, la Function (para armar el cuerpo que envía a Graph) y las pruebas de contrato. Cada columna declara su tipo, si es obligatoria y **quién puede escribirla**:

| Columnas | Las escribe | Cuándo |
| --- | --- | --- |
| `Title`, `EventId` (única e indexada), `DeviceId`, `TipoEvento`, `Zona`, `NombreZona`, `CamaraId`, `Sitio`, `SeveridadRaw`, `SeveridadInicial`, `Repeticiones`, `FechaEventoUtc`, `RecibidoUtc`, `EsPrueba` | La Function | Al crear el incidente (y `Repeticiones` en cada repetición) |
| `Estado` | La Function y `PublicarIncidente` | `Nuevo` al crear; después `Pendiente de decisión`, `Atendido`, `Escalado`, `Falsa alarma` o `Sin respuesta` |
| `SeveridadPropuesta`, `JustificacionSeveridad`, `ResumenAgente`, `ProtocoloAplicado`, `PublicacionSolicitadaUtc` | `PublicarIncidente` | Al publicar la propuesta |
| `Decision`, `DecididoPor`, `FechaDecision`, `Observacion` | `PublicarIncidente` | Cuando el supervisor responde |

`EventId` es **única**: si la Function intenta crear dos veces el mismo incidente (por ejemplo, tras una reentrega), SharePoint lo rechaza y la Function recupera el elemento existente. Está **indexada** porque los flujos y los scripts buscan siempre por ese campo.

**Anota el ID del sitio y el de la lista.** Los necesita el paso 12:

```powershell
Connect-MgGraph -Scopes 'Sites.Read.All' -ContextScope Process -NoWelcome
$site = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/sites/<host>:/sites/<ruta-del-sitio>?$select=id'
$filter = [uri]::EscapeDataString("displayName eq 'Eventos de seguridad'")
$list = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($site.id)/lists?`$filter=$filter&`$select=id").value[0]
$site.id; $list.id
```

| Línea | Qué hace |
| --- | --- |
| `Connect-MgGraph ... -ContextScope Process` | Abre una sesión de solo lectura. `Process` deja el token solo en esta consola, sin guardarlo en la caché del perfil ([Connect-MgGraph](https://learn.microsoft.com/powershell/module/microsoft.graph.authentication/connect-mggraph)) |
| `GET v1.0/sites/<host>:/sites/<ruta>` | Pide el sitio por su dirección. Graph devuelve un ID con la forma `{hostname},{siteCollectionId},{webId}` |
| `$filter=displayName eq '...'` | Busca la lista por su nombre visible y devuelve solo su `id` |

✅ **Siga cuando:** la segunda ejecución de `provision.ps1` no crea nada; la lista tiene las columnas del contrato; la biblioteca `Protocolos` tiene `acceso_denegado_repetido.docx`, `movimiento_zona_restringida.docx` y `puerta_forzada.docx`; y tienes anotados `<siteId>` y `<listId>`.

---

### Paso 4. Desplegar Azure

**Qué se hace:** crear toda la infraestructura de Azure con una plantilla de Bicep y publicar el código de la Function.

```powershell
az login
./infra/deploy.ps1
```

Para ver los cambios sin aplicarlos: `./infra/deploy.ps1 -WhatIf`. Si la suscripción ya tiene un IoT Hub gratuito (solo se permite uno), usa `./infra/deploy.ps1 -IotHubSku B1` (suma unos USD 10 al mes, [docs/costos.md](costos.md)).

**Qué hace `deploy.ps1`, en orden:**

1. **Comprueba la sesión de `az`.** No inicia sesión por ti: si no hay sesión, falla.
2. **Registra los proveedores de recursos que faltan:** `Microsoft.Devices`, `Microsoft.Web`, `Microsoft.KeyVault`, `Microsoft.Storage`, `Microsoft.Insights`, `Microsoft.OperationalInsights` y `Microsoft.ManagedIdentity`. Una suscripción nueva no los tiene registrados, y sin ellos el despliegue falla.
3. **Crea el grupo `rg-dsa-demo`** en `eastus2`, si no existe.
4. **Lee tu object ID** (`az ad signed-in-user show`) y lo pasa como `operatorPrincipalId`. Con él, la plantilla te da dos roles de operador: crear dispositivos en IoT Hub y vaciar las tablas con `demo/reset.ps1`. Tu ID nunca se escribe en un archivo.
5. **Despliega `infra/main.bicep`** con los parámetros de `infra/main.bicepparam`.
6. **Empaqueta la Function** (`function/` más los contratos en `_contracts/`) y la publica con compilación remota (`--build-remote true`), para que Azure instale las dependencias de Python en Linux.
7. **Imprime el resumen:** nombres de los recursos, el client ID y el object ID de `id-dsa-func`, y los dos comandos del administrador listos para copiar. **Ningún valor se escribe en archivos.**

**Los parámetros de la plantilla** (`infra/main.bicepparam`):

| Parámetro | Valor | Por qué |
| --- | --- | --- |
| `location` | `eastus2` | Región de todos los recursos |
| `namePrefix` | `dsa` | Prefijo de los nombres. Los nombres únicos se completan con un token derivado del grupo de recursos |
| `iotHubSku` | `F1` | Gratis. `B1` solo si ya hay un F1 en la suscripción |
| `instanceMemoryMB` | `512` | La Function procesa un evento pequeño; más memoria solo cuesta más |
| `maximumInstanceCount` | `1` | Una sola instancia: tope de costo y de concurrencia |
| `alwaysReadyCount` | `0` | Apagado por defecto. Se enciende solo para ensayos y la sesión ([ADR-005](adr/ADR-005-hosting-function.md)) |
| `maxIncidentsPerMinute` | `10` | Tope de incidentes por minuto: protege los créditos y al supervisor |
| `budgetAmount`, `budgetThresholdPercent` | `20`, `80` | Aviso al 80 % de USD 20 al mes |
| `logDailyQuotaGb` | `0.05` | Límite diario de ingesta de registros: un error en bucle no dispara la factura |

`graphSiteId`, `graphListId` y `agentFlowUrl` llegan vacíos en este primer despliegue. Se pasan en el paso 12, cuando existen.

#### Qué crea cada módulo de Bicep, y por qué

**`modules/identity.bicep` — la identidad de la Function.** Crea la identidad administrada asignada por el usuario `id-dsa-func`. Se crea **antes** que la Function para que los roles y la referencia a Key Vault estén listos en el primer arranque. Sus salidas (`clientId`, `principalId`) son identificadores públicos, no secretos.

**`modules/storage.bicep` — almacenamiento sin claves.**

```bicep
allowSharedKeyAccess: false
defaultToOAuthAuthentication: true
minimumTlsVersion: 'TLS1_2'
```

- `allowSharedKeyAccess: false` **desactiva las claves de la cuenta**. Todo acceso es con Microsoft Entra ID: no existe una clave que se pueda filtrar.
- Crea el contenedor `deploymentpackage` (el paquete de la Function) y las tablas `dedup` y `ratelimit`.
- Asigna a `id-dsa-func` dos roles: *Storage Blob Data Owner* (el host de la Function y su paquete) y *Storage Table Data Contributor* (las tablas). Si se pasó `operatorPrincipalId`, te da también *Storage Table Data Contributor*, para `demo/reset.ps1`.
- El nombre de cada asignación es `guid(storage.id, principalId, roleId)`: determinista, así que volver a desplegar no duplica roles.

**`modules/keyvault.bicep` — el único secreto.** Key Vault con modelo **RBAC** (`enableRbacAuthorization: true`) y borrado temporal de 7 días. `id-dsa-func` recibe solo *Key Vault Secrets User* sobre este almacén: puede leer secretos, no crearlos ni borrarlos. No tiene protección de purga para que `infra/destroy.ps1` pueda purgarlo y redesplegar con el mismo nombre.

**`modules/monitor.bicep` — registros con tope.**

- Log Analytics con `workspaceCapping.dailyQuotaGb`: límite diario de ingesta ([Daily cap](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap)).
- Application Insights con `DisableLocalAuth: true`: solo acepta telemetría autenticada con Entra ID. Por eso la Function recibe el rol *Monitoring Metrics Publisher*.

**`modules/iothub.bicep` — la puerta de los dispositivos.**

```bicep
authorizationPolicies: [
  { keyName: 'func-reader', rights: 'ServiceConnect' }
]
routing: {
  fallbackRoute: { name: '$fallback', source: 'DeviceMessages', condition: 'true', endpointNames: ['events'], isEnabled: true }
}
```

- **Una sola política, `func-reader`, con `ServiceConnect`.** Es lo mínimo para leer los mensajes. No existe la política `iothubowner`: la administración del registro de dispositivos se hace con Entra ID, con el rol *IoT Hub Registry Contributor* del operador.
- **`fallbackRoute` activa.** Sin rutas propias, la ruta de respaldo lleva los mensajes de los dispositivos al endpoint integrado. Si se omite en la plantilla, queda desactivada y los mensajes no llegan a la Function.
- **`partitionCount: 2` y `retentionTimeInDays: 1`.** F1 exige 2 particiones; un día de retención basta.
- **Grupo de consumidores `func`.** La Function lee con su propio grupo, para no competir con otras herramientas que lean el hub.
- `disableLocalAuth: false`: los dispositivos se autentican con su **clave simétrica propia**, así que la autenticación local debe seguir activa.

**`modules/iothub-secret.bicep` — el secreto que nunca pasa por tu consola.**

```bicep
var policy = filter(hub.listkeys().value, p => p.keyName == policyName)[0]
value: 'Endpoint=${events.endpoint};SharedAccessKeyName=${policyName};SharedAccessKey=${...};EntityPath=${events.path}'
```

Azure Resource Manager lee las claves del hub (`listkeys()`), compone la cadena compatible con Event Hubs y la guarda en Key Vault como `iothub-func-reader`. La clave **no sale del despliegue**: el módulo solo devuelve el nombre del secreto. Si la política no existiera, el índice `[0]` falla y el despliegue se detiene, que es lo deseado.

**`modules/function.bicep` — la Function en Flex Consumption.** Plan `FC1` (Flex Consumption), Linux, Python 3.11 ([plantilla de referencia](https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code?pivots=flex-consumption-plan)). La configuración de la app no tiene ningún secreto:

| App setting | Valor | Para qué |
| --- | --- | --- |
| `AzureWebJobsStorage__accountName`, `__credential=managedidentity`, `__clientId` | Cuenta e identidad | El host usa Storage con la identidad, sin cadena de conexión |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Leída del recurso | A dónde enviar la telemetría |
| `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` | `ClientId=...;Authorization=AAD` | Autentica la telemetría con Entra ID, porque Application Insights no acepta otra |
| `IoTHubConnection` | `@Microsoft.KeyVault(VaultName=...;SecretName=iothub-func-reader)` | **Referencia** a Key Vault: la app resuelve el secreto al arrancar, con `id-dsa-func` (`keyVaultReferenceIdentity`) |
| `AZURE_CLIENT_ID` | Client ID de `id-dsa-func` | El código pide tokens con esta identidad |
| `DSA_TABLE_ENDPOINT` | Endpoint de tablas | Dónde están `dedup` y `ratelimit` |
| `DSA_MAX_INCIDENTS_PER_MINUTE` | `10` | Tope por minuto |
| `DSA_GRAPH_SITE_ID`, `DSA_GRAPH_LIST_ID`, `DSA_FLOW_URL` | Vacíos hasta el paso 12 | Destino del incidente y del disparo |

Además:

- `alwaysReady` con `function:ingest_event` cuando `alwaysReadyCount > 0`: mantiene una instancia encendida para quitar el arranque en frío durante la sesión.
- El paquete se despliega desde el contenedor de blobs con autenticación de la identidad.
- `basicPublishingCredentialsPolicies` `ftp` y `scm` en `allow: false`: no se puede publicar con usuario y contraseña, solo con Entra ID.
- `httpsOnly`, TLS 1.2 mínimo y FTPS desactivado.

**`modules/budget.bicep` — el aviso de costo.** Presupuesto mensual de USD 20 con aviso al 80 %. Avisa al rol *Owner* del grupo (`contactRoles`) y a un grupo de acciones con un receptor de rol de ARM. Así **no hay ningún correo escrito en el repositorio**. Learn exige al menos un correo o un grupo de acciones en el ámbito de grupo de recursos, por eso existe el grupo ([Budgets — notification](https://learn.microsoft.com/azure/templates/microsoft.consumption/budgets#notification)). Un presupuesto **avisa, pero no detiene** el consumo: por eso los topes también están en el diseño.

**Las salidas de `main.bicep`** son solo nombres e identificadores públicos. Ninguna clave, cadena de conexión ni URI de secreto.

Al terminar, guarda `DSA_RESOURCE_GROUP=rg-dsa-demo` en `.env` y anota `<clientId>`, `<objectId>` y el nombre del IoT Hub (`<iotHub>`) que imprime el resumen.

> **Importante:** no envíes eventos todavía. La Function arranca sin `DSA_GRAPH_SITE_ID`, `DSA_GRAPH_LIST_ID` ni `DSA_FLOW_URL`, y cada evento fallaría con `ConfigurationError` hasta el paso 12.

✅ **Siga cuando:** el grupo `rg-dsa-demo` tiene la Function App, el plan, IoT Hub, Key Vault, la cuenta de almacenamiento, Log Analytics, Application Insights, la identidad `id-dsa-func`, el grupo de acciones y el presupuesto; y tienes anotados `<clientId>`, `<objectId>` e `<iotHub>`.

---

### Paso 5. Conceder `Sites.Selected`

**Qué se hace:** un administrador de SharePoint da a `id-dsa-func` permiso de escritura **solo sobre el sitio de la demo**.

**Por qué así.** La Function necesita escribir en una lista. El permiso amplio (`Sites.ReadWrite.All`) le daría acceso a todos los sitios del tenant. `Sites.Selected` no da acceso a nada por sí solo: hay que conceder cada sitio de forma explícita ([Overview of Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview)).

**Forma rápida**, con el script que hace los dos comandos, las comprobaciones y el cierre de sesión:

```powershell
./infra/grant-sites-selected.ps1 -ObjectId <objectId> -ClientId <clientId> -SiteUrl <URL del sitio de la demo> -ControlSiteUrl <URL de DSA-Control>
```

Agrega `-UseDeviceCode` si la consola no puede abrir el navegador. El script es idempotente.

**Lo que hace por dentro** (los mismos dos comandos, explicados):

1. **Asigna el rol de aplicación `Sites.Selected`** de Microsoft Graph a la entidad de servicio de `id-dsa-func`. Las identidades administradas reciben permisos de Graph así, con una asignación de rol de aplicación, no desde el portal ([Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity)).

   ```powershell
   New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '<objectId>' -PrincipalId '<objectId>' -ResourceId (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id -AppRoleId '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
   ```

   `00000003-0000-0000-c000-000000000000` es el appId de Microsoft Graph y `883ea226-...` es el ID público del rol `Sites.Selected` ([permissions reference](https://learn.microsoft.com/graph/permissions-reference#sitesselected)). Ambos son iguales en todos los tenants.

2. **Concede el rol `write` sobre el sitio de la demo**, con el **client ID** de la identidad ([Create permission](https://learn.microsoft.com/graph/api/site-post-permissions)):

   ```powershell
   New-MgSitePermission -SiteId '<siteId>' -BodyParameter @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = '<clientId>'; displayName = 'id-dsa-func' } }) }
   ```

Quien ejecuta estos comandos necesita permisos de administrador en **su sesión** (detalle en [admin-sites-selected.md](admin-sites-selected.md)). La Function solo recibe `Sites.Selected`.

✅ **Siga cuando:** `Get-MgSitePermission -SiteId '<siteId>'` muestra `id-dsa-func` con `write`, y el mismo comando sobre `DSA-Control` **no** la muestra.

---

### Paso 6. Preparar Power Platform

**Qué se hace:** el entorno, la cuenta de servicio, la solución, las conexiones y las variables de entorno. Todo lo que sigue hasta el paso 11 se hace **iniciando sesión como `agente-dsa`**.

**6.1 Entorno.** Recomendado: un entorno **Sandbox** dedicado, `DSA-Demo`, con Dataverse ([Create an environment](https://learn.microsoft.com/power-platform/admin/create-environment#create-an-environment-with-a-database)). Nunca de tipo *Trial*: se elimina con sus agentes a los 30 días y no admite pago por uso.

| Configuración del entorno | Por qué |
| --- | --- |
| Grupo de seguridad ([Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)) | Solo entra quien debe |
| Política de datos propia ([Configure data policies for agents](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention)) | Limita los conectores que pueden usar el agente y sus flujos. La tabla de conectores está en [gobernanza.md](gobernanza.md) |
| Auditoría de Dataverse ([Manage Dataverse auditing](https://learn.microsoft.com/power-platform/admin/manage-dataverse-auditing#configure-auditing-for-an-environment)) | Registro de cambios en el agente y los flujos |
| *Solution-aware cloud flow sharing* activado ([requisito](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#solution-aware-cloud-flow-sharing-must-be-turned-on)) | Lo necesitan los flujos de una solución que usa un agente |
| Pago por uso con presupuesto propio y límite del agente de 3 000 créditos ([Manage monthly consumption limits](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity#manage-monthly-consumption-limits-for-copilot-studio-agents)) | Tope de consumo por agente |

Si el tenant no tiene capacidad para un Sandbox, la alternativa es el entorno predeterminado, con los riesgos y mitigaciones de la [guía del agente](../agent/GUIA-CONFIGURACION.md#si-no-tienes-capacidad-para-un-sandbox). Así se hizo la demo en vivo ([ADR-002](adr/ADR-002-entorno-demo-en-vivo.md)). Anota en `.env` `DSA_ENVIRONMENT_KIND` (`sandbox` o `default`) y `DSA_DATAVERSE_URL`.

**6.2 Cuenta de servicio `agente-dsa`.**

1. Sin roles de administración, con una licencia de Copilot Studio ([licensing](https://learn.microsoft.com/microsoft-copilot-studio/billing-licensing#get-access-to-copilot-studio)).
2. Miembro del equipo de Teams (paso 2).
3. Permiso de **lectura y escritura** en el sitio de la demo y de **lectura** en `Protocolos`. El conocimiento de SharePoint solo muestra lo que puede leer la identidad que ejecuta al agente ([Add SharePoint as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint)).

**6.3 Solución y conexiones.**

1. Crea el publicador `dsa` y la solución `DelSensorAlAgente`, y márcala como **solución preferida**, para que todo lo nuevo entre en ella ([Create a solution](https://learn.microsoft.com/power-apps/maker/data-platform/create-solution)). Una solución permite mover, versionar y borrar todo junto.
2. Crea dos **referencias de conexión**, una de SharePoint y una de Microsoft Teams, cada una con una conexión de `agente-dsa` ([Use a connection reference](https://learn.microsoft.com/power-apps/maker/data-platform/create-connection-reference#manually-add-a-connection-reference-using-solution-explorer)). Los flujos usan la referencia, no la conexión directa: al mover la solución a otro entorno, solo se cambia la conexión.
3. Crea las **variables de entorno** `dsa_TimeoutDecision` (`PT15M`, la espera de la tarjeta en formato ISO 8601) y `dsa_SitioDemo` (la URL del sitio) ([Environment variables](https://learn.microsoft.com/power-apps/maker/data-platform/environmentvariables)).

✅ **Siga cuando:** la solución `DelSensorAlAgente` existe con las dos referencias de conexión y las dos variables de entorno, y todo pertenece a `agente-dsa`.

---

### Paso 7. Crear el agente

**Qué se hace:** crear el Agente de Operaciones con sus instrucciones y su conocimiento.

1. En Copilot Studio, crea un agente del **standard harness** llamado "Agente de Operaciones" ([Access standard harness agents](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/switch-experiences)).
2. Elige **inglés (en-US)** como idioma principal. **No se puede cambiar después** ([Language support](https://learn.microsoft.com/microsoft-copilot-studio/authoring-language-support)). Las instrucciones le ordenan responder siempre en español ([ADR-003](adr/ADR-003-disparo-del-agente.md)).
3. Deja activada la **orquestación generativa**: el agente decide qué herramienta llamar a partir de las descripciones.
4. En *Instructions*, pega el bloque entre `<!-- INSTRUCCIONES: inicio -->` y `<!-- INSTRUCCIONES: fin -->` de [agent/instrucciones.md](../agent/instrucciones.md), **incluidos** los comentarios `REGLA-HORARIO`. El campo admite hasta 8 000 caracteres, y una prueba lo comprueba.
5. En *Knowledge*, agrega la biblioteca `Protocolos` con la opción **SharePoint**, con la descripción "Protocolos de respuesta por tipo de evento de seguridad física" ([Add SharePoint sites](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint#add-sharepoint-sites-as-a-knowledge-source)).
6. Desactiva el conocimiento general y la búsqueda web, para que responda solo con los protocolos ([Filter your SharePoint source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint#filter-your-sharepoint-source)).

**Cómo están escritas las instrucciones, y por qué.**

| Sección | Qué dice | Por qué |
| --- | --- | --- |
| Rol | Propone; nunca ejecuta | Fija el límite antes que cualquier otra cosa |
| Idioma y tono | Siempre en español, sobrio, en términos de propuesta | El idioma principal es inglés; sin esta regla podría responder en inglés |
| Qué haces, en este orden | Siete pasos: leer, consultar el protocolo, calcular, redactar, publicar una sola vez, terminar | Un orden explícito reduce llamadas de más y protege los créditos |
| Modelo de severidad | Parte de `SeveridadInicial`; propone a lo sumo un nivel de diferencia; justifica cada cambio | La propuesta queda acotada y explicada |
| Bloque `REGLA-HORARIO` | Horario diurno de 06:00 a 18:00 en America/Bogota; fuera de horario, sube un nivel | Es la regla que cambia el jefe de seguridad. Está aislada entre marcadores para cambiarla sin tocar nada más |
| Lo que nunca haces | No llama, no abre ni bloquea, no cierra casos, no cambia protocolos, no afirma haber avisado a nadie | Primera capa del control. La segunda es el diseño: el agente no tiene herramientas para hacerlo |
| Si algo falla | No inventa incidentes; no repite publicaciones; sin protocolo, propone la severidad inicial | Comportamiento seguro ante errores |

**Cambiar la regla de horario.** Edita solo el texto entre `REGLA-HORARIO: inicio` y `REGLA-HORARIO: fin`, guarda y **vuelve a publicar** el agente. Fuera de ese bloque no hay horas ni zona horaria, así que el resto no cambia.

✅ **Siga cuando:** el agente existe en `en-US`, con las instrucciones pegadas, `Protocolos` como único conocimiento y el conocimiento general y la web desactivados.

---

### Paso 8. Herramienta `LeerIncidente`

**Qué se hace:** un flujo del agente que lee un incidente de la lista por su `EventId` y se lo devuelve al agente.

1. En el agente: *Tools* → *Add a tool* → *New agent flow* ([Create an agent flow](https://learn.microsoft.com/microsoft-copilot-studio/advanced-flow-create)).
2. Disparador *When an agent calls the flow*, con una entrada de texto `eventId` y la descripción "Identificador UUID del incidente, tal como llega en el mensaje Nuevo incidente". El orquestador usa esa descripción para saber qué pasar.
3. Acción de SharePoint *Send an HTTP request to SharePoint*, renombrada `LeerElemento`, método `GET`, encabezado `Accept: application/json;odata=nometadata` y esta URI:

   ```text
   _api/web/lists/getbytitle('Eventos de seguridad')/items?$select=EventId,TipoEvento,Zona,NombreZona,Sitio,SeveridadInicial,Repeticiones,FechaEventoUtc,Estado&$filter=EventId eq '<eventId>'&$top=1
   ```

   | Parte | Qué hace |
   | --- | --- |
   | `getbytitle('Eventos de seguridad')/items` | La colección de elementos de la lista |
   | `$select=...` | Solo las columnas que necesita el agente. Menos datos, respuesta más rápida, y el agente no ve lo que no debe usar |
   | `$filter=EventId eq '<eventId>'` | El incidente exacto. `EventId` está indexada, así que la búsqueda es rápida |
   | `$top=1` | Como mucho un resultado: `EventId` es única |
   | `odata=nometadata` | Respuesta JSON sin metadatos de OData: más corta y fácil de leer en el flujo |

4. *Respond to the agent* con una salida de texto `incidente` que incluya esos campos y `HoraLocal` en formato `HH:mm COT`, calculada con `convertFromUtc(<FechaEventoUtc>, 'SA Pacific Standard Time', 'HH:mm')` ([convertFromUtc](https://learn.microsoft.com/azure/logic-apps/workflow-definition-language-functions-reference#convertFromUtc)). `SA Pacific Standard Time` es la zona de Windows para UTC−05:00 (Bogotá, Lima, Quito). Así el agente no tiene que calcular la hora local.
5. Activa el **modo rápido**: el flujo no espera nada y responde en pocos segundos ([Express mode](https://learn.microsoft.com/microsoft-copilot-studio/agent-flow-express-mode#limitations)).
6. **Guarda el borrador antes de publicar.** Una expresión agregada a una salida de *Respond to the agent* se pierde si publicas sin guardar.

✅ **Siga cuando:** el flujo está publicado y, probado con el `eventId` de un incidente de prueba, devuelve los campos y `HoraLocal`.

---

### Paso 9. Herramienta `PublicarIncidente`

**Qué se hace:** el flujo que registra la propuesta, publica la tarjeta, espera la decisión del supervisor y la registra. Es la pieza que hace cumplir las reglas aunque el agente se equivoque ([ADR-008](adr/ADR-008-publicacion-tarjeta-y-decision.md)).

**No puede ir en modo rápido:** espera hasta 15 minutos la respuesta de la tarjeta, y el modo rápido no admite esperas.

#### 9.1 Generar la definición desde el repositorio

La definición del flujo se genera desde las tarjetas versionadas en `cards/`, con los identificadores de tu tenant como parámetros:

```powershell
python -m agent.flows.build_publicar_incidente --site-url <URL del sitio> --team-id <groupId del equipo> `
    --channel-id <id del canal> --sharepoint-reference <nombre lógico de la referencia de SharePoint> `
    --teams-reference <nombre lógico de la referencia de Teams> --out <archivo fuera del repositorio>
```

**Por qué se genera y no se dibuja a mano.** Las tarjetas son JSON largos que se arman con expresiones. Generarlos desde `cards/` garantiza que el flujo publica exactamente las tarjetas que validan las pruebas, y que ningún identificador del tenant queda en el repositorio: se pasan al ejecutar y el resultado se guarda **fuera** del repositorio.

El archivo resultante es el `clientdata` del flujo. Se crea de una de dos formas:

- **Con la API de Dataverse** ([Work with cloud flows using code](https://learn.microsoft.com/power-automate/manage-flows-with-code#create-a-cloud-flow)): `POST` a `workflows` con `category = 5`, `type = 1`, `primaryentity = none`, `name = PublicarIncidente`, el `clientdata` y el encabezado `MSCRM.SolutionUniqueName: DelSensorAlAgente`. El flujo queda en borrador.
- **En el diseñador**, siguiendo la misma estructura, explicada abajo.

#### 9.2 Qué hace el flujo, acción por acción

**Entradas** (las llena el agente con *Dynamically fill with AI*):

| Clave | Entrada | Obligatoria |
| --- | --- | --- |
| `text` | `eventId` | Sí |
| `text_1` | `severidadPropuesta` | Sí |
| `text_2` | `justificacionSeveridad` | Sí |
| `text_3` | `resumen` | Sí |
| `text_4` | `pasosProtocolo` | No |
| `text_5` | `protocoloAplicado` | No |

**Acciones:**

1. **`LeerElemento`.** Lee el incidente por `EventId`, igual que `LeerIncidente`, más el `Id` del elemento.
2. **`Si_estado_es_Nuevo`.** Si el estado **no** es `Nuevo`, responde `ya publicado` y termina. Es la **idempotencia**: si el agente llama dos veces, no se publican dos tarjetas.
3. **`Ord_inicial`, `Ord_propuesta`, `Ord_final`, `Severidad_final`.** Convierten las severidades a números (`Baja` 0, `Media` 1, `Alta` 2, `Crítica` 3) y **limitan la propuesta a un nivel** de la inicial:

   ```text
   if(propuesta − inicial > 1)  → inicial + 1
   if(propuesta − inicial < −1) → inicial − 1
   en otro caso                 → propuesta
   ```

   Si el agente propone algo fuera de la escala, se toma la inicial. **Este es el control de diseño**: aunque el agente se equivoque, la severidad que llega al supervisor nunca se aleja más de un nivel.
4. **`Actualizar_pendiente`.** Escribe en la lista `Estado = Pendiente de decisión`, la severidad final, la justificación, el resumen, el protocolo y `PublicacionSolicitadaUtc`. Los textos se recortan (resumen a 1 000 caracteres, justificación a 500) y se escapan como cadena JSON.
5. **`Armar_tarjeta`.** Elige `incidente-alta.json` si la severidad final es `Alta` o `Crítica`, o `incidente-normal.json` en otro caso, y reemplaza los marcadores `{{campo}}` por los valores escapados.
6. **`Responder_publicado`.** Responde `publicado` al agente **antes** de esperar al supervisor. Así el agente termina en segundos y no queda ocupado 15 minutos.
7. **`Publicar_tarjeta_y_esperar`.** *Post adaptive card and wait for a response*, como *Flow bot*, en el canal, con `limit.timeout = PT15M` ([Post adaptive card and wait for a response](https://learn.microsoft.com/connectors/teams/#post-adaptive-card-and-wait-for-a-response)).
8. **Rama de respuesta:**
   - `Leer_estado_actual` y `Si_sigue_pendiente`: solo registra si el incidente sigue en `Pendiente de decisión`. Una segunda respuesta a un incidente ya resuelto se ignora.
   - `Asegurar_usuario`: llama a `_api/web/ensureuser` con el usuario que respondió. La columna `DecididoPor` es de tipo persona, y SharePoint necesita el ID de ese usuario en el sitio.
   - `Registrar_decision`: escribe `Estado` (`Atendido`, `Escalado` o `Falsa alarma`), `Decision`, `DecididoPor`, `FechaDecision` y `Observacion`.
   - `Armar_tarjeta_solo_lectura` y `Publicar_solo_lectura`: publican la tarjeta de solo lectura con la decisión, quién y a qué hora.
9. **Rama de vencimiento** (se ejecuta solo si la espera termina en `TimedOut`):
   - Si el incidente sigue pendiente, escribe `Estado = Sin respuesta` y publica `sin-respuesta.json`. **No registra ninguna decisión por defecto.**
   - `Terminar_sin_respuesta`: acción *Terminate* con estado `Succeeded`. Sin ella, la ejecución quedaría como fallida, aunque el vencimiento es un resultado esperado ([Terminate action](https://learn.microsoft.com/azure/logic-apps/logic-apps-workflow-actions-triggers#terminate-action)).

#### 9.3 Las tarjetas

| Archivo | Cuándo |
| --- | --- |
| `cards/incidente-normal.json` | Severidad propuesta `Baja` o `Media` |
| `cards/incidente-alta.json` | `Alta` o `Crítica`: contenedor con estilo `attention` y la severidad escrita en texto |
| `cards/incidente-solo-lectura.json` | Reemplazo tras la decisión, sin botones ni campos |
| `cards/sin-respuesta.json` | Aviso al vencer los 15 minutos |

Son **Adaptive Cards 1.5**, la versión que admite Teams. Power Automate no admite la función de plantillas de Adaptive Cards (`${...}`), así que el flujo reemplaza marcadores `{{campo}}`. Los marcadores siempre van dentro de una cadena JSON, de modo que cada archivo es JSON válido aun sin reemplazar, y las pruebas lo validan contra el esquema oficial. Las tarjetas usan solo `Action.Submit` con tres decisiones (`Atender`, `Escalar a autoridades`, `Falsa alarma`), un campo opcional `observacion` y pesan menos de ~28 KB, el límite de mensaje del conector. El detalle de cada marcador está en [cards/README.md](../cards/README.md).

#### 9.4 Reglas que salen de la integración

1. **El dueño del flujo y de las conexiones debe ser la misma cuenta.** Con otra cuenta, activar el flujo falla con `ConnectionAuthorizationFailed`. Si lo creas con la API desde otra cuenta, asigna `agente-dsa` como dueño en la misma petición (`ownerid@odata.bind`) y actívalo con la sesión de `agente-dsa`.
2. **Ninguna expresión puede pasar de 8 192 caracteres** ([flow definition limits](https://learn.microsoft.com/power-automate/limits-and-config#flow-definition-limits)). Por eso la plantilla de la tarjeta va como objeto en su propio *Compose* y los valores escapados en otro.
3. **Si el diseñador tiene un borrador sin publicar, la API rechaza la actualización** (`0x80040203`). Publica primero desde el diseñador.

✅ **Siga cuando:** `PublicarIncidente` está activo, pertenece a `agente-dsa` y usa las dos referencias de conexión.

---

### Paso 10. Flujo `DisparoAgente`

**Qué se hace:** el flujo de nube que recibe el `eventId` desde la Function y ejecuta el agente.

1. Crea en la solución un flujo instantáneo con el disparador *When an HTTP request is received*.
2. En *Who can trigger the flow*, elige **Specific users in my tenant** con dos object IDs: el de `id-dsa-func` (`<objectId>` del paso 4) y el de tu cuenta de operador, que usan `demo/retrigger.ps1` y `demo/inject.ps1` ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication)).
3. El cuerpo esperado es solo `{"eventId": "..."}`. Un solo dato, para que nadie pueda inyectar instrucciones al agente por este camino.
4. Agrega la acción *Execute Agent* del conector de Copilot Studio (en la búsqueda aparece como *Power Virtual Agents*) con el agente "Agente de Operaciones" y el mensaje `Nuevo incidente <eventId>` ([Call Copilot Studio agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)).
5. Responde `202` sin esperar al agente.
6. Copia la URL del disparador en `DSA_FLOW_URL` de `.env`.

**Por qué no hay una URL con firma.** Un disparador HTTP clásico se protege con una firma en la URL (`sig=`): quien tenga la URL puede llamarlo. Aquí el disparador exige un **token de Microsoft Entra ID** de una de las dos identidades autorizadas. Aunque la URL se filtre, no sirve sin el token. Por eso el código y `deploy.ps1` rechazan cualquier URL con `sig=`.

✅ **Siga cuando:** el flujo está activo, el disparador tiene exactamente los dos object IDs y `DSA_FLOW_URL` está en `.env`.

---

### Paso 11. Publicar el agente

1. En el agente: *Tools* → *Add a tool* → *Agent flow*, agrega `LeerIncidente` y `PublicarIncidente` ([Add an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/flow-agent)).
2. En `PublicarIncidente`, usa *Agregar entrada* para incluir también `pasosProtocolo` y `protocoloAplicado`: son opcionales y no aparecen solos. Las seis entradas se llenan con *Dynamically fill with AI*.
3. Escribe la descripción de cada herramienta. El orquestador la usa para decidir cuándo llamarla ([Authoring descriptions](https://learn.microsoft.com/microsoft-copilot-studio/advanced-generative-actions#authoring-descriptions)). La de `PublicarIncidente` está en la [guía del agente](../agent/GUIA-CONFIGURACION.md#paso-7-agregar-las-herramientas-al-agente).
4. **Publica el agente** ([Publish and deploy your agent](https://learn.microsoft.com/microsoft-copilot-studio/publication-fundamentals-publish-channels)). Cada cambio en las instrucciones o en las herramientas exige volver a publicar.

✅ **Siga cuando:** el agente está publicado con exactamente dos herramientas.

---

### Paso 12. Conectar Azure con Microsoft 365

**Qué se hace:** volver a desplegar Azure, ahora con los tres datos que faltaban.

```powershell
./infra/deploy.ps1 -GraphSiteId '<siteId>' -GraphListId '<listId>' -AgentFlowUrl '<URL de DisparoAgente>'
```

El despliegue es **idempotente**: no recrea recursos, solo actualiza las app settings `DSA_GRAPH_SITE_ID`, `DSA_GRAPH_LIST_ID` y `DSA_FLOW_URL` de la Function. Desde aquí la Function ya sabe dónde crear el incidente y a quién avisar.

✅ **Siga cuando:** en el portal, la Function App muestra las tres app settings con valor.

---

### Paso 13. Registrar los dispositivos

```powershell
az iot hub device-identity create --hub-name <iotHub> --device-id sim-01 --auth-type login
az iot hub device-identity create --hub-name <iotHub> --device-id preflight-01 --auth-type login
az iot hub device-identity connection-string show --hub-name <iotHub> --device-id sim-01 --auth-type login --query connectionString -o tsv
az iot hub device-identity connection-string show --hub-name <iotHub> --device-id preflight-01 --auth-type login --query connectionString -o tsv
```

| Detalle | Por qué |
| --- | --- |
| Dos dispositivos | `sim-01` es el de la demo. `preflight-01` es el de las pruebas automáticas: la Function marca `EsPrueba = Sí` en sus incidentes, y `demo/reset.ps1` los limpia sin tocar los demás |
| `--auth-type login` | La CLI usa tu sesión de Entra ID (el rol *IoT Hub Registry Contributor* que te dio la plantilla), no la política `iothubowner`, que no existe en este hub |
| Una clave por dispositivo | Si un dispositivo se compromete, se revoca solo ese |

Pega la primera cadena en `IOTHUB_DEVICE_CONNECTION_STRING` y la segunda en `IOTHUB_PREFLIGHT_CONNECTION_STRING`, en `.env`.

**Por qué `EsPrueba` no se puede falsificar.** La Function no lee la marca de prueba del cuerpo del mensaje. La lee de los metadatos que pone IoT Hub (`connection-device-id`), que dicen qué identidad se conectó de verdad. Un mensaje no puede hacerse pasar por prueba escribiéndolo en su JSON.

✅ **Siga cuando:** los dos dispositivos aparecen habilitados en IoT Hub y las dos cadenas están en `.env`.

---

### Paso 14. Prueba de punta a punta

**Encender la instancia y enviar el primer evento:**

```powershell
./infra/set-always-ready.ps1 -Scenario ensayo -ResourceGroup rg-dsa-demo
python -m simulator --type puerta_forzada --zone Z-03
```

La consola responde `Enviados 1 evento(s) puerta_forzada desde DEV-SIM-01 en Z-03 (severidad Alta) en ... s.` y el `eventId`.

**Comprueba en orden** (es el mismo orden del recorrido del evento):

| # | Dónde | Qué debes ver |
| --- | --- | --- |
| 1 | Lista `Eventos de seguridad` | Un elemento `puerta_forzada · Z-03` en `Nuevo`, que pasa a `Pendiente de decisión` |
| 2 | Historial de `DisparoAgente` | Una ejecución con respuesta 202 |
| 3 | *Activity* del agente | Llamó a `LeerIncidente`, consultó el protocolo y llamó a `PublicarIncidente` ([Review agent activity](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity)) |
| 4 | Canal `Centro de operaciones` | La tarjeta "Propuesta del Agente de Operaciones", con `Ref.` igual al `eventId` de la consola |
| 5 | Lista, tras pulsar un botón | `Estado`, `Decision`, `DecididoPor`, `FechaDecision` y `Observacion`, y la tarjeta de solo lectura en el canal |

**Probar la deduplicación** (espera al menos 60 s desde el evento anterior del mismo tipo):

```powershell
python -m simulator --type movimiento_zona_restringida --zone Z-01 --burst 20
```

Resultado: **un solo** incidente con `Repeticiones = 20` y **una sola** tarjeta.

**Medir los tiempos:**

```powershell
./demo/measure.ps1 -Last 10
```

Une los elementos de la lista con los mensajes del canal por el texto `Ref. {eventId}` de la tarjeta y calcula los percentiles. La meta es p90 de 30 s o menos, y nunca más de 60. En 10 ensayos del 2026-10-26 el p90 fue de 22,6 s y el máximo, de 36,1 s. El tramo de Azure se mide con más precisión con la consulta [infra/queries/tramo1.kql](../infra/queries/tramo1.kql) en Application Insights.

**Al terminar, apaga la instancia:**

```powershell
./infra/set-always-ready.ps1 -Scenario reposo -ResourceGroup rg-dsa-demo
```

✅ **Siga cuando:** la tarjeta llega en 60 s o menos, la decisión queda en la lista y la ráfaga produce un solo incidente con 20 repeticiones. La solución está completa.

---

## Parte 4 · El código, archivo por archivo

Esta parte explica qué hace cada pieza de código, por qué está escrita así y para qué sirve. Las pruebas de cada módulo están en `tests/`.

### 4.1 El contrato del evento: `schemas/evento-dispositivo.schema.json`

```json
"additionalProperties": false,
"required": ["schemaVersion", "eventId", "deviceId", "type", "zone", "timestamp", "rawSeverity"]
```

| Campo | Regla | Por qué |
| --- | --- | --- |
| `schemaVersion` | Siempre `1.0` | Permite cambiar el formato en el futuro sin romper lo que existe |
| `eventId` | UUID | Identifica el evento en todo el recorrido: lista, registros y tarjeta |
| `deviceId` | `DEV-` + mayúsculas, dígitos y guiones, máximo 32 | Identificador del dispositivo dentro del mensaje |
| `type` | Uno de los tres tipos | Solo los eventos que tienen protocolo |
| `zone` | `Z-` + dos dígitos | Se enriquece con el catálogo de zonas |
| `timestamp` | ISO 8601 en UTC con `Z` | Hora del evento según el dispositivo |
| `rawSeverity` | `Baja`, `Media`, `Alta` o `Crítica` | Severidad que reporta el dispositivo |

**`additionalProperties: false` es una decisión de privacidad.** El evento no tiene ningún campo de texto libre y no admite campos de más. Por diseño, un dispositivo no puede enviar nombres, descripciones ni datos personales.

### 4.2 El catálogo de zonas: `data/zonas.json`

Seis zonas ficticias. Cada una tiene nombre, cámara, sitio y una **severidad base**:

```json
{ "zone": "Z-01", "zoneName": "Sala de servidores", "cameraId": "CAM-01", "site": "Sede Demo Centro", "baseSeverity": "Alta" }
```

La severidad base expresa qué tan sensible es el lugar: un movimiento en la sala de servidores pesa más que en el parqueadero.

### 4.3 El simulador: `simulator/`

| Archivo | Qué hace |
| --- | --- |
| `message.py` | Arma el evento (`build_event`) con un `eventId` UUID nuevo y la hora actual en UTC con milisegundos, y lo valida contra el mismo esquema que usa la Function (`validate_event`). Si no se indica `--severity`, usa una por tipo: `puerta_forzada` Alta, los otros dos Media |
| `cli.py` | Lee y valida los argumentos (`--type`, `--zone`, `--burst` de 1 a 100, `--device`, `--severity`), arma y valida **todos** los eventos antes de abrir la conexión, los envía y muestra los `eventId` |
| `transport.py` | Envía cada evento como mensaje de dispositivo con `azure-iot-device` por MQTT, con `content_type = application/json` y `content_encoding = utf-8`, para que IoT Hub lea el cuerpo como JSON |

**Detalles de diseño:**

- La cadena de conexión se lee de la variable `IOTHUB_DEVICE_CONNECTION_STRING` o del `.env`. Nunca es un argumento: así no queda en el historial de la consola.
- Si el envío falla, el mensaje de error muestra **solo el tipo del error**, nunca el detalle, que podría incluir la cadena de conexión.
- Códigos de salida: 0 envío correcto, 1 fallo de envío, 2 argumentos no válidos, 3 falta configuración. Permiten usarlo desde otros scripts.
- `--burst 20` envía los 20 eventos seguidos, sin pausas: simula un sensor ruidoso.

### 4.4 La entrada de la Function: `function/function_app.py`

```python
@app.function_name(name="ingest_event")
@app.retry(strategy="exponential_backoff", max_retry_count="3",
           minimum_interval="00:00:05", maximum_interval="00:00:30")
@app.event_hub_message_trigger(arg_name="event", event_hub_name="iothub-builtin-endpoint",
                               connection="IoTHubConnection", consumer_group="func", cardinality="one")
def ingest_event(event: func.EventHubEvent, context: func.Context) -> None:
```

| Línea | Qué hace | Por qué |
| --- | --- | --- |
| `event_hub_message_trigger` | La Function se despierta con cada mensaje del endpoint integrado de IoT Hub, que es compatible con Event Hubs | Es la forma estándar de leer IoT Hub desde Functions |
| `connection="IoTHubConnection"` | Nombre de la app setting con la cadena | Esa app setting es una referencia a Key Vault (paso 4). La cadena incluye `EntityPath`, que reemplaza a `event_hub_name` al ejecutar |
| `consumer_group="func"` | Lee con su propio grupo de consumidores | No compite con otros lectores |
| `cardinality="one"` | Un evento por invocación | Cada evento tiene su propia ventana, su propio reintento y su propio registro |
| `@app.retry(...)` | Si el procesamiento lanza una excepción, el runtime reintenta 3 veces con espera exponencial de 5 a 30 s ([retry policies](https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages#retry-policies)) | Cubre fallas pasajeras de Graph o del flujo |
| `func.EventHubEvent` | Tipo del mensaje | Da acceso a `enqueued_time`, la hora en que IoT Hub recibió el mensaje |
| `iothub_metadata["connection-device-id"]` | La identidad que se conectó | Marca `EsPrueba` sin confiar en el cuerpo del mensaje |

`_pipeline()` arma la cadena de procesamiento **una vez por instancia** (`lru_cache`) y sin llamadas de red, para que cada evento solo pague su propio trabajo. Usa `ManagedIdentityCredential(client_id=...)`: todos los tokens (Table Storage, Graph, el flujo) salen de `id-dsa-func`.

`logging.getLogger("azure").setLevel(logging.WARNING)` silencia los registros detallados de los SDK de Azure, que escriben cada petición HTTP con sus encabezados. Así no se gasta el límite diario de Log Analytics.

`host.json` desactiva el muestreo de Application Insights: cada registro llega, y las mediciones de tiempo son completas.

### 4.5 La cadena de procesamiento: `function/core/pipeline.py`

El orden de los pasos es la decisión más importante del código:

```text
1. validar → 2. reclamar la ventana → 3. tomar cupo del minuto → 4. enriquecer
→ 5. crear el elemento en SharePoint → 6. disparar al agente
(repetición: 7. actualizar Repeticiones)
```

**Por qué este orden.**

- **Validar primero.** Un evento inválido no consume nada: ni tabla, ni Graph, ni créditos.
- **El registro antes que el agente.** El incidente existe en la lista **antes** de que el agente lo vea. Si el agente falla, el incidente queda en `Nuevo`, visible y recuperable con `demo/retrigger.ps1`. Nunca hay una tarjeta sin registro.
- **Cada paso es idempotente.** La cabecera de la ventana guarda tres marcas: `quotaTaken`, `itemId` y `flowTriggered`. Si el runtime reentrega el mismo evento tras una caída, la Function solo hace lo que falta: no toma otro cupo, no crea otro elemento, no dispara otra vez al agente.

**Cómo maneja cada error:**

| Situación | Resultado | Por qué |
| --- | --- | --- |
| Evento inválido o zona desconocida | `EventRejected`, sin excepción | Reintentar no lo arregla |
| Graph responde un 4xx distinto de 429 | `GraphRejected`, sin excepción | Es un problema de permisos o de datos, no pasajero |
| El flujo responde 401 o 403 | `AgentTriggerAuthFailed`, sin excepción | Es configuración. El incidente queda en `Nuevo` y se recupera con `retrigger` |
| Graph saturado, flujo sin respuesta o conflicto de concurrencia | Excepción | Entra el reintento del runtime |
| Último reintento agotado | `EventFailed` y termina | Queda registrado con su `eventId` |

### 4.6 Validar: `function/core/validation.py`

Valida el cuerpo contra el esquema del evento. **Nunca repite el valor recibido** en el motivo del rechazo, solo la ruta y la regla incumplida (`zone: pattern`): un valor inválido podría traer un dato personal. `safe_event_id` solo devuelve el `eventId` si tiene forma de UUID, así nunca se registra texto libre.

### 4.7 Enriquecer y calcular la severidad: `enrich.py` y `severity.py`

```python
def max_severity(raw: str, base: str) -> str:
    return LEVELS[max(level_index(raw), level_index(base))]
```

**Severidad inicial = la mayor entre la del dispositivo y la base de la zona.** Una puerta forzada (Alta) en la bodega norte (base Media) es Alta. Un movimiento (Media) en la sala de servidores (base Alta) es Alta. Es una regla determinista: el agente parte de ella y no la recalcula. `enrich` agrega además el nombre de la zona, la cámara y el sitio. Una zona fuera del catálogo se trata como evento inválido.

### 4.8 Deduplicar: `function/core/dedup.py`

**El problema:** un sensor ruidoso envía 20 eventos iguales en 10 segundos. Sin deduplicación serían 20 incidentes, 20 tarjetas y 20 ejecuciones del agente.

**La solución:** una ventana fija de 60 segundos por dispositivo y tipo, en Table Storage ([ADR-006](adr/ADR-006-deduplicacion.md)).

| Fila | PartitionKey | RowKey | Guarda |
| --- | --- | --- | --- |
| Cabecera de la ventana | `{deviceId}\|{type}` | `current` | `windowId` (el `eventId` del primer evento), `windowStartUtc`, `state`, `itemId`, `flowTriggered`, `quotaTaken` |
| Un evento de la ventana | `w\|{windowId}` | `{eventId}` | `enqueuedTimeUtc` |

**Cómo decide (`claim`):**

- No hay cabecera, o la ventana tiene 60 s o más: **abre** una ventana nueva. Este evento crea el incidente.
- La ventana está abierta: es una **repetición**. Se inserta su fila y `Repeticiones` es el número de filas de la ventana.
- El evento es de una ventana ya cerrada que llega tarde: no se cuenta.

**Por qué el reloj es la hora de IoT Hub** (`enqueuedTimeUtc`) y no la del dispositivo: un sensor con el reloj desajustado no puede abrir ni cerrar ventanas.

**Por qué las filas cuentan las repeticiones.** Contar filas es idempotente: si el runtime reentrega un evento, su fila ya existe (`EntityExists`) y no suma de nuevo.

**Concurrencia optimista con ETag.** Dos instancias podrían procesar dos eventos de la misma ventana a la vez. Cada actualización de la cabecera va con `If-Match` (su ETag). Si otra ejecución la cambió primero, la escritura falla con `412`, el código relee y vuelve a intentar, hasta 5 veces.

### 4.9 Limitar por minuto: `function/core/ratelimit.py`

Una fila por minuto de reloj (`PartitionKey = minute`, `RowKey = yyyyMMddHHmm` en UTC) con un contador. Solo la **apertura** de un incidente toma cupo; las repeticiones no. Con el cupo agotado, la ventana queda `discarded` y el evento se registra como `IncidentDiscarded`. Usa el mismo patrón de ETag que la deduplicación.

**Para qué:** protege los créditos y al supervisor ante una tormenta de eventos. Al ser ventanas fijas de reloj, en el cambio de minuto pueden crearse hasta 20 incidentes en 60 s; ADR-006 lo acepta para la demo.

### 4.10 Armar el incidente: `function/core/listitem.py`

`build_create_fields` arma los 15 campos que escribe la Function al crear el incidente (`Estado = Nuevo`, `Repeticiones = 1`, `RecibidoUtc` con milisegundos) y los **valida contra `sharepoint/columnas.json`** antes de enviarlos: tipo, opciones permitidas, patrón y si la Function tiene permiso para escribir esa columna. Si algo no cumple, falla en la Function, no en SharePoint. El error nombra la columna y el tipo, nunca el valor.

### 4.11 Escribir en SharePoint: `function/core/graph_client.py`

| Operación | Llamada de Graph |
| --- | --- |
| Crear el incidente | `POST /sites/{site-id}/lists/{list-id}/items` ([listitem-create](https://learn.microsoft.com/graph/api/listitem-create)) |
| Actualizar `Repeticiones` | `PATCH .../items/{item-id}/fields` ([listitem-update](https://learn.microsoft.com/graph/api/listitem-update)) |
| Buscar por `EventId` | `GET .../items?$filter=fields/EventId eq '...'` |

**Reintentos:** ante 429 o 5xx, espera lo que indique `Retry-After`; sin esa cabecera, 0,5 s, 1 s y 2 s con una variación aleatoria ([throttling](https://learn.microsoft.com/graph/throttling#best-practices-to-handle-throttling)). El total de espera tiene un **presupuesto de 6 segundos**, para no romper la meta de latencia; si se agota, entra el reintento del runtime. Un 4xx distinto de 429 no se reintenta.

**Conflicto de unicidad:** si `EventId` ya existe (una reentrega tras una caída), busca el elemento existente y sigue con él.

El token se pide a la credencial en cada llamada (la librería lo guarda en caché) y **nunca se registra** ni se incluye en un error.

### 4.12 Disparar al agente: `function/core/flow_trigger.py`

```python
FLOW_SCOPE = "https://service.flow.microsoft.com//.default"
```

**La doble barra no es un error.** La audiencia que exige el disparador es `https://service.flow.microsoft.com/`, que termina en barra, y el ámbito `.default` se agrega después: queda con doble barra ([trailing slash and .default](https://learn.microsoft.com/entra/identity-platform/scopes-oidc#trailing-slash-and-default), [audience values](https://learn.microsoft.com/power-automate/oauth-authentication#audience-values)).

| Regla | Por qué |
| --- | --- |
| La URL debe ser `https` y **no** puede llevar `sig=` | El disparador se protege con Entra ID, no con una firma en la URL |
| Cuerpo: solo `{"eventId": ...}` | Un solo dato; nada que el agente pueda interpretar como instrucción |
| 3 intentos, con esperas de 1 s y 2 s, ante 429, 5xx o tiempo agotado (10 s) | Fallas pasajeras |
| 401 o 403: no se reintenta | Es configuración: el object ID no está en el disparador, o la identidad cambió |
| En los registros solo aparece el host | La URL completa identifica el tenant |

### 4.13 Registrar: `function/core/telemetry.py`

Cada registro es una línea `"{Nombre} {json}"` con el `eventId` como hilo de correlación: `EventRejected`, `IncidentCreated`, `RepetitionCounted`, `IncidentDiscarded`, `AgentTriggered`, `AgentTriggerAuthFailed`, `GraphRejected` y `EventFailed`. La consulta [tramo1.kql](../infra/queries/tramo1.kql) lee ese JSON para medir el tramo de Azure. **Defensa en profundidad:** solo acepta campos conocidos y valores escalares, y redacta cualquier valor con forma de token.

### 4.14 Configuración: `function/core/settings.py`

Lee las app settings y falla con `ConfigurationError` si falta alguna obligatoria. El mensaje **nombra las variables, nunca sus valores**. Así, en el paso 4, un evento enviado antes de tiempo deja un error claro en los registros.

### 4.15 Los scripts de PowerShell

| Archivo | Qué hace |
| --- | --- |
| `infra/lib/DsaInfra.psm1` | Funciones compartidas de `infra/`. Toda llamada a `az` pasa por `Invoke-DsaAz`, que se puede simular en las pruebas de Pester (`infra/tests/`). Ninguna función imprime ni guarda secretos |
| `sharepoint/ProvisionLogic.psm1` | Lógica de `provision.ps1`: comparar columnas, armar los cuerpos de Graph, calcular hashes de los protocolos. Probada en `sharepoint/tests/` |
| `demo/*.psm1` | Lógica de `preflight`, `reset` y `retrigger`, probada en `demo/tests/` |

El patrón es siempre el mismo: **la lógica en un módulo sin red, probada; el script solo orquesta**. Así cada regla se comprueba en CI sin un tenant.

### 4.16 Integración continua: `.github/workflows/ci.yml`

Cuatro trabajos en cada push: Python (`ruff` y `pytest`), secretos (`gitleaks` sobre **todo el historial**, con las excepciones justificadas de `.gitleaks.toml`), Bicep (compilación y lint) y PowerShell 7 (Pester).

---

## Parte 5 · Operación diaria

| Comando | Para qué | Cuándo |
| --- | --- | --- |
| `./infra/set-always-ready.ps1 -Scenario ensayo` o `sesion` | Enciende una instancia *always ready* (sin arranque en frío) | Antes de ensayar o presentar |
| `./infra/set-always-ready.ps1 -Scenario reposo` | La apaga: vuelve al costo de centavos | Siempre al terminar. Si se olvida encendida todo el mes, el costo de Azure pasa de unos USD 0,40 a unos USD 7,90 ([costos.md](costos.md)) |
| `./demo/preflight.ps1` | Comprueba todos los componentes en 3 minutos o menos, en verde, amarillo o rojo, con una prueba de punta a punta marcada `EsPrueba` | Antes de cada ensayo o sesión |
| `./demo/reset.ps1` | Manda a la papelera los incidentes de prueba y vacía `dedup` y `ratelimit`. Con `-All`, todos los incidentes. Nunca borra definitivamente | Antes de empezar, para que el primer evento abra un incidente |
| `./demo/retrigger.ps1 -EventId <id>` | Vuelve a disparar al agente para un incidente en `Nuevo`. Si ya avanzó, no hace nada | Cuando la Function no pudo llamar al flujo |
| `./demo/inject.ps1 -Type <tipo> -Zone <zona>` | Contingencia sin Azure: crea el incidente con los mismos campos que la Function y dispara al agente con tu sesión | Si falla el tramo de Azure |
| `./demo/measure.ps1 -Last 10` | Mide la latencia de los últimos incidentes | Después de los ensayos |
| `./infra/rotate-iothub-key.ps1 -TargetKey secondary` | Rota la clave de `func-reader` sin cortar la ingesta. Azure compone el secreto nuevo; la clave nunca pasa por la consola. Alterna `primary` y `secondary` en cada rotación | Periódicamente, o si sospechas de la clave |

El guion completo de una sesión en vivo está en [demo/RUNBOOK.md](../demo/RUNBOOK.md).

---

## Parte 6 · Solución de problemas

| Síntoma | Causa probable | Solución |
| --- | --- | --- |
| `ConfigurationError: Faltan app settings` en los registros | Se enviaron eventos antes del paso 12 | Ejecuta el paso 12 |
| El incidente se queda en `Nuevo` y hay `AgentTriggerAuthFailed` | El object ID de `id-dsa-func` no está en el disparador de `DisparoAgente`, o cambió tras redesplegar | Revisa *Specific users in my tenant* (paso 10) y recupera con `./demo/retrigger.ps1 -EventId <id>` |
| `GraphRejected` con 403 | Falta `Sites.Selected` sobre el sitio, o el sitio no es el correcto | Repite el paso 5 y revisa `DSA_GRAPH_SITE_ID` |
| No llega nada a la Function | Ruta de respaldo desactivada o cadena de Key Vault sin resolver | Revisa `fallbackRoute` en IoT Hub y la referencia `IoTHubConnection` en la Function App |
| El despliegue falla en IoT Hub | La suscripción ya tiene un hub F1 | `./infra/deploy.ps1 -IotHubSku B1` |
| La tarjeta no se publica | El canal es privado, o falta la app *Workflows* | Usa un canal estándar y permite *Workflows* en Teams |
| `ConnectionAuthorizationFailed` al activar un flujo | El dueño del flujo y el de las conexiones son cuentas distintas | Todo debe pertenecer a `agente-dsa` (paso 9.4) |
| La API rechaza el flujo con `0x80040203` | Hay un borrador sin publicar en el diseñador | Publica desde el diseñador |
| Error de expresión de más de 8 192 caracteres | Plantilla de tarjeta en una sola expresión | Plantilla y valores en *Compose* separados (paso 9.4) |
| La salida de `LeerIncidente` perdió una expresión | Se publicó sin guardar el borrador | Guarda el borrador y publica de nuevo |
| El agente responde en inglés | Faltan las instrucciones de idioma | Pega el bloque completo de instrucciones y publica |
| La tarjeta usa la regla anterior | El agente no se volvió a publicar | Publica el agente; cada cambio lo exige |
| En la notificación de Teams se ve "Card - access it on go.skype.com/cards.unsupported" | Teams no muestra tarjetas en las notificaciones | Es esperado: en el canal la tarjeta se ve completa |
| La ráfaga crea dos incidentes | Pasaron más de 60 s, o el `reset` no vació `dedup` | Envía la ráfaga en menos de 60 s y ejecuta `./demo/reset.ps1` antes |

---

## Parte 7 · Limpieza

```powershell
./infra/set-always-ready.ps1 -Scenario reposo
./infra/destroy.ps1
```

`destroy.ps1` muestra los recursos, **pide confirmación**, borra el grupo de recursos completo y purga el Key Vault en borrado temporal (para poder redesplegar con el mismo nombre). En Bash: `infra/destroy.sh`.

Al borrar el grupo desaparece `id-dsa-func` con sus permisos. Si vuelves a desplegar, repite el paso 5 y actualiza el object ID en el disparador de `DisparoAgente`.

En Microsoft 365, borra o desactiva a mano:

1. El vínculo del entorno con el plan de pago por uso. Desde ese momento no se factura.
2. La solución `DelSensorAlAgente`, con el agente y los flujos.
3. La lista `Eventos de seguridad`, la biblioteca `Protocolos` y los sitios, si ya no los necesitas.

---

## Referencias

**Del repositorio:** [README](../README.md) · [Guía del agente](../agent/GUIA-CONFIGURACION.md) · [Instrucciones del agente](../agent/instrucciones.md) · [Tarjetas](../cards/README.md) · [Sites.Selected](admin-sites-selected.md) · [Gobernanza](gobernanza.md) · [Costos](costos.md) · [ADR](adr/) · [Runbook](../demo/RUNBOOK.md) · [Videos](videos.md) · [Especificación](../specs/01-especificacion.md) · [Plan](../specs/02-plan.md)

**Microsoft Learn:**

- [Azure Functions: Flex Consumption con infraestructura como código](https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code?pivots=flex-consumption-plan)
- [Azure Functions: always ready en Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#set-always-ready-instance-counts)
- [Azure Functions: disparador de IoT Hub](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#decorators)
- [Azure Functions: políticas de reintento](https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages#retry-policies)
- [Permisos Sites.Selected de Microsoft Graph](https://learn.microsoft.com/graph/permissions-selected-overview)
- [Autenticación OAuth en disparadores HTTP de Power Automate](https://learn.microsoft.com/power-automate/oauth-authentication)
- [Llamar a agentes de Copilot Studio desde Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)
- [Publicar una tarjeta adaptativa y esperar respuesta en Teams](https://learn.microsoft.com/connectors/teams/#post-adaptive-card-and-wait-for-a-response)
- [Agregar SharePoint como conocimiento de un agente](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint)
- [Revisar la actividad de un agente](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity)
- [Tarifas de Copilot Credits](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)
- [Crear y administrar presupuestos en Azure](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
