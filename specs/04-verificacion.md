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
| CA-06.2 (403 en `DSA-Control`) | **Cumple** | 2026-10-26 23:12 UTC: con `DSA_GRAPH_SITE_ID` apuntando temporalmente al sitio `DSA-Control`, un evento del simulador produjo en Application Insights `GraphRejected` con `status = 403`, `code = accessDenied` y `step = create`. La configuración se restauró y el evento siguiente registró `IncidentCreated` y `AgentTriggered` |
| CA-06.4 (comandos del administrador) | **Cumple** | `docs/admin-sites-selected.md` y `infra/grant-sites-selected.ps1`, ejecutados con éxito |
| CA-07.1 y CA-07.2 (aprovisionamiento idempotente) | **Cumple** | Segunda ejecución de `sharepoint/provision.ps1`: "0 creados, 33 ya existían, 0 errores". Nota: `Estado: defaultValue` se vuelve a completar en cada ejecución (pendiente de depurar, no duplica nada) |
| R-13 (token de la identidad administrada para el flujo HTTP) | **Cerrado** | Registro `AgentTriggered` con `status = 202` y `attempts = 1` el 2026-10-26 17:26:30 UTC; el flujo restringido a "Usuarios específicos de mi inquilino" aceptó el token de `id-dsa-func` |
| CA-05.5 (tramo 1) | Primera medición | 10,7 s (`durationMs` de `IncidentCreated`) con la instancia *always ready* recién encendida. Meta p90 ≤ 10 s en 10 ensayos (T-027, T-052) |
| CA-08.5 (casos del agente) | **Cumple** | 18 corridas el 2026-10-26: 0 afirmaciones de acción; cada caso acierta al menos 2 de 3 (C5 llegó a 3 de 3 tras ajustar las instrucciones). Registro en `tests/integration/casos-agente.md` |
| CA-08.7 (un nivel y justificación) | **Cumple** | Ninguna diferencia pasa de un nivel; C2 y C3 suben un nivel con justificación en todas sus corridas |
| CA-14.3 (preflight) | **Cumple** | `demo/preflight.ps1` en 103 s: amarillo general por el entorno predeterminado (ADR-002) y por dos datos que se cargan a mano (consumo de créditos e infraestructura); punta a punta verde en 20,5 s |
| OBJ-2 y CA-05.5 (total) | **Cumple** en la primera serie | 10 ensayos de punta a punta el 2026-10-26: 10 de 10 con tarjeta; total p90 22,6 s, máximo 36,1 s. `tests/integration/ensayos.md` |
| CA-08.6 / R-18 (tramo 2) | **Desviación aceptada** (Daniel, 2026-10-26) | Tramo 2 p90 20,7 s frente a 20 s. Se acepta porque el total, que es lo que ve el público, cumple con margen (p90 22,6 s frente a 30 s). Se vuelve a medir con una segunda serie el día anterior a la sesión; si el total pasa de 30 s, se aplica el plan B de §10 |
| CA-08.3 (guía) | Escrita | `agent/GUIA-CONFIGURACION.md`, con un enlace oficial en cada paso y los hallazgos de la integración. Falta la prueba de un tercero (T-054) |

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
| El vencimiento manejado dejaba la ejecución como fallida (la acción con espera vencida cuenta como falla) | Acción `Terminate` con estado `Succeeded` al final de la rama de vencimiento; prueba | `T-038 HU-10` |
| Con un borrador del diseñador sin publicar, la API rechaza actualizar el flujo (`0x80040203`) | Publicar primero desde el diseñador y después actualizar con la API | — |

## Pendiente de esta fase

- `PublicarIncidente` (T-037, T-038): creado desde `agent/flows/build_publicar_incidente.py`, activado y agregado como herramienta del agente, que se volvió a publicar. Primera ejecución de punta a punta el 2026-10-26 a las 18:29 UTC (evento del simulador `puerta_forzada` en Z-01): el agente llamó a la herramienta, `LeerElemento` respondió y la condición `Si_estado_es_Nuevo` fue verdadera; la ejecución quedó esperando la tarjeta. La tarjeta se publicó y la espera venció a los 15 min 1 s; la rama de vencimiento leyó el estado, marcó `Sin respuesta`, armó y publicó la tarjeta sin respuesta (CA-10.5 cumple en esa ejecución). Rama de decisión, segunda ejecución (evento `acceso_denegado_repetido` en Z-03 enviado a las 21:37:30 UTC): la tarjeta se dibujó completa en el canal; el supervisor respondió "Atender" con observación y el elemento quedó con `Estado = Atendido`, `Decision`, `DecididoPor` (persona resuelta con `ensureuser`), `FechaDecision` y `Observacion`; se publicó la tarjeta de solo lectura con el nombre del respondiente y la ejecución terminó como correcta en 7 min 39 s (CA-10.4 cumple en esa ejecución). R-M4 cerrado: `responder.displayName` y `responder.userPrincipalName` llegan en la respuesta. Del evento a `PublicacionSolicitadaUtc` pasaron 26 s (primera medición aproximada del total hasta la tarjeta; la medición formal es `demo/measure.ps1`).
- Nota: el texto "Card - access it on go.skype.com/cards.unsupported" aparece en superficies de Teams que no dibujan tarjetas (notificación o vista previa); en el canal la tarjeta se ve completa.
- Idioma (H-41.1): en el panel de prueba el agente responde en inglés aunque las instrucciones lo prohíben. Lo visible en la demo (tarjeta y lista) sale en español. Se revisa en la página *Activity* durante los ensayos.
- El runbook completo dos veces y la segunda serie de ensayos (T-052).
