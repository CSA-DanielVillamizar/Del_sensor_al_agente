# Del sensor al agente

## Instructivo para asistentes — Microsoft 365 Live 2026

### Sesión del 4 de noviembre de 2026 · Copilot Studio y Teams como centro de operaciones de seguridad física

Gracias por asistir. Este documento tiene tres partes:

1. **Lo que viste en la sesión**, explicado paso a paso, para repasarlo con calma.
2. **Cómo reproducirlo en tu propio tenant**, con una comprobación al final de cada paso.
3. **Preguntas frecuentes, costos, glosario y enlaces** a la documentación oficial.

> **Todos los datos son ficticios:** zonas, cámaras, protocolos y cuentas. No uses datos reales de personas ni de instalaciones para probar este patrón.

### Comparte la sesión

Si publicas algo de esta sesión, usa **#M365Live** y **#Microsoft365Live2026**, menciona a **Microsoft 365 Live** y etiqueta al speaker, Daniel Villamizar:

| Red | Enlace |
| --- | --- |
| LinkedIn | [linkedin.com/in/danielvillamizara](https://www.linkedin.com/in/danielvillamizara/) |
| Instagram | [instagram.com/danielvillamizara](https://www.instagram.com/danielvillamizara/) |
| GitHub | [github.com/CSA-DanielVillamizar](https://github.com/CSA-DanielVillamizar) |

---

## Parte 1 · Lo que viste en la sesión

### 1.1 La idea en una frase

**El agente propone; la persona decide.**

Una alerta de seguridad física llega a Microsoft Teams como una *propuesta*: qué pasó, dónde, qué tan grave y qué dice el protocolo. Un supervisor decide con un botón. La decisión queda registrada con quién, qué y cuándo. Ningún componente ejecuta una acción física ni contacta a nadie.

### 1.2 El problema que resuelve

- **Fatiga de alertas.** Un sensor ruidoso dispara veinte alertas iguales y el operador deja de mirarlas.
- **Falta de contexto.** La alerta dice "puerta 3" pero no qué zona es, qué tan grave es ni qué hacer.
- **Falta de trazabilidad.** Al día siguiente nadie puede reconstruir quién decidió qué.

### 1.3 Las cinco piezas

| # | Pieza | Qué hace |
| --- | --- | --- |
| 1 | **Sensor** | Un simulador en Python envía un evento por MQTT, con la clave propia del dispositivo |
| 2 | **Azure** | IoT Hub recibe el evento. Una Azure Function lo valida contra un esquema cerrado, agrupa los eventos repetidos de 60 s y le agrega zona, sitio, cámara y severidad inicial |
| 3 | **SharePoint** | La Function crea el incidente en la lista `Eventos de seguridad`, que es el registro de auditoría |
| 4 | **Copilot Studio** | Un flujo despierta al agente con el identificador del evento. El agente lee el incidente, consulta el protocolo en la biblioteca `Protocolos` y propone una severidad |
| 5 | **Teams** | La propuesta llega como tarjeta al canal `Centro de operaciones`. El supervisor elige *Atender*, *Escalar a autoridades* o *Falsa alarma* |

### 1.4 Los componentes, uno por uno

Dieciséis componentes en total. Cada uno tiene una sola tarea, y ninguno puede llamar a nadie ni abrir una puerta.

**En Azure**

| Componente | Qué es | Para qué sirve en la solución |
| --- | --- | --- |
| **Simulador** | Programa en Python (`simulator/`) | Hace de sensor. Envía por MQTT un evento JSON de siete campos, sin texto libre, con la clave propia del dispositivo |
| **IoT Hub** | Servicio de Azure para dispositivos | Puerta de entrada. Una identidad y una clave por dispositivo: uno comprometido se revoca sin tocar los demás |
| **Azure Function** `ingest_event` | Código sin servidor, en Python | Valida el evento, deduplica, aplica el tope por minuto, lo enriquece con la zona y la severidad inicial, crea el incidente y despierta al agente |
| **Table Storage** | Almacenamiento de tablas de Azure | Guarda la ventana de 60 s de cada sensor y el cupo de 10 incidentes por minuto. Así 20 eventos iguales son un incidente |
| **Identidad administrada** `id-dsa-func` | Identidad de Microsoft Entra ID gestionada por Azure | Es la identidad de la Function ante Microsoft Graph y el flujo. No tiene contraseña que guardar |
| **Key Vault** | Almacén de secretos de Azure | Guarda el único secreto en la nube: la cadena con la que la Function lee IoT Hub. Ningún secreto va en el código |
| **Application Insights** | Monitoreo de Azure | Registra cada paso con el `eventId`: eventos rechazados, errores y tiempos. Ahí se diagnostica una falla |
| **Presupuesto** | Azure Cost Management | USD 20 al mes con aviso al 80 %. Avisa, pero no detiene el consumo: por eso también hay topes en el diseño |

**En Microsoft 365**

| Componente | Qué es | Para qué sirve en la solución |
| --- | --- | --- |
| **Lista `Eventos de seguridad`** | Lista de SharePoint | El incidente y su registro de auditoría: estado, severidades, decisión, quién y cuándo |
| **Biblioteca `Protocolos`** | Biblioteca de documentos de SharePoint | Un protocolo por tipo de evento, mantenido por el jefe de seguridad. El agente lo consulta, no lo cambia |
| **Flujo `DisparoAgente`** | Flujo de Power Automate con disparador HTTP | Recibe solo el `eventId` y ejecuta el agente. Únicamente la identidad de la Function puede llamarlo |
| **Agente de Operaciones** | Agente de Copilot Studio | Lee el incidente, consulta el protocolo, propone la severidad y redacta el resumen. Nunca decide |
| **`LeerIncidente`** | Herramienta del agente (flujo) | Trae de la lista los datos del incidente: tipo, zona, sitio, severidad inicial, repeticiones y hora |
| **`PublicarIncidente`** | Herramienta del agente (flujo) | Comprueba el tope de un nivel, publica la tarjeta, espera 15 minutos y registra la decisión |
| **Tarjeta en Teams** | Tarjeta adaptativa 1.5 en el canal `Centro de operaciones` | Muestra la propuesta y tres botones: *Atender*, *Escalar a autoridades* y *Falsa alarma* |
| **Cuenta de servicio** `agente-dsa` | Usuario de Microsoft 365 sin roles de administrador | Dueña del agente y de los flujos, con permisos solo sobre la lista, la biblioteca y el equipo |

**El recorrido de un evento:**
1. El simulador envía el evento a IoT Hub.
2. La Function lo valida, lo deduplica y lo enriquece.
3. La Function crea el incidente en la lista y llama a `DisparoAgente`.
4. El agente usa `LeerIncidente`, consulta `Protocolos` y llama a `PublicarIncidente`.
5. La tarjeta llega al canal y el supervisor decide.
6. La decisión queda en la lista.

### 1.5 Los tres actos de la demo

**Acto 1 — El resultado primero**
- Se simuló una **puerta forzada** en la bodega norte. En menos de 30 segundos llegó la tarjeta a Teams. Mostraba la severidad inicial (Alta) y la propuesta del agente (Crítica, porque ocurrió fuera del horario diurno), con su justificación, un resumen y los pasos del protocolo.
- Después se simularon **20 eventos de movimiento iguales** en 10 segundos. Resultado: **un solo incidente** con `Repeticiones = 20` y **una sola tarjeta**. El agente se ejecutó una vez, no veinte.

**Acto 2 — Dentro del agente**
- **Instrucciones:** qué hace, en orden, y una sección "Lo que nunca haces": llamar a nadie, abrir o bloquear accesos, confrontar a alguien, cerrar casos o cambiar protocolos.
- **Conocimiento:** los protocolos en una biblioteca de SharePoint. El agente los consulta; no los cambia.
- **Herramientas:** solo dos, `LeerIncidente` y `PublicarIncidente`. Ninguna envía correos, llama ni abre nada.
- **Disparo:** un flujo HTTP que solo la identidad de la Function puede llamar.
- **Actividad:** la bitácora de cada ejecución del agente, paso a paso.

**Acto 3 — La persona decide**
- El supervisor escribió una observación y pulsó *Escalar a autoridades*. La tarjeta quedó en solo lectura, y la lista registró el estado, la decisión, quién y cuándo. **Nadie fue llamado por el sistema:** la llamada la hace la persona.
- La **regla de horario** se cambió en vivo, con texto, en las instrucciones del agente, y se publicó. El siguiente evento recibió otra propuesta: "sin cambio respecto a la severidad inicial".
- Una tarjeta quedó sin responder a propósito. A los 15 minutos pasa a `Sin respuesta`, **sin ninguna decisión por defecto**.

**Los videos de los tres actos**, con su reseña y subtítulos, están en [videos.md](videos.md).

### 1.6 Qué se automatiza y qué no

| Se automatiza | Lo decide siempre una persona |
| --- | --- |
| Recibir y deduplicar alertas | Llamar a la fuerza pública o a emergencias |
| Clasificar la severidad inicial | Bloquear o abrir accesos físicos |
| Buscar el protocolo que aplica | Confrontar o retener a alguien |
| Redactar el resumen para el supervisor | Declarar una falsa alarma y cerrar el caso |
| Registrar quién decidió qué y cuándo | Cambiar el propio protocolo |

**Criterio para tu organización:** si la acción afecta a otras personas o al mundo físico, la decide una persona. Y no basta con escribirlo en las instrucciones del agente: el diseño debe impedirlo. En esta solución, el agente simplemente no tiene herramientas para llamar, escribir correos ni abrir nada.

### 1.7 Las cifras de la sesión

| Cifra | Qué significa |
| --- | --- |
| **60 s** | Ventana para agrupar eventos iguales del mismo dispositivo y tipo en un solo incidente |
| **10 por minuto** | Tope de incidentes nuevos por minuto; lo que sobra se descarta y se registra |
| **22,6 s** | p90 del evento a la tarjeta visible en 10 ensayos (máximo 36,1 s). Meta: 30 s, nunca más de 60 |
| **15 min** | Tiempo que la tarjeta espera una decisión antes de pasar a `Sin respuesta` |
| **≈ USD 0,40** | Costo de Azure en un mes normal, con la instancia *always ready* apagada |
| **≈ 15 créditos** | Copilot Credits estimados por incidente (planifica con 20) |

---

## Parte 2 · Cómo reproducirlo en tu tenant

Tiempo estimado: **60 minutos**, si ya tienes el tenant, la suscripción, el entorno y las licencias. La guía completa y siempre actualizada es el [README del repositorio](https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente). Aquí va el recorrido con más explicación.

> **Si el enlace del repositorio todavía no abre**, es porque se publica después de la sesión. Vuelve a intentarlo en unos días.

### 2.1 Antes de empezar: requisitos

**Tenant y licencias**

| Necesitas | Por qué |
| --- | --- |
| Un **tenant de Microsoft 365 de pruebas**, con Teams y SharePoint | Para no tocar tu entorno productivo. Una persona administradora concede los permisos |
| Una **suscripción de Azure en el mismo tenant**, con rol *Owner* sobre el grupo de recursos | La identidad administrada de la Function solo existe en el tenant de su suscripción |
| Un **entorno de Power Platform** de tipo *Sandbox*, con Dataverse | Un entorno *Trial* se elimina a los 30 días y no admite pago por uso |
| Una **cuenta de servicio** (por ejemplo `agente-dsa`), sin roles de administrador | Será la dueña del agente y de los flujos. Necesita una licencia que permita publicar: de usuario de Copilot Studio con créditos en el entorno, o Microsoft 365 Copilot. Las licencias de prueba no habilitan la publicación |
| Una **cuenta de supervisor** sin roles de administrador | Es quien recibe la tarjeta y decide |
| **Copilot Credits** por pago por uso, vinculados a la suscripción, con presupuesto propio | Cada ejecución del agente consume créditos |
| La app **Workflows** permitida en Teams | La usa la publicación de la tarjeta |

**Herramientas en tu computador**

| Herramienta | Versión | Cómo instalarla |
| --- | --- | --- |
| PowerShell | 7 o superior | `winget install --id Microsoft.PowerShell --source winget` |
| Python | 3.11 o superior | [python.org](https://www.python.org/downloads/) |
| Azure CLI | La más reciente | [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Bicep | La más reciente | `az bicep install` |
| Extensión de IoT para Azure CLI | La más reciente | `az extension add --name azure-iot` |
| Microsoft Graph para PowerShell | 2.x | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| Git | Reciente | — |

✅ **Siga cuando** `pwsh --version`, `python --version` y `az version` respondan sin error.

### 2.2 Paso 1 — Preparar el repositorio (5 min)

En Windows, clona en una ruta corta. Algunas dependencias tienen rutas largas.

```powershell
git clone https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente.git C:\src\del-sensor-al-agente
cd C:\src\del-sensor-al-agente
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.txt
python -m pytest -q
Copy-Item .env.example .env
```

Qué hace: crea un entorno de Python aislado, instala las dependencias, corre las pruebas y crea tu archivo `.env` de configuración local.

✅ **Siga cuando** todas las pruebas pasen. No necesitan Azure ni el tenant.

> **`.env` nunca se sube al repositorio.** Ahí van nombres, rutas y las claves de los dispositivos.

### 2.3 Paso 2 — Preparar Microsoft 365 (10 min)

Con una cuenta de administrador, en el portal:

1. Crea el **sitio de SharePoint** de la demo y un segundo sitio vacío, `DSA-Control`. El segundo sirve para comprobar que la Function **no** puede escribir fuera del sitio de la demo.
2. Crea el **equipo privado** `DSA-Demo` con un **canal estándar** `Centro de operaciones`. El conector de Teams no publica en canales privados.
3. Agrega a la cuenta de servicio y al supervisor como miembros del equipo.

Completa en `.env`: `DSA_SITE_URL`, `DSA_TEAM_NAME`, `DSA_CHANNEL_NAME` y `DSA_ENVIRONMENT_KIND=sandbox`.

✅ **Siga cuando** veas el canal `Centro de operaciones` en Teams con las dos cuentas como miembros.

### 2.4 Paso 3 — Aprovisionar SharePoint (5 min)

```powershell
./sharepoint/provision.ps1
```

Qué hace:
1. Abre una sesión de Microsoft Graph.
2. Crea la lista `Eventos de seguridad` con sus columnas y la biblioteca `Protocolos`.
3. Convierte los protocolos ficticios a `.docx` y los sube.
4. Comprueba que `DSA-Control` existe y está vacío.

Es idempotente: si lo ejecutas dos veces, no duplica nada.

Después, anota el ID del sitio y el de la lista. Los necesitas en el paso 6. El comando exacto está en el README, sección 3.

✅ **Siga cuando** la lista y la biblioteca existan en el sitio y la biblioteca tenga tres documentos.

### 2.5 Paso 4 — Desplegar Azure (10 min)

```powershell
az login
./infra/deploy.ps1
```

Qué hace:
1. Registra los proveedores de recursos que falten.
2. Crea el grupo de recursos en `eastus2` y despliega la plantilla Bicep: IoT Hub, la Function, Table Storage, Key Vault, Application Insights, la identidad administrada y un presupuesto de USD 20 con aviso al 80 %.
3. Publica el código de la Function.

Para ver los cambios sin aplicarlos: `./infra/deploy.ps1 -WhatIf`.

✅ **Siga cuando** el script imprima el client ID y el object ID de la identidad `id-dsa-func` y los dos comandos para el administrador. No se escriben en ningún archivo: cópialos.

> Si tu suscripción ya tiene un IoT Hub gratuito, usa `./infra/deploy.ps1 -IotHubSku B1`. Suma unos USD 10 al mes.

### 2.6 Paso 5 — Conceder `Sites.Selected` (5 min)

Una persona administradora de SharePoint ejecuta los dos comandos que imprimió el paso 4. El detalle está en `docs/admin-sites-selected.md` del repositorio.

Por qué: `Sites.Selected` es un permiso de Microsoft Graph que no da acceso a ningún sitio hasta que un administrador lo concede sitio por sitio ([documentación](https://learn.microsoft.com/graph/permissions-selected-overview)). Así la Function solo puede escribir donde debe.

✅ **Siga cuando** la identidad tenga el rol `write` solo sobre el sitio de la demo, y ningún permiso sobre `DSA-Control`.

### 2.7 Paso 6 — Configurar el agente en Copilot Studio (20 min)

Con la **cuenta de servicio**, sigue la guía `agent/GUIA-CONFIGURACION.md` del repositorio. En resumen:

1. Crea la solución `DelSensorAlAgente` en tu entorno.
2. Crea los flujos `DisparoAgente`, `LeerIncidente` y `PublicarIncidente`.
   - En `DisparoAgente`, configura *Who can trigger the flow* = *Specific users in my tenant*, con el object ID de `id-dsa-func`. Agrega también el tuyo si vas a usar los scripts de contingencia.
   - La definición de `PublicarIncidente` se genera con `python -m agent.flows.build_publicar_incidente`.
3. Crea el agente "Agente de Operaciones" **en inglés (`en-US`)**. El idioma principal no se puede cambiar después, y las instrucciones le piden responder en español. Copia las instrucciones de `agent/instrucciones.md`, agrega el conocimiento `Protocolos` y las dos herramientas.
4. Publica el agente y fija un **límite mensual de créditos** para él.

Copia la URL del disparador de `DisparoAgente` en `DSA_FLOW_URL` de `.env`. No es una URL con firma: exige un token de Microsoft Entra ID. Aun así, no la compartas.

Vuelve a desplegar con los tres valores:

```powershell
./infra/deploy.ps1 -GraphSiteId '<siteId>' -GraphListId '<listId>' -AgentFlowUrl '<URL de DisparoAgente>'
```

✅ **Siga cuando** el agente aparezca como publicado en Copilot Studio y el despliegue termine sin errores.

### 2.8 Paso 7 — Registrar los dispositivos (3 min)

Usa el nombre del IoT Hub que imprimió el paso 4.

```powershell
az iot hub device-identity create --hub-name <iotHub> --device-id sim-01 --auth-type login
az iot hub device-identity create --hub-name <iotHub> --device-id preflight-01 --auth-type login
az iot hub device-identity connection-string show --hub-name <iotHub> --device-id sim-01 --auth-type login --query connectionString -o tsv
az iot hub device-identity connection-string show --hub-name <iotHub> --device-id preflight-01 --auth-type login --query connectionString -o tsv
```

Pega la primera cadena en `IOTHUB_DEVICE_CONNECTION_STRING` y la segunda en `IOTHUB_PREFLIGHT_CONNECTION_STRING`, en `.env`. Cada dispositivo tiene su propia clave.

✅ **Siga cuando** las dos variables estén completas en `.env`.

### 2.9 Paso 8 — Tu primera tarjeta (2 min)

```powershell
./infra/set-always-ready.ps1 -Scenario ensayo -ResourceGroup <grupo de recursos>
python -m simulator --type puerta_forzada --zone Z-03
```

✅ **Siga cuando** veas las tres cosas:
1. Un elemento nuevo en la lista `Eventos de seguridad` que pasa de `Nuevo` a `Pendiente de decisión`.
2. La tarjeta "Propuesta del Agente de Operaciones" en el canal, en 30 segundos o menos.
3. Al pulsar un botón de la tarjeta, la decisión, quién la tomó y la hora quedan en la lista.

**Prueba la deduplicación:**

```powershell
python -m simulator --type movimiento_zona_restringida --zone Z-01 --burst 20
```

✅ **Siga cuando** veas un solo incidente nuevo con `Repeticiones = 20` y una sola tarjeta.

**Prueba el cambio de regla:** en las instrucciones del agente, cambia la hora del bloque `REGLA-HORARIO`, publica y envía otro evento. La propuesta debe cambiar según la nueva regla.

**Al terminar, apaga la instancia *always ready*** para volver al costo de centavos:

```powershell
./infra/set-always-ready.ps1 -Scenario reposo -ResourceGroup <grupo de recursos>
```

### 2.10 Si algo no funciona

| Señal | Qué revisar |
| --- | --- |
| Más de 60 s sin tarjeta y el elemento sigue en `Nuevo` | La Function no pudo llamar al flujo. Reintenta con `./demo/retrigger.ps1 -EventId <eventId>` |
| No aparece ningún elemento en la lista | Revisa Application Insights: busca `EventRejected` (esquema) o errores de Graph (paso 5) |
| El simulador dice `No se pudo enviar a IoT Hub` | Revisa la cadena de conexión en `.env` y la red |
| Error 403 al escribir en la lista | Falta conceder `Sites.Selected` sobre el sitio (paso 5) |
| El agente no se publica | La cuenta de servicio no tiene una licencia que permita publicar |
| La tarjeta no aparece en el canal | El canal es privado, o la app *Workflows* no está permitida en Teams |
| Quieres empezar de cero | `./demo/reset.ps1 -All` manda los incidentes a la papelera y vacía la deduplicación |

`./demo/preflight.ps1` comprueba todos los componentes en 3 minutos o menos y te dice cuál falla.

### 2.11 Limpieza

```powershell
./infra/set-always-ready.ps1 -Scenario reposo
./infra/destroy.ps1
```

`destroy` muestra los recursos, pide confirmación, borra el grupo de recursos y purga el Key Vault. En Bash: `infra/destroy.sh`.

En Microsoft 365, borra o desactiva a mano:
1. El vínculo del entorno con el plan de pago por uso. Desde ese momento no se factura.
2. La solución `DelSensorAlAgente`, con el agente y los flujos.
3. La lista y la biblioteca, si ya no las necesitas.

---

## Parte 3 · Preguntas frecuentes

**¿Funciona con sensores o cámaras reales?**
El diseño sí. El simulador usa el mismo contrato que un dispositivo real: un evento JSON por MQTT a IoT Hub, con su propia clave. Un sensor real, o la integración con un sistema de videovigilancia, tendría que enviar ese mismo formato.

**¿Qué campos tiene el evento?**
Siete, todos obligatorios: `schemaVersion`, `eventId`, `deviceId`, `type`, `zone`, `timestamp` y `rawSeverity`. No hay ningún campo de texto libre, así que un dispositivo no puede enviar datos personales.

**¿Cómo se calcula la severidad inicial?**
La calcula la Function: es la mayor entre la que reporta el dispositivo y la severidad base de la zona. El agente parte de ahí y puede proponer como máximo un nivel de diferencia.

**¿Por qué el agente no puede llamar ni abrir puertas?**
Porque son acciones con consecuencias físicas sobre personas. Una propuesta equivocada se corrige; una llamada equivocada no. Además del texto de las instrucciones, el agente no tiene ninguna herramienta para hacerlo.

**¿Qué pasa si nadie responde la tarjeta?**
A los 15 minutos el incidente pasa a `Sin respuesta`, se publica un aviso en el canal y no se registra ninguna decisión por defecto.

**¿Qué pasa si el agente propone una severidad equivocada?**
Solo puede proponer un nivel de diferencia con la inicial, y el flujo lo vuelve a comprobar antes de escribir. El supervisor ve la severidad inicial, la propuesta y la justificación, y decide.

**¿Por qué el registro está en SharePoint?**
Porque queda donde la organización ya gobierna su información: permisos, retención y búsqueda de Microsoft 365.

**¿Cómo sé por qué el agente propuso algo?**
En Copilot Studio, la página *Actividad* muestra cada ejecución paso a paso: qué herramienta usó, qué consultó y qué publicó.

**¿Lo puedo usar para otros escenarios?**
Sí: cualquier señal que necesite contexto y una decisión humana, como alarmas industriales, mantenimiento o monitoreo de TI. El patrón es el mismo: deduplicar, registrar, proponer y dejar decidir.

**¿Qué cambiaría para producción?**
El repositorio trae una lista de verificación de 10 puntos en `docs/gobernanza.md`. Los más importantes:
- Un entorno dedicado con DLP y auditoría.
- Una cuenta de servicio sin roles de administrador.
- La conexión de IoT Hub con identidad administrada a través de Event Hubs.
- Un límite de créditos por agente.
- Monitoreo y revisión de seguridad para cada cambio en las instrucciones, las tarjetas o los flujos.

### Costos

| Concepto | Estimado |
| --- | --- |
| Azure, mes normal con IoT Hub `F1` y *always ready* apagado | ≈ USD 0,40 al mes |
| Azure, *always ready* olvidado todo el mes | ≈ USD 7,90 al mes |
| Copilot Credits por incidente | ≈ 15 (planifica con 20) |

Las licencias de Microsoft 365 no están incluidas. Confirma el consumo real en el Power Platform admin center ([Manage Copilot Credits and capacity](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity)) y la tabla oficial de tarifas ([Billing rates and management](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)).

Un presupuesto de Azure avisa, pero no detiene el consumo. Fija además un límite mensual de créditos por agente ([Manage monthly consumption limits](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity#manage-monthly-consumption-limits-for-copilot-studio-agents)).

### Glosario

| Término | Qué es |
| --- | --- |
| **Agente** | Asistente de Copilot Studio con instrucciones, conocimiento y herramientas |
| **Always ready** | Instancias de la Function que se mantienen encendidas para evitar el arranque en frío |
| **Copilot Credits** | Unidad de consumo de Copilot Studio |
| **Deduplicación** | Agrupar eventos iguales en un solo incidente |
| **DLP** | Políticas de datos de Power Platform: qué conectores se pueden usar juntos |
| **Identidad administrada** | Identidad que Azure gestiona para un recurso, sin contraseña que guardar |
| **Idempotencia** | Repetir una operación no cambia el resultado |
| **IoT Hub** | Servicio de Azure que recibe mensajes de dispositivos |
| **MQTT** | Protocolo ligero de mensajería para dispositivos |
| **p90** | 9 de cada 10 mediciones quedan por debajo de ese valor |
| **Sites.Selected** | Permiso de Graph limitado a los sitios que un administrador elige |
| **Tarjeta adaptativa** | Tarjeta interactiva de Teams con botones y campos |

### Enlaces

**Repositorio de la sesión:** https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente

**Videos de la demo:** [videos.md](videos.md)

**Documentación oficial en Microsoft Learn:**
- [Llamar a agentes de Copilot Studio desde Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)
- [Autenticación OAuth en disparadores HTTP](https://learn.microsoft.com/power-automate/oauth-authentication)
- [Publicar una tarjeta adaptativa y esperar respuesta en Teams](https://learn.microsoft.com/connectors/teams/#post-adaptive-card-and-wait-for-a-response)
- [Permisos Sites.Selected de Microsoft Graph](https://learn.microsoft.com/graph/permissions-selected-overview)
- [Revisar la actividad de un agente](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity#historical-activity)
- [Idiomas de un agente](https://learn.microsoft.com/microsoft-copilot-studio/authoring-language-support)
- [Configurar pago por uso](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan)
- [Crear y administrar presupuestos en Azure](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)

**El evento:** Microsoft 365 Live 2026, del 4 al 8 de noviembre, 100 % online y gratis. Agenda: https://microsoft365live.github.io/26/ · #M365Live #Microsoft365Live2026
