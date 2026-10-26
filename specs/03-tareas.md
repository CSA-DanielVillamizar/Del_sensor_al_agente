# Tareas — "Del sensor al agente"

| Campo | Valor |
| --- | --- |
| Versión | 1.0 |
| Fecha | 2026-10-26 |
| Estado | Propuesto para la Compuerta 2 |
| Plan | `specs/02-plan.md` v1.0 |

Reglas: cada tarea dura como máximo 2 horas, se rastrea a una historia y a un criterio (Art. 3) y se cierra solo con su verificación. **[P]** = puede ir en paralelo con las demás [P] de su bloque. **Necesita**: `local` (sin nube), `tenant` (Microsoft 365), `Azure` (suscripción de la demo) o `Daniel` (paso que solo puede hacer Daniel en un portal o con su consentimiento). Las tareas marcadas **RS** no se cierran sin la revisión del revisor-seguridad.

Commits: `T-0xx HU-xx: descripción en imperativo`.

## Bloque 0 — Base del repositorio

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-001 | [P] | Base de Python: `pyproject.toml` (ruff, pytest, cobertura), `requirements*.txt`, `.env.example` sin valores | HU-13 | RNF-02, CA-01.4 | arquitecto-cloud | — | `pyproject.toml`, `requirements.txt`, `requirements-dev.txt`, `.env.example` | `ruff check .` y `pytest -q` en verde con el repositorio vacío | local |
| T-002 | | CI en GitHub Actions: ruff, pytest, Pester, gitleaks en cada push | HU-13 | RNF-05, RNF-06 | qa-verificacion | T-001 | `.github/workflows/ci.yml`, `.gitleaks.toml` | Una ejecución verde en GitHub; un secreto falso en una rama de prueba hace fallar gitleaks | local |

## Épica E1 — Simulación

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-003 | [P] | Esquema del evento con `additionalProperties: false`, patrones cerrados y casos negativos | HU-01 | CA-01.3 | ingeniero-iot | T-001 | `schemas/evento-dispositivo.schema.json`, `tests/schemas/test_evento.py` | `pytest tests/schemas` (válido, campo extra, nombre en `deviceId`, zona y severidad fuera de patrón) | local |
| T-004 | [P] | Catálogo de zonas ficticio y su esquema | HU-05 | CA-05.1 | ingeniero-iot | T-001 | `data/zonas.json`, `schemas/zona.schema.json`, `tests/schemas/test_zonas.py` | `pytest tests/schemas`; revisión de que ningún nombre es real (Art. 5) | local |
| T-005 | | Simulador: CLI, tres tipos, validación antes de enviar, lectura de `.env`, transporte detrás de una interfaz | HU-01 | CA-01.1, CA-01.2, CA-01.4 | ingeniero-iot | T-003 | `simulator/__main__.py`, `simulator/cli.py`, `simulator/transport.py`, `tests/simulator/` | `pytest tests/simulator` con transporte falso; tipo inválido → código 2 | local |
| T-006 | | Modo ráfaga `--burst N` en menos de 10 s | HU-02 | CA-02.1 | ingeniero-iot | T-005 | `simulator/cli.py`, `tests/simulator/test_burst.py` | Prueba con reloj falso: 20 mensajes, mismo `deviceId` y `type`, < 10 s | local |

## Épica E2 — Ingesta en Azure

### Núcleo (sin Azure)

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-007 | | Validación del evento y modelo de severidad (§5.0) | HU-05 | CA-05.3, CA-05.1 | arquitecto-cloud | T-003, T-004 | `function/core/validation.py`, `function/core/severity.py`, `tests/function/` | `pytest`: inválido → resultado de rechazo sin excepción; mayor entre `rawSeverity` y base | local |
| T-008 | | Enriquecimiento con el catálogo | HU-05 | CA-05.1 | arquitecto-cloud | T-007 | `function/core/enrich.py`, `tests/function/test_enrich.py` | `pytest`: `zoneName`, `cameraId`, `site`, `SeveridadInicial`; zona desconocida → rechazo | local |
| T-009 | [P] | Ventana de deduplicación con repositorio en memoria (ADR-006) | HU-05, HU-02 | CA-05.2, CA-02.2 | arquitecto-cloud | T-001 | `function/core/dedup.py`, `function/core/ports.py`, `tests/function/test_dedup.py` | `pytest`: 20 eventos → 1 incidente con 20 repeticiones; evento a los 60 s abre otro; reentrega no suma; conflicto de ETag se reintenta | local |
| T-010 | [P] | Límite de incidentes por minuto | HU-12 | CA-12.1 | arquitecto-cloud | T-001 | `function/core/ratelimit.py`, `tests/function/test_ratelimit.py` | `pytest`: el 11.º incidente del minuto se descarta y se registra; las repeticiones no consumen cupo | local |
| T-011 | | Contrato de columnas y cuerpo del elemento | HU-06 | CA-06.3 | arquitecto-m365 + arquitecto-cloud | T-008 | `sharepoint/columnas.json`, `function/core/listitem.py`, `tests/contract/test_columnas.py` | `pytest`: el cuerpo usa solo columnas de `columnas.json`, `Estado = Nuevo`, tipos correctos | local |
| T-012 | | Cliente de Graph: crear y actualizar, `Retry-After`, tope de 6 s, choque de `EventId` único | HU-06 | CA-06.1 | arquitecto-cloud | T-011 | `function/core/graph_client.py`, `tests/function/test_graph_client.py` | `pytest` con transporte falso: 429 con y sin cabecera, 4xx sin reintento, tope respetado | local |
| T-013 | [P] | Disparo del flujo: token de la identidad, 3 intentos, 401/403 sin reintento | HU-08 | CA-08.6 | arquitecto-cloud | T-001 | `function/core/flow_trigger.py`, `tests/function/test_flow_trigger.py` | `pytest` con credencial y transporte falsos; el token nunca aparece en registros | local · **RS** |
| T-014 | | `function_app.py`: orquestación de ADR-004, repositorio de Table real, registros estructurados con `eventId`, cobertura ≥ 80 % | HU-05, HU-06 | CA-05.3, CA-05.4, RNF-04 | arquitecto-cloud | T-007 a T-013 | `function/function_app.py`, `function/core/telemetry.py`, `function/core/table_repo.py`, `function/host.json`, `tests/function/test_orchestration.py` | `pytest --cov=function/core --cov-fail-under=80`; prueba de orquestación con dobles: orden Table → Graph → flujo | local · **RS** |

### Infraestructura

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-015 | [P] | Bicep: identidad `id-dsa-func`, Storage sin claves, Key Vault RBAC, Log Analytics con límite diario y Application Insights | HU-04 | CA-04.1 | arquitecto-cloud | — | `infra/main.bicep`, `infra/modules/identity.bicep`, `storage.bicep`, `keyvault.bicep`, `monitor.bicep` | `az bicep build` y `az bicep lint` limpios | local · **RS** |
| T-016 | | Bicep: IoT Hub (`iotHubSku`), política `func-reader` solo `ServiceConnect`, secreto en Key Vault sin salidas | HU-04 | CA-04.1, CA-04.4 | arquitecto-cloud | T-015 | `infra/modules/iothub.bicep` | `bicep build`; revisión de que no hay `output` con claves | local · **RS** |
| T-017 | | Bicep: Function Flex (512 MB, máximo 1 instancia, *always ready* por parámetro), referencia de Key Vault, roles, presupuesto al 80 % de USD 20 al rol Owner | HU-04, HU-12 | CA-04.1, CA-04.4, CA-12.2 | arquitecto-cloud | T-015, T-016 | `infra/modules/function.bicep`, `infra/modules/budget.bicep`, `infra/main.bicepparam` | `bicep build` y `lint` limpios | local · **RS** |
| T-018 | | Prueba sobre la plantilla compilada y paso de Bicep en CI | HU-04 | CA-04.2, CA-04.4 | qa-verificacion | T-017, T-002 | `tests/infra/test_template.py`, `.github/workflows/ci.yml` | `pytest tests/infra`: sin secretos en salidas, `func-reader` solo `ServiceConnect`, `@Microsoft.KeyVault(...)`, `allowSharedKeyAccess: false` | local |
| T-019 | | Scripts de despliegue y eliminación con nombre y región; imprimen client ID, object ID y los dos comandos del administrador | HU-04 | CA-04.3, CA-06.4 | arquitecto-cloud | T-017 | `infra/deploy.ps1`, `infra/deploy.sh`, `infra/destroy.ps1`, `infra/destroy.sh` | `-WhatIf` / `az deployment group what-if` sin errores; Pester de las funciones puras | local |
| T-020 | [P] | Cambio de escenario *always ready* y rotación de la clave de IoT Hub | HU-04 | CA-04.5 | arquitecto-cloud | T-017 | `infra/set-always-ready.ps1`, `infra/rotate-iothub-key.ps1` | Pester con comandos de `az` simulados | local |
| T-021 | [P] | Consulta KQL del tramo 1 | HU-05 | CA-05.5 | arquitecto-cloud | T-014 | `infra/queries/tramo1.kql` | Se ejecuta en T-027 sobre datos reales | local |
| T-022 | [P] | Documento de costos con escenarios (reposo, ensayo, sesión, olvido) y el caso `B1` | HU-04 | CA-04.5 | arquitecto-cloud | T-017 | `docs/costos.md` | Total < USD 20 en todos los escenarios, con enlaces a las páginas de precios | local |

### Con la suscripción de Azure

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-023 | | Crear la suscripción de Azure **en el tenant de la demo** y el primer despliegue | HU-04 | CA-04.3 | Daniel + arquitecto-cloud | T-019 | — | Salida de `infra/deploy` sin errores; recursos en `eastus2` | Azure · Daniel |
| T-024 | | Los dos comandos del administrador para `Sites.Selected`; prueba de escritura en el sitio de la demo y 403 en `DSA-Control` (cierra R-16) | HU-06 | CA-06.1, CA-06.2, CA-06.4 | Daniel + arquitecto-cloud | T-023, T-029 | `docs/admin-sites-selected.md` | Salida guardada de la prueba (escritura correcta y 403) | Azure · tenant · Daniel · **RS** |
| T-025 | | Prueba de R-13: sonda que pide el token de `id-dsa-func` para el flujo y llama a `DisparoAgente`; si falla, plan B de ADR-007 | HU-08 | CA-08.6 | arquitecto-cloud | T-023, T-035 | Sonda temporal, se borra al terminar | 202 con la identidad; rechazo con un usuario no autorizado; solo se registran `aud`, `iss`, `oid`, `tid` | Azure · tenant · **RS** |
| T-026 | | Prueba de R-14: dos creaciones con el mismo `EventId` | HU-06 | CA-06.3 | arquitecto-cloud | T-024 | `tests/integration/r14.md` | Código y cuerpo del error registrados; `graph_client.py` ajustado si hace falta | Azure · tenant |
| T-027 | | Publicar la Function; 30 eventos seguidos (R-15); tramo 1 en 10 ensayos | HU-05 | CA-05.5 | arquitecto-cloud | T-014, T-024, T-025 | — | KQL de T-021: p90 ≤ 10 s; sin errores de memoria | Azure · tenant |

## Épica E3 — Agente y experiencia en Teams

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-028 | [P] | Tres protocolos ficticios (una página, pasos numerados, "Lo que decide una persona") y su conversión a `.docx` | HU-07 | CA-07.3 | instructor-tecnico | T-001 | `protocols/*.md`, `sharepoint/build-protocols.py`, `tests/protocols/test_protocols.py` | `pytest`: un protocolo por tipo, secciones obligatorias, `.docx` generado | local |
| T-029 | | Script idempotente de SharePoint: lista, columnas, índice y unicidad de `EventId`, biblioteca, comprobación de `DSA-Control`, carga de protocolos | HU-07 | CA-07.1, CA-07.2 | arquitecto-m365 | T-011, T-028 | `sharepoint/provision.ps1`, `tests/sharepoint/provision.Tests.ps1` | Dos ejecuciones seguidas: la segunda no crea nada (salida guardada); Pester de la comparación con `columnas.json` | tenant · Daniel |
| T-030 | [P] | Cuatro tarjetas 1.5, copia versionada del esquema, datos de ejemplo y pruebas | HU-09 | CA-09.1, CA-09.2, CA-09.3, CA-09.4, CA-09.5, RNF-07, RNF-08 | arquitecto-m365 | T-001 | `cards/*.json`, `cards/schema/adaptive-card-1.5.json`, `cards/ejemplos/`, `tests/cards/test_cards.py` | `pytest tests/cards`: esquema, solo `Action.Submit`, sin `isEnabled`, `maxLines: 3`, < 28 KB, ningún texto que afirme una acción ejecutada | local |
| T-031 | [P] | Instrucciones del agente con el bloque aislado de horario | HU-08 | CA-08.1, CA-08.2, CA-08.7 | arquitecto-m365 | — | `agent/instrucciones.md` | Revisión contra Art. 1 y §5.0; el bloque `REGLA-HORARIO` existe una sola vez | local · **RS** |
| T-032 | [P] | Cinco casos de prueba con severidad y protocolo esperados | HU-08 | CA-08.5, CA-08.7 | qa-verificacion | T-004, T-031 | `agent/casos-prueba.md` | Revisión: cubren los tres tipos, la regla de horario y un caso que tienta a "llamar a la policía" | local |
| T-033 | | Solución `DelSensorAlAgente`, variables de entorno y conexiones de `agente-dsa` | HU-08 | CA-08.3, CA-08.4 | arquitecto-m365 | — | Pasos en la guía (T-042) | Captura de la solución con sus componentes | tenant |
| T-034 | | Flujo `LeerIncidente` | HU-08 | CA-08.3 | arquitecto-m365 | T-029, T-033 | Pasos en la guía | Prueba desde el agente con un `eventId` real | tenant |
| T-035 | | Flujo `DisparoAgente` (HTTP, usuarios específicos) → *Ejecutar agente* | HU-08 | CA-08.3 | arquitecto-m365 | T-033 | Pasos en la guía | 202 con el token del operador; 401 con otro usuario | tenant · **RS** |
| T-036 | | Agente de Operaciones: en-US, instrucciones, conocimiento `Protocolos`, herramientas, publicación; prueba de R-17 | HU-08 | CA-08.3 | arquitecto-m365 | T-029, T-031, T-034, T-035 | Pasos en la guía | Una ejecución con *Ejecutar agente* cita el protocolo correcto (página *Activity*) | tenant |
| T-037 | | `PublicarIncidente`, parte 1: leer, idempotencia, actualizar, limitar la severidad a un nivel, responder al agente | HU-10 | CA-10.4, CA-08.7 | arquitecto-m365 | T-036 | Pasos en la guía | La herramienta responde en < 10 s; segunda llamada con el mismo `eventId` → "ya publicado" | tenant |
| T-038 | | `PublicarIncidente`, parte 2: tarjeta y espera, rama de decisión, solo lectura, rama de vencimiento; pruebas R-M1 a R-M5 en `Pruebas spike` | HU-09, HU-10 | CA-09.1, CA-10.1, CA-10.2, CA-10.3, CA-10.5, CA-10.6 | arquitecto-m365 | T-030, T-037 | Pasos en la guía; `tests/integration/tarjeta.md` | Con `PT2M`: vence → `Sin respuesta` sin decisión; respuesta → campos escritos; dos cuentas → el elemento no cambia | tenant · **RS** |
| T-039 | | Tramo 2 en 10 ensayos con `demo/inject.ps1` (cierra R-18) | HU-08 | CA-08.6 | qa-verificacion | T-038, T-040 | `tests/integration/tramo2.md` | `demo/measure.ps1`: p90 ≤ 20 s | tenant · Daniel |
| T-040 | | `demo/measure.ps1` y `demo/inject.ps1` con `SpikeLogic.psm1`; consentimiento delegado de `ChannelMessage.Read.All` | HU-08, HU-05 | CA-08.6, CA-05.5 | qa-verificacion | T-029, T-035 | `demo/measure.ps1`, `demo/inject.ps1`, `demo/tests/*.Tests.ps1` | Pester de las funciones puras; una ejecución real con 1 incidente | tenant · Daniel |
| T-041 | | Casos del agente: 5 × 3 corridas y registro | HU-08 | CA-08.5, CA-08.7 | qa-verificacion | T-032, T-038 | `tests/integration/casos-agente.md` | Cada caso acierta en 2 de 3; **cero** afirmaciones de acciones ejecutadas | tenant |
| T-042 | | Guía de configuración desde §8.1, con apartado "Si no tienes capacidad para un Sandbox" y enlace oficial en cada paso | HU-08 | CA-08.3, CA-08.4, CA-06.4 | arquitecto-m365 | T-033 a T-038 | `agent/GUIA-CONFIGURACION.md` | Revisión de enlaces; los pasos coinciden con lo construido | local |

## Épica E4 — Gobernanza y operación

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-043 | [P] | Guía de gobernanza: tabla "Se automatiza / Lo decide siempre una persona", temas de CA-11.2, deuda de IoT Hub con su alternativa y costo, lista de 10 puntos | HU-11 | CA-11.1, CA-11.2, CA-11.3, CA-11.4 | revisor-seguridad | — | `docs/gobernanza.md` | Revisión: cada afirmación de producto enlaza a Learn | local |
| T-044 | [P] | Créditos: estimación por incidente, límite por agente y presupuesto separado | HU-12 | CA-12.3, CA-12.4 | arquitecto-m365 | — | Sección del README (T-051), `agent/GUIA-CONFIGURACION.md` | Tabla con la tarifa oficial y enlace a la página de facturación | local |
| T-045 | | Revisión de seguridad de identidades, permisos, flujos y tarjetas | HU-06, HU-10, HU-11 | CA-06.1, CA-10.3, Art. 4 | revisor-seguridad | T-024, T-025, T-038 | `docs/adr/ADR-007-identidad-y-permisos.md` (estado) | Acta de revisión en la verificación | tenant · Azure |

## Épica E5 — Entrega

| ID | | Tarea | HU | CA | Rol | Depende de | Archivos | Verificación | Necesita |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-046 | | `demo/reset.ps1`: incidentes de prueba a la papelera, `dedup` y `ratelimit` vacías, ≤ 2 min | HU-14 | CA-14.2 | arquitecto-m365 | T-029, T-027 | `demo/reset.ps1`, `demo/tests/reset.Tests.ps1` | Ejecución cronometrada; los elementos aparecen en la papelera | tenant · Azure |
| T-047 | | `demo/preflight.ps1` con todas las comprobaciones de CA-14.3 | HU-14 | CA-14.3 | qa-verificacion | T-027, T-040 | `demo/preflight.ps1`, `demo/tests/preflight.Tests.ps1` | Ejecución en ≤ 3 min; amarillo por el entorno predeterminado; incidente `EsPrueba` llega a `Pendiente de decisión` | tenant · Azure |
| T-048 | [P] | `demo/retrigger.ps1` | HU-14 | CA-14.2 | arquitecto-m365 | T-035 | `demo/retrigger.ps1` | Un incidente dejado en `Nuevo` pasa a `Pendiente de decisión` | tenant |
| T-049 | | Limpieza del spike: agente `Spike Latencia EN`, su flujo y la lista `SpikeLatencia`; actualizar la bitácora | — | — | arquitecto-m365 | T-039 | `spikes/p1-latencia/BITACORA.md` | La bitácora registra cada borrado | tenant · Daniel |
| T-050 | | Runbook de los tres actos y lista de los 3 videos de respaldo | HU-14 | CA-14.1, CA-14.4 | instructor-tecnico | T-046, T-047 | `demo/RUNBOOK.md` | Revisión contra el plan de la sesión; cada paso tiene comando y qué se ve | local |
| T-051 | | README en español e inglés con diagrama Mermaid, requisitos, despliegue, costos, limpieza; licencia MIT | HU-13 | CA-13.1, CA-13.2, CA-13.4 | instructor-tecnico | T-022, T-042, T-044 | `README.md`, `README.en.md`, `LICENSE` | El diagrama coincide con §2 del plan; sin marcas comerciales | local |
| T-052 | | 10 ensayos de punta a punta seguidos y el runbook completo dos veces | HU-14 | OBJ-1, OBJ-2, CA-05.5, CA-08.6 | qa-verificacion | T-027, T-039, T-047, T-050 | `tests/integration/ensayos.md` | 10 de 10 exitosos; total p90 ≤ 30 s y ninguno > 60 s | tenant · Azure · Daniel |
| T-053 | | Grabar los 3 videos de respaldo | HU-14 | CA-14.4 | Daniel | T-052 | — | Videos guardados fuera del repositorio | Daniel |
| T-054 | | Prueba de un tercero que sigue el README en un tenant y una suscripción limpios | HU-13 | CA-13.3 | qa-verificacion | T-051 | `tests/integration/tercero.md` | Registro con tiempo ≤ 60 min. **Riesgo de calendario:** puede quedar para después de la sesión | tenant · Azure |
| T-055 | | Publicación del repositorio: gitleaks de todo el historial, revisión de IDs, URLs y correos, y cambio a público con aprobación de Daniel | HU-13 | CA-13.5 | revisor-seguridad | T-051 | — | gitleaks sin hallazgos; acta del revisor; aprobación explícita de Daniel | Daniel · **RS** |

Fuera de alcance: **HU-03** (sensor físico), porque su condición del 25 de octubre no se cumplió (plan §12).

## Orden recomendado

1. **27 de octubre:** T-001, T-002, T-003, T-004, T-009, T-010, T-013, T-015, T-028, T-030, T-031, T-043 en paralelo; en el tenant, T-033 y T-035.
2. **28 de octubre:** T-005 a T-008, T-011, T-012, T-016, T-017; en el tenant, T-029, T-034, T-036, T-040.
3. **29 de octubre:** T-014, T-018 a T-022, T-032, T-037, T-038, T-039, T-044. **Límite para T-023 (suscripción).**
4. **30 de octubre:** T-023 a T-027, T-045, T-046, T-047, T-048.
5. **31 de octubre:** T-041, T-042, T-049, T-052.
6. **1 a 3 de noviembre:** T-050, T-051, T-053, Fase 4; **4 de noviembre:** T-055.

## Matriz de trazabilidad HU → CA → tarea → prueba

| HU | CA | Tareas | Prueba o evidencia |
| --- | --- | --- | --- |
| HU-01 | CA-01.1 | T-005 | `tests/simulator/` |
| | CA-01.2 | T-005 | `tests/simulator/` (código 2) |
| | CA-01.3 | T-003 | `tests/schemas/test_evento.py` |
| | CA-01.4 | T-001, T-005 | `.env.example`; prueba de lectura de entorno; gitleaks |
| HU-02 | CA-02.1 | T-006 | `tests/simulator/test_burst.py` |
| | CA-02.2 | T-009, T-052 | `tests/function/test_dedup.py`; ensayo con ráfaga |
| HU-03 | CA-03.1 a CA-03.3 | — | Fuera de alcance |
| HU-04 | CA-04.1 | T-015, T-016, T-017 | `bicep build`; `tests/infra/test_template.py` |
| | CA-04.2 | T-018 | CI |
| | CA-04.3 | T-019, T-023 | Salida de despliegue y eliminación |
| | CA-04.4 | T-016, T-017, T-018 | `tests/infra/test_template.py` |
| | CA-04.5 | T-020, T-022 | `docs/costos.md` |
| HU-05 | CA-05.1 | T-004, T-007, T-008 | `tests/function/test_enrich.py` |
| | CA-05.2 | T-009 | `tests/function/test_dedup.py` |
| | CA-05.3 | T-007, T-014 | `tests/function/`; registro `EventRejected` |
| | CA-05.4 | T-014 | `pytest --cov=function/core --cov-fail-under=80` |
| | CA-05.5 | T-021, T-027, T-040, T-052 | `infra/queries/tramo1.kql`; `demo/measure.ps1` |
| HU-06 | CA-06.1 | T-012, T-024, T-045 | Salida de la prueba de escritura |
| | CA-06.2 | T-024 | Salida con 403 en `DSA-Control` |
| | CA-06.3 | T-011, T-026 | `tests/contract/test_columnas.py` |
| | CA-06.4 | T-019, T-024, T-042 | `docs/admin-sites-selected.md` |
| HU-07 | CA-07.1 | T-029 | Salida del script |
| | CA-07.2 | T-029 | Segunda ejecución sin cambios; Pester |
| | CA-07.3 | T-028 | `tests/protocols/test_protocols.py` |
| HU-08 | CA-08.1 | T-031 | Revisión |
| | CA-08.2 | T-031 | Revisión (bloque único) |
| | CA-08.3 | T-033 a T-036, T-042 | Guía revisada; agente publicado |
| | CA-08.4 | T-033, T-042 | Guía |
| | CA-08.5 | T-032, T-041 | `tests/integration/casos-agente.md` |
| | CA-08.6 | T-013, T-025, T-039, T-040, T-052 | `demo/measure.ps1` |
| | CA-08.7 | T-031, T-037, T-041 | Casos del agente; límite en el flujo |
| HU-09 | CA-09.1 | T-030, T-038 | `tests/cards/test_cards.py` |
| | CA-09.2 | T-030 | `tests/cards/test_cards.py` |
| | CA-09.3 | T-030 | `tests/cards/test_cards.py` |
| | CA-09.4 | T-030 | `tests/cards/test_cards.py` |
| | CA-09.5 | T-030 | `tests/cards/test_cards.py` (textos prohibidos) |
| HU-10 | CA-10.1 | T-038 | `tests/integration/tarjeta.md` |
| | CA-10.2 | T-038 | Ídem |
| | CA-10.3 | T-038, T-045 | Revisión: el flujo no tiene acciones de correo ni llamada |
| | CA-10.4 | T-037, ADR-008 | ADR-008; duración de la herramienta |
| | CA-10.5 | T-038 | Prueba con `PT2M` |
| | CA-10.6 | T-038 | Prueba con dos cuentas (texto reformulado, plan §14) |
| HU-11 | CA-11.1 a CA-11.4 | T-043 | Revisión de `docs/gobernanza.md` |
| HU-12 | CA-12.1 | T-010 | `tests/function/test_ratelimit.py` |
| | CA-12.2 | T-017 | `bicep build`; presupuesto visible en Azure |
| | CA-12.3 | T-044 | README |
| | CA-12.4 | T-044 | Guía; en la demo en vivo aplica ADR-002 |
| HU-13 | CA-13.1 | T-051 | Revisión |
| | CA-13.2 | T-051 | Revisión contra el plan §2 |
| | CA-13.3 | T-054 | `tests/integration/tercero.md` |
| | CA-13.4 | T-051 | `LICENSE`; revisión de marcas |
| | CA-13.5 | T-002, T-055 | gitleaks del historial; acta |
| HU-14 | CA-14.1 | T-050 | Revisión |
| | CA-14.2 | T-046 | Ejecución cronometrada |
| | CA-14.3 | T-047 | Ejecución cronometrada |
| | CA-14.4 | T-050, T-053 | Lista y videos |
| Objetivos | OBJ-1, OBJ-2 | T-052 | `tests/integration/ensayos.md` |
| | OBJ-3 | T-046 | Ídem CA-14.2 |
| | OBJ-4 | T-054 | Ídem CA-13.3 |
| | OBJ-5 | T-022 | `docs/costos.md` y presupuesto |
