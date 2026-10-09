# Especificación funcional — "Del sensor al agente"

| Campo | Valor |
| --- | --- |
| Versión | 1.7 |
| Fecha | 2026-10-08 |
| Dueño del producto | Daniel Villamizar |
| Evento | Microsoft 365 Live 2026, 4–7 de noviembre, online por Teams, 60 min, español |
| Estado | Pendiente de aprobación de la Fase 1 (Compuerta 1): falta el resultado de SPK-01 |
| Fuentes de esta versión | Respuestas de Daniel a `specs/01a-clarificaciones.md` (v1.1), a B-01 y SPK-01 (v1.2) a los ajustes del kit del spike (v1.3) a la elección de tenant y entorno (v1.6), a la separación entre configuración recomendada y demo en vivo (v1.7) y a los prerrequisitos de PowerShell 7 (v1.4) |

---

## 1. Visión

Mostrar en vivo, a una comunidad de Microsoft 365, cómo una alerta física (cámara, sensor, control de acceso) se convierte en una decisión humana informada y auditada en Teams, con un agente de Copilot Studio que propone y una persona que decide.

**Resultado de negocio:** que el asistente salga con una arquitectura de referencia, un repositorio que puede clonar y una regla clara sobre qué automatizar y qué no.

## 2. Objetivos medibles

| ID | Objetivo | Métrica | Meta |
| --- | --- | --- | --- |
| OBJ-1 | Demo confiable | Ejecuciones de punta a punta exitosas en ensayos | 10 de 10 seguidas |
| OBJ-2 | Demo rápida | Tiempo desde el evento del dispositivo hasta la tarjeta visible en Teams, medido por tramos (§6, RNF-01) | p90 ≤ 30 s en al menos 10 ensayos, ninguno > 60 s. **No se relaja sin aprobación de Daniel.** |
| OBJ-3 | Recuperable | Tiempo para dejar la demo en estado inicial | ≤ 2 min con un comando |
| OBJ-4 | Reutilizable | Tiempo para que un tercero despliegue el repositorio siguiendo el README | ≤ 60 min |
| OBJ-5 | Barata | Costo mensual en Azure | < USD 20 |

## 3. Alcance

**Dentro:**
- Simulador de dispositivos por script.
- Ingesta en Azure (IoT Hub y Azure Functions), con enriquecimiento y deduplicación.
- Escritura del incidente en una lista de SharePoint vía Microsoft Graph. La lista es **siempre** el registro de auditoría visible, cualquiera sea el mecanismo que dispare al agente (DEC-05).
- Agente de Copilot Studio en el **standard harness**, con orquestación generativa, disparado según DEC-05, con conocimiento en una biblioteca de protocolos y una tarjeta adaptativa en un canal de Teams.
- Captura de la decisión del supervisor y escritura de vuelta en la lista.
- Infraestructura como código, pruebas, documentación bilingüe, guion de demo y scripts de reinicio.

**Condicional:**
- Sensor físico en Raspberry Pi (HU-03): solo si E1–E4 están en verde el 25 de octubre de 2026.

**Fuera:**
- Integración con plataformas reales de CCTV o control de acceso (VMS, NVR, paneles).
- Video en vivo, reconocimiento facial o cualquier análisis de imágenes de personas.
- Acciones automáticas sobre dispositivos físicos (abrir, cerrar, bloquear).
- Alta disponibilidad, multi-región o carga productiva.
- Agentes del *GitHub Copilot harness* (el conector de Power Automate no los admite).

## 4. Roles

### 4.1 Roles de negocio (personas del escenario)

| Rol | Descripción | Qué necesita |
| --- | --- | --- |
| Supervisor de seguridad | Atiende el centro de operaciones, recibe alertas en Teams | Saber qué pasó, dónde, qué tan grave y qué hacer, en menos de 10 segundos de lectura |
| Jefe de seguridad | Responsable del protocolo y de la auditoría | Registro de cada decisión y poder ajustar reglas sin programar |
| Administrador de M365 / Power Platform | Gobierna el tenant | Permisos mínimos, entorno dedicado, políticas DLP, monitoreo |
| Asistente a la charla | Profesional de M365 que verá la demo | Entender la arquitectura y poder reproducirla |
| Speaker (Daniel) | Ejecuta la demo en vivo; es además el administrador del tenant donde corre la demo (§8.2) | Disparar, mostrar, reiniciar y tener plan B |

En el tenant se usan cuentas de prueba con nombres ficticios (por ejemplo "Supervisor Demo").

### 4.2 Roles del equipo de construcción

Los archivos viven en `docs/equipo/`, única fuente de verdad de los roles.

| Rol | Archivo | Responsabilidad |
| --- | --- | --- |
| Líder de especificación | `docs/equipo/lider-especificacion.md` | Dueño de specs, trazabilidad y compuertas |
| Arquitecto cloud (Azure) | `docs/equipo/arquitecto-cloud.md` | IoT Hub, Functions, Bicep, identidad, costos |
| Arquitecto M365 y Copilot Studio | `docs/equipo/arquitecto-m365.md` | SharePoint, Graph, agente, tarjetas, Teams, guía de configuración |
| Ingeniero IoT | `docs/equipo/ingeniero-iot.md` | Simulador y dispositivo físico |
| Revisor de seguridad y gobernanza | `docs/equipo/revisor-seguridad.md` | Permisos, secretos, datos, DLP, revisión obligatoria |
| QA y verificación | `docs/equipo/qa-verificacion.md` | Pruebas, evidencia por criterio, Definition of Done |
| Instructor técnico y redactor | `docs/equipo/instructor-tecnico.md` | README bilingüe, runbook de la demo, material para el asistente |

## 5. Historias de usuario

Prioridad MoSCoW: **M** = Must, **S** = Should, **C** = Could. Estimación en puntos (1, 2, 3, 5, 8).

### 5.0 Modelo de severidad (común a HU-05, HU-08 y HU-09)

- Escala única de cuatro niveles, siempre en texto: `Baja` < `Media` < `Alta` < `Crítica`.
- **SeveridadInicial** (la calcula la función): el mayor entre `rawSeverity` del evento y la severidad base de la zona en `data/zonas.json`.
- **SeveridadPropuesta** (la propone el agente): puede ser igual a `SeveridadInicial` o diferir en **un solo nivel**, hacia arriba o hacia abajo, y nunca sale de la escala.
- **JustificacionSeveridad** (la escribe el agente): texto corto, obligatorio siempre que `SeveridadPropuesta` ≠ `SeveridadInicial`.
- Regla de horario: fuera de 06:00–18:00 en `America/Bogota`, el agente sube un nivel. Esa subida cuenta dentro del límite de un nivel.

### Épica E1 — Simulación de dispositivos

#### HU-01 Simular eventos de seguridad física
**Como** speaker, **quiero** emitir desde mi computador tres tipos de evento de dispositivo, **para** disparar la demo sin depender de hardware.
Prioridad: M · Estimación: 3 · Rol: ingeniero-iot

**Criterios de aceptación**
- **CA-01.1** Dado el simulador configurado con la cadena de conexión del dispositivo, cuando ejecuto `simulate --type puerta_forzada --zone Z-03` (o `python -m simulator …`), entonces se envía a IoT Hub un mensaje que cumple el esquema `schemas/evento-dispositivo.schema.json`.
- **CA-01.2** El simulador soporta exactamente los tipos `movimiento_zona_restringida`, `puerta_forzada` y `acceso_denegado_repetido`; un tipo distinto termina con código de salida distinto de 0 y un mensaje claro.
- **CA-01.3** Cada mensaje lleva `eventId` (UUID), `deviceId`, `type`, `zone`, `timestamp` (ISO 8601 UTC) y `rawSeverity`. El esquema usa `additionalProperties: false` y patrones cerrados (`deviceId` = `DEV-[A-Z0-9-]+`, `zone` = `Z-\d{2}`, `rawSeverity` en la escala de §5.0), de modo que no admite campos con datos personales; una prueba automatizada lo verifica.
- **CA-01.4** La cadena de conexión se lee de variable de entorno o `.env`; nunca de un archivo versionado.

#### HU-02 Simular una ráfaga de eventos
**Como** speaker, **quiero** enviar una ráfaga del mismo evento, **para** mostrar en vivo que la deduplicación evita inundar al supervisor.
Prioridad: S · Estimación: 2 · Rol: ingeniero-iot

**Criterios de aceptación**
- **CA-02.1** Cuando ejecuto `simulate --type movimiento_zona_restringida --zone Z-01 --burst 20`, entonces se envían 20 mensajes del mismo `deviceId` y tipo en menos de 10 segundos.
- **CA-02.2** Tras la ráfaga, la lista de SharePoint tiene un solo elemento nuevo para ese dispositivo y tipo, con `Repeticiones` = 20 (verificado junto con HU-05). Las actualizaciones de `Repeticiones` no cuentan para el límite por minuto de CA-12.1.

#### HU-03 Sensor físico opcional
**Como** speaker, **quiero** un sensor real (PIR o contacto magnético) en una Raspberry Pi, **para** que el público vea un evento físico en cámara.
Prioridad: C · Estimación: 5 · Rol: ingeniero-iot · **Condicional:** solo si E1–E4 están en verde el 25 de octubre de 2026.

**Criterios de aceptación**
- **CA-03.1** Al activarse el sensor, el dispositivo envía un evento con el mismo esquema que el simulador.
- **CA-03.2** Con un rebote de 5 segundos, un sensor activado varias veces seguidas no envía más de un evento cada 5 segundos.
- **CA-03.3** El README del dispositivo lista materiales, diagrama de conexión y pasos de instalación en menos de 15 pasos.

### Épica E2 — Ingesta y procesamiento en Azure

#### HU-04 Desplegar la infraestructura con un comando
**Como** asistente a la charla, **quiero** desplegar toda la infraestructura de Azure con un solo comando, **para** reproducir la demo en mi propia suscripción.
Prioridad: M · Estimación: 5 · Rol: arquitecto-cloud

**Criterios de aceptación**
- **CA-04.1** `infra/` contiene Bicep que crea IoT Hub (parámetro `iotHubSku`, por defecto `F1`; `B1` si la suscripción ya tiene un hub gratuito), Function App en Flex Consumption, Storage, Key Vault, Application Insights e identidad administrada. Región por defecto: `eastus2`.
- **CA-04.2** `az bicep build` y `az bicep lint` terminan sin errores.
- **CA-04.3** Un script de despliegue y otro de eliminación funcionan con parámetros de nombre y región; la eliminación borra el grupo de recursos completo.
- **CA-04.4** Ningún secreto queda en salidas de despliegue, parámetros versionados ni configuración de la aplicación en texto plano. En particular, la cadena de conexión de IoT Hub:
  - usa una política de acceso compartido **dedicada**, solo con el permiso *service connect* (nunca `iothubowner`);
  - se guarda en Key Vault y la Function la consume como referencia `@Microsoft.KeyVault(...)`, resuelta por su identidad administrada con el rol *Key Vault Secrets User*.
  Una prueba sobre la plantilla compilada verifica las tres condiciones.
- **CA-04.5** El documento de costos estima el gasto mensual y queda por debajo de USD 20, incluido el escenario con instancias *always ready* encendidas solo durante ensayos y evento.

#### HU-05 Enriquecer y deduplicar eventos
**Como** supervisor de seguridad, **quiero** recibir una sola alerta por incidente con su contexto, **para** no perder tiempo con duplicados ni buscar dónde ocurrió.
Prioridad: M · Estimación: 5 · Rol: arquitecto-cloud

**Criterios de aceptación**
- **CA-05.1** Dado un evento válido, la función agrega `zoneName`, `cameraId`, `site` y `SeveridadInicial` (§5.0) a partir de un catálogo de zonas versionado (`data/zonas.json`, ficticio).
- **CA-05.2** Dados varios eventos con el mismo `deviceId` y `type` dentro de una ventana **fija de 60 s contada desde el primer evento**, la función produce un solo incidente y acumula `Repeticiones`. Un evento posterior a la ventana crea otro incidente.
- **CA-05.3** Dado un evento que no cumple el esquema, la función no lo procesa, registra el error en Application Insights y no falla la ejecución completa.
- **CA-05.4** La lógica de enriquecimiento y deduplicación vive separada de los *bindings* y tiene pruebas unitarias con `pytest --cov=function/core --cov-fail-under=80`.
- **CA-05.5** Tramo 1 (dispositivo → elemento creado): p90 ≤ 10 s en al menos 10 ensayos, medido como la diferencia entre `enqueuedTimeUtc` de IoT Hub y la respuesta de Graph al crear el elemento, registradas en Application Insights con `eventId`. La consulta KQL está versionada.

#### HU-06 Publicar el incidente en SharePoint
**Como** administrador de M365, **quiero** que la función escriba solo en el sitio de la demo, **para** cumplir el principio de mínimo privilegio.
Prioridad: M · Estimación: 3 · Rol: arquitecto-cloud + revisor-seguridad

**Criterios de aceptación**
- **CA-06.1** La función crea el elemento en la lista `Eventos de seguridad` usando Microsoft Graph con identidad administrada y el permiso `Sites.Selected` con rol `write` concedido solo al sitio de la demo.
- **CA-06.2** Un intento de la función de escribir en el sitio de control vacío `DSA-Control` falla con error de autorización (prueba documentada con salida).
- **CA-06.3** Los campos escritos coinciden con el contrato de columnas definido en el plan, incluido `Estado` = `Nuevo`.
- **CA-06.4** La guía documenta los dos comandos exactos que ejecuta el administrador del tenant: (1) asignar el rol de aplicación `Sites.Selected` de Microsoft Graph a la identidad administrada y (2) conceder el rol `write` sobre el sitio de la demo con `POST /sites/{siteId}/permissions`.

### Épica E3 — Agente y experiencia en Teams

#### HU-07 Preparar SharePoint para la demo
**Como** speaker, **quiero** crear la lista de eventos y la biblioteca de protocolos con un script, **para** no configurarlas a mano antes de cada ensayo.
Prioridad: M · Estimación: 3 · Rol: arquitecto-m365

**Criterios de aceptación**
- **CA-07.1** Un script idempotente crea la lista `Eventos de seguridad` con sus columnas (incluidas `SeveridadInicial`, `SeveridadPropuesta`, `JustificacionSeveridad`, `Repeticiones`, `Estado`, `Decision`, `DecididoPor`, `FechaDecision`, `Observacion` y `EsPrueba`), la biblioteca `Protocolos` y el sitio de control `DSA-Control` vacío, y carga los protocolos de `protocols/`.
- **CA-07.2** Ejecutar el script dos veces no duplica columnas, listas, sitios ni documentos.
- **CA-07.3** Hay un protocolo por tipo de evento, de máximo una página, con pasos numerados y un apartado "Lo que decide una persona". La fuente es Markdown en `protocols/`; se sube en el formato que el Plan verifique como indexable por el conocimiento de SharePoint de Copilot Studio.

#### HU-08 Configurar el agente de Copilot Studio
**Como** speaker, **quiero** instrucciones del agente y una guía de configuración paso a paso, **para** montar el agente en mi tenant en menos de 30 minutos.
Prioridad: M · Estimación: 5 · Rol: arquitecto-m365

**Criterios de aceptación**
- **CA-08.1** `agent/instrucciones.md` contiene las instrucciones del agente: rol, tono, qué puede hacer, qué nunca hace (Artículo 1 de la constitución) y cómo proponer la severidad según §5.0.
- **CA-08.2** Las instrucciones incluyen la regla "fuera del horario 06:00–18:00 en America/Bogota, la severidad sube un nivel", aislada en un bloque para poder cambiarla en vivo.
- **CA-08.3** `agent/GUIA-CONFIGURACION.md` lleva al lector desde un agente vacío del **standard harness** hasta uno publicado con: orquestación generativa activada, el disparador elegido en DEC-05 sobre el origen de los incidentes, conocimiento en la biblioteca `Protocolos` y el flujo del agente `PublicarIncidente` (DEC-01). Cada paso enlaza la documentación oficial que lo respalda. La guía parte de la **configuración recomendada de §8.1** (tenant de pruebas, Sandbox dedicado nunca *Trial*, grupo de seguridad, DLP, auditoría, *solution-aware cloud flow sharing* activo, cuenta de servicio con licencia que permita publicar y créditos por pago por uso según ADR-001) e incluye un apartado "Si no tienes capacidad para un Sandbox" que explica la alternativa del entorno predeterminado, sus riesgos y mitigaciones (ADR-002).
- **CA-08.4** La guía advierte que los disparadores usan las credenciales del creador y pide una cuenta de servicio dedicada.
- **CA-08.5** `agent/casos-prueba.md` define 5 casos con severidad y protocolo esperados. Cada caso se ejecuta 3 veces en el tenant y se evalúa en dos niveles:
  - **Calidad:** cada caso acierta severidad y protocolo en al menos 2 de las 3 corridas.
  - **Seguridad (Artículo 1):** tolerancia cero. Si en **cualquier** corrida el agente afirma haber ejecutado una acción física o haber contactado a alguien, el criterio falla.
- **CA-08.6** Tramo 2 (elemento creado → tarjeta visible en Teams): p90 ≤ 20 s en al menos 10 ensayos, medido con `eventId` como identificador de correlación.
- **CA-08.7** Dado un incidente, `SeveridadPropuesta` difiere de `SeveridadInicial` como máximo en un nivel, y si difiere, `JustificacionSeveridad` no está vacía (verificado en los casos de CA-08.5).

#### HU-09 Mostrar la alerta como tarjeta adaptativa en Teams
**Como** supervisor de seguridad, **quiero** ver cada incidente como una tarjeta clara en el canal de operaciones, **para** entender en 10 segundos qué pasó y qué hacer.
Prioridad: M · Estimación: 3 · Rol: arquitecto-m365

**Criterios de aceptación**
- **CA-09.1** `cards/` contiene la tarjeta en dos variantes (normal y severidad alta o crítica), sin usar la función de plantillas que Power Automate no soporta, más la variante de solo lectura (CA-10.2) y la de "Sin respuesta" (CA-10.5).
- **CA-09.2** La tarjeta muestra: el encabezado "Propuesta del Agente de Operaciones", tipo de evento, zona, hora local con la zona explícita (por ejemplo "14:32 COT"), `SeveridadInicial` y `SeveridadPropuesta` con su justificación, repeticiones, resumen del agente en máximo 3 líneas y los pasos del protocolo en máximo 3 líneas (`TextBlock` con `maxLines: 3`).
- **CA-09.3** La tarjeta tiene tres acciones: `Atender`, `Escalar a autoridades` y `Falsa alarma`, y un campo opcional de observación.
- **CA-09.4** Las tarjetas validan contra el esquema oficial de Adaptive Cards **1.5** (versión soportada por Teams), usan solo `Action.Submit` y no usan `isEnabled` (prueba automatizada contra una copia versionada del esquema).
- **CA-09.5** Ningún texto de la tarjeta afirma que el agente ya ejecutó una acción física o contactó a alguien; las acciones se presentan como decisiones del supervisor.

#### HU-10 Registrar la decisión del supervisor
**Como** jefe de seguridad, **quiero** que cada decisión quede registrada en el incidente, **para** auditar quién decidió qué y cuándo.
Prioridad: M · Estimación: 5 · Rol: arquitecto-m365 + revisor-seguridad

**Criterios de aceptación**
- **CA-10.1** Cuando el supervisor pulsa una acción, el elemento de la lista se actualiza con `Estado`, `Decision`, `DecididoPor`, `FechaDecision` y `Observacion`. Estados válidos: `Nuevo` (función) → `Pendiente de decisión` (flujo del agente) → `Atendido` / `Escalado` / `Falsa alarma` (persona) o `Sin respuesta` (tiempo agotado).
- **CA-10.2** La tarjeta se reemplaza por una versión de solo lectura que muestra la decisión tomada, para que nadie la responda dos veces.
- **CA-10.3** La elección `Escalar a autoridades` solo se registra; ningún componente contacta a nadie.
- **CA-10.4** La solución respeta los límites de duración de los flujos del agente con el patrón de DEC-01 (responder al agente de inmediato y después publicar y esperar), documentado en un ADR.
- **CA-10.5** Si nadie responde en **15 minutos**, el incidente pasa a `Sin respuesta`, se publica un aviso en el canal y **no se registra ninguna decisión por defecto**.
- **CA-10.6** Si llega una segunda respuesta a la misma tarjeta, se ignora, no modifica el elemento y queda registrada en el historial de ejecución.

### Épica E4 — Gobernanza y operación

#### HU-11 Documentar la gobernanza del agente
**Como** administrador de M365, **quiero** una guía de gobernanza aplicable, **para** llevar este patrón a producción sin abrir riesgos.
Prioridad: M · Estimación: 3 · Rol: revisor-seguridad

**Criterios de aceptación**
- **CA-11.1** `docs/gobernanza.md` contiene la tabla "Se automatiza / Lo decide siempre una persona" del plan de la sesión.
- **CA-11.2** Cubre: cuenta de servicio y credenciales del creador, entorno de Power Platform dedicado, políticas DLP para disparadores, datos en el payload, monitoreo (página Activity y las que el Plan verifique), cuotas y créditos, y la deuda consciente de la cadena de conexión de IoT Hub con su alternativa de producción (enrutamiento a Event Hubs con identidad administrada y su costo).
- **CA-11.3** Cada afirmación sobre el producto enlaza a Microsoft Learn.
- **CA-11.4** Incluye una lista de verificación de 10 puntos o menos para pasar de demo a producción.

#### HU-12 Controlar costos y cuotas
**Como** speaker, **quiero** que una ráfaga o un error no consuma créditos sin control, **para** no tener sorpresas en la factura ni en las cuotas.
Prioridad: S · Estimación: 2 · Rol: arquitecto-cloud

**Criterios de aceptación**
- **CA-12.1** La función limita la **creación** de incidentes a un máximo configurable por minuto (por defecto 10) y registra lo descartado.
- **CA-12.2** Hay una alerta de presupuesto en Azure al 80 % de USD 20.
- **CA-12.3** El README estima los Copilot Credits por incidente (disparador o acción del agente, respuesta generativa con conocimiento y acciones del flujo) con la tabla oficial de tarifas, enlaza la página oficial de facturación y explica el límite mensual de créditos por agente.
- **CA-12.4** Existe un presupuesto de Copilot Credits **separado** de los USD 20 de Azure: presupuesto en Azure Cost Management con alcance en el grupo de recursos del plan de pago por uso (`rg-dsa-creditos`) y alertas al 50 %, 80 % y 100 %, más un límite mensual de créditos por agente como freno, según ADR-001. La guía documenta la estimación de consumo de spike, ensayos y evento.

### Épica E5 — Entrega para la comunidad y para el escenario

#### HU-13 Repositorio listo para la comunidad
**Como** asistente a la charla, **quiero** un README claro en español e inglés, **para** entender y desplegar la solución sin haber visto la charla.
Prioridad: M · Estimación: 3 · Rol: instructor-tecnico

**Criterios de aceptación**
- **CA-13.1** `README.md` (español) y `README.en.md` (inglés) con: qué es, diagrama de arquitectura, requisitos (incluidas licencias), despliegue paso a paso, costos, limpieza y licencia.
- **CA-13.2** El diagrama está en Mermaid dentro del README y coincide con la arquitectura del plan.
- **CA-13.3** Un tercero sigue el README en un tenant y suscripción limpios y llega a una tarjeta en Teams en ≤ 60 min (prueba manual registrada).
- **CA-13.4** Licencia MIT y sin marcas comerciales de terceros ni de la empresa del speaker.
- **CA-13.5** El repositorio `del-sensor-al-agente` es privado hasta el ensayo general y se hace público el día del evento. Antes de publicarlo: (1) escaneo de secretos de **todo el historial** de git con `gitleaks` sin hallazgos, y (2) aprobación del revisor-seguridad de que no quedan IDs de tenant, URLs de sitio ni correos reales.

#### HU-14 Kit de demo en vivo
**Como** speaker, **quiero** un runbook, un script de reinicio y un guion de respaldo, **para** ejecutar la demo con calma y recuperarme si algo falla.
Prioridad: M · Estimación: 3 · Rol: instructor-tecnico + qa-verificacion

**Criterios de aceptación**
- **CA-14.1** `demo/RUNBOOK.md` sigue los tres actos del plan de la sesión, con el comando exacto de cada paso y qué debe verse en pantalla.
- **CA-14.2** `demo/reset` deja la lista sin incidentes de prueba y el estado inicial en ≤ 2 minutos. Usa la identidad delegada de Daniel (no la de la función) y los elementos van a la papelera de reciclaje del sitio.
- **CA-14.3** `demo/preflight` verifica en ≤ 3 minutos, con resultado verde, amarillo o rojo por componente: que se ejecuta en PowerShell 7 o superior (`$PSVersionTable.PSVersion.Major -ge 7`; si no, rojo con el comando de instalación); conexión a IoT Hub, función y SharePoint; el entorno configurado en `.env` (verde si es un Sandbox dedicado; amarillo si es el entorno predeterminado, con referencia a ADR-002); que la auditoría de Dataverse está activada; cómo se pagan los créditos (pago por uso vinculado o capacidad del tenant) y, si la capacidad es de prueba, cuántos días faltan para su vencimiento (rojo si vence antes de la fecha de la sesión); que el consumo de créditos del mes está por debajo del 80 % del límite del agente; que el entorno está en la nueva infraestructura de Power Platform (o informa que no lo está); y una prueba de punta a punta con un incidente `EsPrueba = Sí` que debe llegar a `Pendiente de decisión` dentro del tiempo límite.
- **CA-14.4** Lista de los 3 videos de respaldo a grabar, con duración y qué debe mostrar cada uno.

## 6. Requisitos no funcionales

| ID | Requisito |
| --- | --- |
| RNF-01 | Presupuesto de latencia por tramo, cada uno medido con `eventId` como identificador de correlación en Application Insights: tramo 1, dispositivo → elemento creado, p90 ≤ 10 s (CA-05.5); tramo 2, elemento creado → tarjeta visible en Teams, p90 ≤ 20 s (CA-08.6); total de punta a punta p90 ≤ 30 s y nunca > 60 s (OBJ-2) |
| RNF-02 | Lenguaje de la función y del simulador: Python 3.11 o superior, modelo de programación v2 de Azure Functions |
| RNF-03 | Infraestructura en Bicep; scripts en PowerShell 7 y Bash para que funcionen en Windows y Linux. Los scripts de PowerShell declaran `#Requires -Version 7.0` y el README lista la instalación de PowerShell 7 (`winget install --id Microsoft.PowerShell --source winget`) como prerrequisito |
| RNF-04 | Registros estructurados en Application Insights con `eventId` como identificador de correlación |
| RNF-05 | Sin secretos en el repositorio; escaneo con `gitleaks` en CI en cada push y escaneo del historial completo antes de hacerlo público (CA-13.5) |
| RNF-06 | CI en GitHub Actions: lint, pruebas, `bicep build` y validación de tarjetas en cada push |
| RNF-07 | Accesibilidad de la tarjeta: contraste suficiente y la severidad comunicada con texto, no solo con color |
| RNF-08 | Horas en UTC en los datos; en la tarjeta, hora local de `America/Bogota` con la zona explícita (`COT`) |

## 7. Decisiones (a resolver en el Plan con un ADR)

| ID | Decisión | Estado |
| --- | --- | --- |
| DEC-01 | Cómo se publica la tarjeta y se captura la decisión | **Dirección aprobada:** flujo del agente `PublicarIncidente` que actualiza `Estado`, responde al agente de inmediato y después publica la tarjeta en el canal como *Workflows* y espera. Condiciones del ADR: (1) espera de 15 min y estado `Sin respuesta` sin decisión por defecto; (2) la tarjeta dice "Propuesta del Agente de Operaciones"; (3) idempotencia ante segundas respuestas. |
| DEC-02 | Puente de Azure a M365 | Function → Graph → lista de SharePoint como registro de auditoría (fijo). Cómo se dispara el agente se decide en DEC-05. |
| DEC-03 | Plan de hosting de la Function App | Flex Consumption (CA-04.1); el ADR decide el número de instancias *always ready* por escenario. |
| DEC-04 | Dónde vive la ventana de deduplicación | Abierta. Recomendación: Table Storage con concurrencia optimista (ETag), porque Flex Consumption puede escalar a varias instancias. |
| DEC-05 | Mecanismo que dispara al agente | **Se decide con el spike SPK-01** (`spikes/p1-latencia/`): A) disparador de SharePoint, B) disparador de Dataverse, C) flujo HTTP → *Execute Agent*. Se mide en secuencia A → B; C solo si A y B no cumplen. Cortes: (1) en cuanto 3 eventos superan 20 s, porque con 20 muestras el p90 ≤ 20 s ya es imposible; (2) protección: si ninguno de los primeros 5 eventos completa el tramo 2 en ≤ 60 s. El agente del spike debe tener la misma configuración que el de la demo. Gana la opción más simple con p90 ≤ 20 s en el tramo 2. Si ninguna cumple, se escala a Daniel antes de cambiar OBJ-2. |
| DEC-06 | Facturación de Copilot Credits | **Recomendado en [ADR-001](../docs/adr/ADR-001-facturacion-creditos-copilot-studio.md):** pago por uso vinculado a la suscripción de Azure, solo para el entorno de la demo, con presupuesto propio y límite por agente. |
| DEC-07 | Dónde corre la demo en vivo | **[ADR-002](../docs/adr/ADR-002-entorno-demo-en-vivo.md), aceptado el 2026-10-09:** desviación solo para la sesión: tenant de la empresa del speaker, entorno predeterminado renombrado `DSA-Demo` y capacidad de prueba de Copilot Studio hasta el 7 de noviembre. |

## 8. Dependencias externas y licencias

### 8.1 Configuración recomendada (la que documentan la guía y el README)

- **Tenant de Microsoft 365 de pruebas**, dedicado a la demo, con Teams y SharePoint. Una persona con rol de administrador concede `Sites.Selected` y los consentimientos.
- **Suscripción de Azure en el mismo tenant**, con permisos de Owner sobre un grupo de recursos, región `eastus2`. La identidad administrada de la Function recibe `Sites.Selected` en el SharePoint de ese tenant.
- **Entorno de Power Platform dedicado `DSA-Demo`, de tipo Sandbox** (nunca *Trial*: se elimina con sus agentes a los 30 días y no admite pago por uso), con Dataverse, **grupo de seguridad**, **política DLP** propia y **auditoría de Dataverse** activada.
- **Cuenta de servicio** para el agente, sin roles de administrador (Art. 4), con una licencia que permita publicar: Microsoft 365 Copilot, o licencia de usuario de Copilot Studio con créditos asignados al entorno ([FAQ de facturación](https://learn.microsoft.com/microsoft-copilot-studio/faq-billing-licensing)). Según esa misma FAQ, las licencias de prueba no habilitan la publicación.
- **Créditos** por pago por uso de Copilot Studio vinculado a la suscripción de Azure, con presupuesto y límite por agente (ADR-001).

### 8.2 Demo en vivo de la sesión (desviación aceptada, ADR-002)

- **Tenant:** el de la empresa del speaker. Su marca puede verse en la demo y en los videos, sin mensaje comercial. En el repositorio no se escriben IDs de tenant ni de entorno, URL de sitios ni correos (CA-13.5).
- **Entorno:** el predeterminado del tenant, renombrado `DSA-Demo`, porque no hay capacidad de Dataverse para crear un Sandbox ([Create environment](https://learn.microsoft.com/power-platform/admin/create-environment#create-an-environment-with-a-database)). Sin grupo de seguridad (Learn no lo permite en ese tipo de entorno, [Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)) y sin DLP propia (afectaría a toda la empresa); auditoría activada con retención de 180 días.
- **Licencias verificadas en sistema el 2026-10-09:** Microsoft 365 Business Premium en prueba (vence 2026-11-07 04:50 UTC) y capacidad de Copilot Studio del tenant en prueba (vence 2026-11-07 05:01 UTC). La cuenta de Daniel publicó un agente del standard harness con orquestación generativa: **B-01 resuelto para la demo mientras dure la prueba.**
- **Riesgo R-12:** si la sesión cae el 7 de noviembre, las pruebas ya habrán vencido. Antes del 28 de octubre se confirma la fecha y, si hace falta, se pasa a pago la capacidad.
- **Pendientes:** suscripción de Azure en el tenant de la empresa del speaker y cuenta de servicio del agente.
- Supuesto descartado: Microsoft 365 Copilot en las cuentas de prueba (P4); no aparece en ninguna cuenta revisada.

## 9. Calendario

| Fecha | Hito |
| --- | --- |
| 2026-10-25 | Decisión sobre HU-03 (sensor físico): solo si E1–E4 están en verde |
| 2026-10-28 | Congelamiento de código e infraestructura |
| 2026-11-01 | Congelamiento de contenido (runbook, tarjetas, instrucciones del agente) |
| 2026-11-02 | Ensayo general; el repositorio se prepara para publicarse (CA-13.5) |
| 2026-11-04 a 07 | Evento; el repositorio se hace público el día de la sesión |

## 10. Definition of Done

Una historia está terminada cuando:
- [ ] Todos sus criterios de aceptación están verificados con evidencia en `specs/04-verificacion.md`.
- [ ] Las pruebas automatizadas pasan en CI.
- [ ] El revisor de seguridad aprobó los cambios que tocan identidad, permisos, secretos o datos.
- [ ] La documentación afectada está actualizada en español e inglés.
- [ ] No hay secretos, datos reales ni marcas comerciales en el cambio.
- [ ] La matriz de trazabilidad está actualizada.

El proyecto está terminado cuando todas las historias Must están hechas, OBJ-1 a OBJ-3 se cumplen en ensayo y el runbook se ejecutó completo dos veces seguidas sin intervención.

---

## Registro de cambios

### v1.7 — 2026-10-09
Origen: Daniel pide que la documentación enseñe la configuración recomendada aunque la demo en vivo use lo disponible.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| §8 dividida en 8.1 (configuración recomendada) y 8.2 (demo en vivo) | Pedido de Daniel | §8 |
| La guía (CA-08.3) parte de la configuración recomendada e incluye la alternativa sin Sandbox como apartado | Pedido de Daniel | CA-08.3 |
| El preflight (CA-14.3) acepta ambos casos: verde con Sandbox dedicado, amarillo con el entorno predeterminado | Pedido de Daniel | CA-14.3 |
| La desviación de la demo en vivo pasa a ADR-002 (nueva DEC-07); ADR-001 vuelve a ser solo la recomendación | Pedido de Daniel | DEC-06, DEC-07, ADR-001, ADR-002 |

### v1.6 — 2026-10-09
Origen: verificación de cuentas y licencias en sistema, prueba de publicación y decisión de Daniel sobre el tenant y el entorno.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| **Cambio de alcance:** tenant de la empresa del speaker (marca visible en la demo, sin identificadores en el repositorio) en lugar de un tenant de pruebas | Decisión de Daniel | §4.1, §8 |
| **Cambio de alcance:** entorno predeterminado renombrado `DSA-Demo` en lugar de un Sandbox dedicado, por falta de capacidad de Dataverse; sin grupo de seguridad ni DLP propia, con auditoría | Decisión de Daniel | §8, CA-08.3, CA-14.3 |
| Licencias verificadas en sistema y B-01 resuelto hasta el vencimiento de las pruebas; nuevo riesgo R-12 | Verificación del 2026-10-09 | §8, DEC-06 |
| ADR-001 actualizado: capacidad de prueba del tenant hasta el 7 de noviembre; pago por uso diferido | Verificación del 2026-10-09 | DEC-06, ADR-001 |

Revisión contra la constitución: el Art. 5 y el Art. 6 rigen el contenido del repositorio, que sigue sin identificar a la empresa; el Art. 4 se cumple con la cuenta de servicio dedicada y `Sites.Selected`. La pérdida del entorno dedicado debilita la gobernanza de la demo, pero no viola ningún artículo.

### v1.5 — 2026-10-08
Origen: decisión de Daniel sobre el versionado.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| `docs/equipo/` es la única fuente de verdad de los roles; la copia local `equipo/` deja de versionarse | Decisión de versionado | §4.2, `docs/reglas-del-proyecto.md`, `.gitignore` |
| El prompt maestro y el plan de la sesión no se versionan (material personal del speaker) | Decisión de versionado | `.gitignore` |

### v1.4 — 2026-10-08
Origen: Daniel no tiene PowerShell 7 en su PC.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| El preflight verifica que corre en PowerShell 7 o superior | Pedido de Daniel | CA-14.3 |
| PowerShell 7 explícito como prerrequisito de todos los scripts, con el comando de instalación | Pedido de Daniel | RNF-03 |
| Prerrequisitos del spike (PowerShell 7, Pester 5 con `-Force -SkipPublisherCheck`, `Import-Module Pester -MinimumVersion 5.0.0` antes de `Invoke-Pester`) | Pedido de Daniel | `spikes/p1-latencia/README.md` |

### v1.3 — 2026-10-08
Origen: ajustes de Daniel al kit del spike.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| SPK-01 con corte p90 agresivo (3 eventos > 20 s) además del corte de protección de 60 s; créditos recalculados | Decisión 1 | DEC-05, `spikes/p1-latencia/` |
| Límite del agente del spike: 886 créditos (peor caso de 770 + 15 %); el de la demo se mantiene en 3 000 | Decisión 3 | ADR-001 |
| Verificación de representatividad del agente del spike (mismo harness, orquestación y entorno que la demo) | Ajuste 4 | DEC-05, `spikes/p1-latencia/README.md` |
| La limpieza conserva los componentes de la opción ganadora hasta que el Plan decida | Ajuste 5 | `spikes/p1-latencia/README.md` |

Nota de trazabilidad: el commit `f943c14` ("T-000 docs: especificación v1.1 y kit del spike P1") ya contiene la **v1.2** de este archivo, no la v1.1. Se aclara aquí y en el mensaje del commit siguiente; el historial no se reescribe.

### v1.2 — 2026-10-08
Origen: respuesta de Daniel sobre B-01 y el spike SPK-01.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| Publicación con la cuenta de Daniel con Microsoft 365 Copilot como prerrequisito de la guía y del preflight | B-01.1 | §8, CA-08.3, CA-14.3 |
| Facturación de créditos por pago por uso vinculado a Azure, solo para `DSA-Demo`; nueva DEC-06 con ADR-001 | B-01.2 | §8, DEC-06 (nueva) |
| Presupuesto de créditos separado de los USD 20 de Azure, con grupo de recursos propio, alertas y límite por agente; estimación de consumo de spike, ensayos y evento | B-01.3 | CA-12.4 (nuevo) |
| Entorno Sandbox `DSA-Demo`; el preflight verifica nombre, tipo, vínculo de facturación y consumo frente al límite | B-01.4 | §8, CA-08.3, CA-14.3 |
| SPK-01 en secuencia (A → B; C solo si ambas fallan), 20 eventos por opción y corte a los 5 eventos | SPK-01 | DEC-05 |

Revisión contra la constitución: sin conflictos. El Art. 9 limita el costo de Azure a USD 20 "sin contar licencias de Microsoft 365 y Copilot Studio"; los créditos se facturan a la suscripción de Azure, pero son consumo de Copilot Studio y llevan su propio presupuesto, en un grupo de recursos aparte, para que el límite de USD 20 siga midiendo solo la infraestructura.


### v1.1 — 2026-10-08
Origen: respuestas de Daniel a la Compuerta 1 sobre `specs/01a-clarificaciones.md`.

| Cambio | Origen | Afecta |
| --- | --- | --- |
| OBJ-2 se mide por tramos y no se relaja sin aprobación; nuevo RNF-01 con presupuesto 10 s + 20 s = 30 s (p90), nunca > 60 s | P1, I-01 | OBJ-2, RNF-01, CA-05.5, CA-08.6 (nuevo) |
| Nueva DEC-05 (mecanismo de disparo) resuelta por el spike SPK-01 con tres opciones; la lista de SharePoint queda fija como registro de auditoría | P1 | §3, DEC-02, DEC-05, CA-08.3 |
| Credencial de IoT Hub: política dedicada *service connect*, Key Vault y referencia `@Microsoft.KeyVault(...)`; alternativa de producción en gobernanza | P2 | CA-04.4, CA-11.2 |
| Standard harness explícito; GitHub Copilot harness fuera de alcance | P3 | §3, CA-08.3 |
| Licencias declaradas y bloqueante B-01 (la prueba no permite publicar); entorno no *Trial*; verificación de la nueva infraestructura en el preflight | P4, investigación en Learn | §8, CA-08.3, CA-14.3 |
| Modelo de severidad: escala de 4 niveles, `SeveridadInicial`, `SeveridadPropuesta`, `JustificacionSeveridad`, cambio máximo de un nivel; la tarjeta muestra ambas | P5 | §5.0, CA-05.1, CA-07.1, CA-08.1, CA-08.7 (nuevo), CA-09.2 |
| Zona horaria `America/Bogota`; la tarjeta muestra la zona explícita (COT) | P6 | CA-08.2, CA-09.2, RNF-08 (nuevo) |
| HU-03 condicional al 25 de octubre | P7 | §3, HU-03, §9 |
| Sitio de control `DSA-Control` para CA-06.2; Daniel concede los permisos; dos comandos documentados | P8, I-03 | CA-06.2, CA-06.4, CA-07.1 |
| Repositorio `del-sensor-al-agente`: privado hasta el ensayo, escaneo del historial completo y revisión de seguridad antes de publicar | P9 | CA-13.5 (nuevo), RNF-05 |
| Región `eastus2` (verificada con la CLI de Azure: Flex Consumption con Python e IoT Hub disponibles) y calendario con dos congelamientos y ensayo general | P10 | CA-04.1, §9 (nuevo) |
| CA-08.5 con dos niveles: calidad (2 de 3 corridas) y seguridad (tolerancia cero) | S-19 | CA-08.5 |
| DEC-01: dirección aprobada con espera de 15 min sin decisión por defecto, encabezado "Propuesta del Agente de Operaciones" e idempotencia | DEC-01 | DEC-01, CA-09.1, CA-09.2, CA-10.1, CA-10.4, CA-10.5 (nuevo), CA-10.6 (nuevo) |
| Supuestos S-01–S-18 y S-20 e inconsistencias I-02–I-06 incorporados en los criterios correspondientes | Compuerta 1 | HU-01, HU-02, HU-05, HU-07, HU-09, HU-11, HU-12, HU-14, RNF-05 |

Revisión contra la constitución: ningún cambio relaja los artículos 1, 4, 5 o 9. Dos tienen efecto que conviene saber: la referencia a Key Vault para IoT Hub (Art. 4) quedó aprobada explícitamente por Daniel como deuda documentada, y la prueba de punta a punta del preflight (S-16) consume Copilot Credits en cada ejecución (costo de licencia, no de Azure).

### v1.0 — 2026-10-08
Borrador inicial para la Fase 1.
