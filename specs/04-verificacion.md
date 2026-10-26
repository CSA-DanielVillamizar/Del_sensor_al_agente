# Verificación — "Del sensor al agente"

| Campo | Valor |
| --- | --- |
| Versión | 0.1 (en construcción durante la Fase 3) |
| Fecha | 2026-10-26 |
| Estado | Evidencia parcial; la verificación completa es la Fase 4 |

Cada fila registra un criterio, el resultado y la evidencia. "Lo implementé" no cuenta como evidencia. Los identificadores reales del tenant no se escriben aquí.

## Evidencia de integración en Azure y Microsoft 365

| Criterio o riesgo | Resultado | Evidencia |
| --- | --- | --- |
| CA-06.1 (escritura con `Sites.Selected`) / R-16 | **Cumple** | 2026-10-26: `infra/grant-sites-selected.ps1` asignó el rol de aplicación y el permiso `write`; el evento del simulador creó el elemento 1 de `Eventos de seguridad` con `Estado = Nuevo`, `NombreZona = Bodega norte` y `SeveridadInicial = Alta` (registro `IncidentCreated` con `outcome = created`) |
| CA-06.2 (403 en `DSA-Control`) | Cumple en configuración; falta la prueba de escritura | La comprobación del script confirma que la identidad no tiene ningún permiso sobre `DSA-Control`. Pendiente: intento de escritura desde la Function con salida 403 (T-024) |
| CA-06.4 (comandos del administrador) | **Cumple** | `docs/admin-sites-selected.md` y `infra/grant-sites-selected.ps1`, ejecutados con éxito |
| CA-07.1 y CA-07.2 (aprovisionamiento idempotente) | **Cumple** | Segunda ejecución de `sharepoint/provision.ps1`: "0 creados, 33 ya existían, 0 errores". Nota: `Estado: defaultValue` se vuelve a completar en cada ejecución (pendiente de depurar, no duplica nada) |
| R-13 (token de la identidad administrada para el flujo HTTP) | **Cerrado** | Registro `AgentTriggered` con `status = 202` y `attempts = 1` el 2026-10-26 17:26:30 UTC; el flujo restringido a "Usuarios específicos de mi inquilino" aceptó el token de `id-dsa-func` |
| CA-05.5 (tramo 1) | Primera medición | 10,7 s (`durationMs` de `IncidentCreated`) con la instancia *always ready* recién encendida. Meta p90 ≤ 10 s en 10 ensayos (T-027, T-052) |

## Hallazgos de la integración (corregidos con prueba)

| Hallazgo | Corrección | Commit |
| --- | --- | --- |
| El despliegue copiaba los contratos sin su ruta relativa y sin `zona.schema.json`; la Function no podía cargarlos | `Copy-DsaContracts` conserva la ruta; prueba que cruza la lista de PowerShell con la de Python | `T-019 HU-04` |
| Faltaba el grupo de consumidores `func` en IoT Hub | Recurso `ConsumerGroups` en `infra/modules/iothub.bicep` y prueba de plantilla | `T-016 HU-04` |
| La ruta de respaldo de IoT Hub quedaba desactivada si la plantilla no la declaraba; los mensajes no llegaban al endpoint integrado | `routing.fallbackRoute.isEnabled = true` y prueba de plantilla | `T-016 HU-04` |
| Los SDK registraban cada petición HTTP con sus encabezados | `Azure.Core` y `Azure.Messaging.EventHubs` en `Warning` en `host.json` y el registrador `azure` en `WARNING` | `T-014 HU-05` |
| En el diseñador de flujos del agente, una expresión agregada a una salida de "Responder al agente" se perdió al publicar sin guardar antes el borrador | Guardar el borrador antes de publicar y revisar las salidas en el historial de ejecución; queda en la guía (T-042) | — |
| `Version` es un nombre reservado en las bibliotecas de SharePoint | La columna se llama `VersionProtocolo` | `T-029 HU-07` |
| Al activar `PublicarIncidente`, la plataforma rechazó una expresión de 9143 caracteres (máximo 8192): la tarjeta iba completa dentro de la expresión | La plantilla va como objeto en su propio Compose y los valores escapados en otro; prueba que mide la expresión más larga | `T-037 HU-10` |
| Un flujo cuyas referencias de conexión pertenecen a la cuenta de servicio no se puede actualizar ni activar con otra cuenta (`ConnectionAuthorizationFailed`) | Se crea como borrador con la cuenta de servicio como dueña y se activa con la sesión de esa cuenta; queda en la guía (T-042) | — |
| En el diseñador, un flujo creado con la API no habilita "Publicar" | Activar el flujo (`statecode = 1`) con la API de Dataverse desde la sesión del dueño | — |

## Pendiente de esta fase

- `PublicarIncidente` (T-037, T-038): creado desde `agent/flows/build_publicar_incidente.py`, activado y agregado como herramienta del agente, que se volvió a publicar. Primera ejecución de punta a punta el 2026-10-26 a las 18:29 UTC (evento del simulador `puerta_forzada` en Z-01): el agente llamó a la herramienta, `LeerElemento` respondió y la condición `Si_estado_es_Nuevo` fue verdadera; la ejecución quedó esperando la tarjeta. Pendiente: confirmar la tarjeta en el canal de prueba, responderla (rama de decisión y R-M4) y dejar vencer otra (rama sin respuesta).
- El agente respondió una vez en inglés en el panel de prueba, en un camino de error: verificar con los casos de `agent/casos-prueba.md` (CA-08.5).
- Tramo 2 y total con `demo/measure.ps1` (T-039, T-040) y los 10 ensayos (T-052).
