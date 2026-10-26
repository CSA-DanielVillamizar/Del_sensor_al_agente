# Tarjetas adaptativas (T-030 · HU-09, HU-10)

Cuatro tarjetas **Adaptive Cards 1.5** que publica el flujo del agente `PublicarIncidente` en el canal `Centro de operaciones` ([ADR-008](../docs/adr/ADR-008-publicacion-tarjeta-y-decision.md)).

| Archivo | Cuándo se usa | Criterios |
| --- | --- | --- |
| `incidente-normal.json` | Severidad propuesta `Baja` o `Media` | CA-09.1 a CA-09.5 |
| `incidente-alta.json` | Severidad propuesta `Alta` o `Crítica`: contenedor con estilo `attention` y la severidad escrita en texto (RNF-07) | CA-09.1 a CA-09.5 |
| `incidente-solo-lectura.json` | Reemplazo de la tarjeta tras la decisión, sin acciones ni campos (*Update message*) | CA-10.2 |
| `sin-respuesta.json` | Aviso al vencer la espera (`dsa_TimeoutDecision`, 15 min); dice que no se registró ninguna decisión | CA-10.5 |
| `ejemplos/*.data.json` | Datos ficticios para las pruebas, uno por tarjeta | — |
| `schema/adaptive-card-1.5.json` | Copia versionada del esquema oficial | CA-09.4 |

## Por qué no hay plantillas

Power Automate no admite la función de plantillas de Adaptive Cards (`${...}`, `$data`, `$when`), así que el flujo arma el JSON final reemplazando marcadores con expresiones ([Send proactive Teams messages](https://learn.microsoft.com/microsoft-copilot-studio/advanced-proactive-message#send-a-proactive-adaptive-card)). Los marcadores tienen la forma `{{campo}}` y **siempre van dentro de una cadena JSON**, de modo que cada archivo es JSON válido y valida contra el esquema aun sin reemplazar.

Teams admite la versión 1.5 del esquema ([Adaptive Cards for agent design — schema and host compatibility](https://learn.microsoft.com/agents/design-guidelines/adaptive-cards-for-agent-design#schema-and-host-compatibility)). Las tarjetas usan solo `Action.Submit`, no usan `isEnabled` y pesan menos de ~28 KB, el límite de mensaje del conector de Teams ([Teams connector — known issues and limitations](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)).

## Marcadores

Fuente: elemento de `Eventos de seguridad` leído por `EventId` en el paso 2 de ADR-008, entradas de la herramienta (`PublicarIncidente`) o la respuesta de la tarjeta. Las horas se convierten con `convertFromUtc` y la zona de Windows `SA Pacific Standard Time` (UTC−05:00 Bogotá, Lima, Quito) ([convertFromUtc](https://learn.microsoft.com/azure/logic-apps/workflow-definition-language-functions-reference#convertFromUtc), [Default time zones](https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-time-zones)). El sufijo ` COT` está escrito en la tarjeta, no en el marcador (RNF-08).

| Marcador | Tarjetas | Origen | Expresión o regla |
| --- | --- | --- | --- |
| `{{eventId}}` | todas | Elemento, columna `EventId` | Valor tal cual. Aparece en `Ref. {{eventId}}` (lo usa `demo/measure.ps1`) y en `data.eventId` de cada acción |
| `{{tipoEvento}}` | todas | Elemento, `TipoEvento` | `replace(TipoEvento, '_', ' ')`, por ejemplo `puerta forzada` |
| `{{zona}}` | todas | Elemento, `Zona` | `Z-xx` |
| `{{nombreZona}}` | todas | Elemento, `NombreZona` | Del catálogo ficticio `data/zonas.json` |
| `{{sitio}}` | normal, alta, solo lectura | Elemento, `Sitio` | Del catálogo |
| `{{horaLocal}}` | todas | Elemento, `FechaEventoUtc` | `convertFromUtc(FechaEventoUtc, 'SA Pacific Standard Time', 'HH:mm')` |
| `{{severidadInicial}}` | normal, alta, solo lectura | Elemento, `SeveridadInicial` | Escala §5.0 |
| `{{severidadPropuesta}}` | todas | Entrada `severidadPropuesta`, ya limitada a un nivel (ADR-008 paso 3) | Escala §5.0; elige la variante: `Alta`/`Crítica` → `incidente-alta.json` |
| `{{justificacionSeveridad}}` | normal, alta, solo lectura | Entrada `justificacionSeveridad` | Si llega vacía (severidad sin cambio): `Sin cambio respecto a la severidad inicial.` |
| `{{repeticiones}}` | normal, alta, solo lectura | Elemento, `Repeticiones` | `string(Repeticiones)` |
| `{{resumen}}` | normal, alta, solo lectura | Entrada `resumen` | La tarjeta lo corta a 3 líneas (`maxLines: 3`) |
| `{{pasosProtocolo}}` | normal, alta, solo lectura | Entrada `pasosProtocolo` | La tarjeta lo corta a 3 líneas (`maxLines: 3`) |
| `{{protocoloAplicado}}` | normal, alta, solo lectura | Entrada `protocoloAplicado` | Nombre del documento de `Protocolos`; si no hay: `Sin protocolo encontrado` |
| `{{decision}}` | solo lectura | Respuesta de la tarjeta, `data.decision` | `Atender`, `Escalar a autoridades` o `Falsa alarma` |
| `{{decididoPor}}` | solo lectura | Respondiente → *Get user profile (V2)* | Nombre para mostrar de quien respondió (R-M4: el nombre exacto del campo se anota al construir el flujo) |
| `{{horaDecision}}` | solo lectura | `utcNow()` en la rama de respuesta | `convertFromUtc(utcNow(), 'SA Pacific Standard Time', 'HH:mm')` |
| `{{observacion}}` | solo lectura | Respuesta de la tarjeta, campo `observacion` | Si llega vacía: `Sin observación` |
| `{{minutosEspera}}` | sin respuesta | Variable de entorno `dsa_TimeoutDecision` | `15` para `PT15M` |

## Escapar los valores (obligatorio)

Los textos del agente pueden traer comillas, barras invertidas o saltos de línea. Pegados tal cual dentro de una cadena JSON rompen la tarjeta. La prueba `test_escaping_keeps_json_valid` reemplaza cada marcador por el valor **escapado como cadena JSON**, que es lo que debe hacer el flujo.

Forma recomendada, **pendiente de verificar en el tenant (T-038)**: en lugar de concatenar texto, construir la tarjeta en una acción *Compose* cuyo contenido sea el objeto JSON con el contenido dinámico insertado en cada valor, y pasar `string(outputs('Compose'))` al campo de la tarjeta. Si el diseñador no serializa los valores escapados, la alternativa es escapar cada valor con `replace` antes de insertarlo. Learn no documenta cómo serializa *Compose* los valores dinámicos dentro de un objeto: se trata como riesgo **R-C1** hasta probarlo con un resumen que contenga comillas y un salto de línea.

## Topes de longitud

Para no pasar de ~28 KB, el flujo recorta los textos libres antes de insertarlos (por ejemplo `substring(x, 0, min(length(x), 1000))`): `resumen` y `pasosProtocolo` a 1000 caracteres, `justificacionSeveridad` y `observacion` a 500. La tarjeta muestra de todos modos solo 3 líneas del resumen y del protocolo; el texto completo queda en la lista. La prueba de tamaño usa esos topes con caracteres de 2 bytes y 100 caracteres en los demás marcadores.

## Acciones y decisión

- Tres `Action.Submit` con `title` y `data.decision` iguales: `Atender`, `Escalar a autoridades`, `Falsa alarma` (CA-09.3). El flujo usa `data.decision`, no el título (ADR-008, "Quién respondió").
- `data.eventId` permite comprobar en la rama de respuesta que la respuesta corresponde al incidente.
- `Input.Text` con `id` `observacion`, opcional (sin `isRequired`), multilínea, 500 caracteres.
- La tarjeta dice que "Escalar a autoridades" solo se registra y que ningún componente contacta a nadie (CA-09.5, CA-10.3).

## Lo que comprueban las pruebas

`tests/cards/test_cards.py` (`.venv/Scripts/python -m pytest tests/cards`):

- Cada plantilla y cada tarjeta ya rellenada con su ejemplo validan contra `schema/adaptive-card-1.5.json`; no quedan marcadores sin reemplazar; `version` = `1.5`.
- Sin sintaxis de plantillas, solo `Action.Submit`, sin `selectAction`, sin `isEnabled`.
- Tamaño < 28 KB con el ejemplo y con cada marcador de 1000 caracteres no ASCII.
- Encabezado "Propuesta del Agente de Operaciones", hora con `COT`, `Ref. {{eventId}}` en letra pequeña, campos de CA-09.2, `maxLines: 3` en resumen y protocolo, contenedor `attention` solo en la variante alta.
- Tres acciones con `data.decision`, `Input.Text` opcional `observacion`; las tarjetas de solo lectura y sin respuesta no tienen acciones ni campos.
- Ningún texto afirma una acción ejecutada ni haber avisado, llamado, escrito, informado o notificado a una persona o autoridad (lista `FORBIDDEN`).
- Los ejemplos cubren exactamente los marcadores de su tarjeta, cada marcador está documentado en esta tabla y los ejemplos usan el catálogo ficticio.

## Esquema versionado

`schema/adaptive-card-1.5.json` es una copia sin cambios del esquema oficial publicado en el repositorio `microsoft/AdaptiveCards` (licencia MIT):

- Origen: `https://raw.githubusercontent.com/microsoft/AdaptiveCards/main/schemas/1.5.0/adaptive-card.json`
- Descargado: 2026-10-26 · SHA-256 `32c91fb285180a266a55b3475dd0396e63fe079311714d3a14963b41f5e17920`
- Dialecto: JSON Schema draft-06, con `additionalProperties: false` en cada elemento (rechaza propiedades desconocidas).

El esquema 1.5 incluye `Action.Execute` e `isEnabled`; que el esquema los admita no significa que las tarjetas los usen: las pruebas los prohíben.

## Riesgos abiertos

| ID | Riesgo | Cómo se cierra |
| --- | --- | --- |
| R-C1 | Escapado de los valores dinámicos al armar la tarjeta en el flujo | Prueba en `Pruebas spike` con comillas y salto de línea en `resumen` (T-038) |
| R-M3 | *Update message* podría aceptar solo texto y no la tarjeta de solo lectura (ADR-008) | Misma prueba; plan B en ADR-008 |
| R-C2 | Teams móvil puede mostrar distinto el `FactSet` y el contenedor con `bleed` ([Adaptive Cards for agent design](https://learn.microsoft.com/agents/design-guidelines/adaptive-cards-for-agent-design#schema-and-host-compatibility) recomienda probar en anchos estrechos) | Revisión visual en Teams de escritorio y móvil durante T-038 |
