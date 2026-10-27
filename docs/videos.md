# Videos de la demo

Tres videos cortos, uno por cada acto de la demo de la sesión "Del sensor al agente" (Microsoft 365 Live 2026). Muestran el sistema funcionando de punta a punta, con voz en español y subtítulos.

Los videos completos están en la carpeta [`docs/videos/`](videos/) del repositorio, para verlos como guía antes de desplegar la solución. También se pueden descargar desde la versión [`videos-demo`](https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente/releases/tag/videos-demo). Todos los datos que aparecen son ficticios: zonas, sitios, protocolos y cuentas.

| Video | Duración | Descarga | Subtítulos |
| --- | --- | --- | --- |
| 1. Del sensor a la tarjeta | 1 min 15 s | [video-1-del-sensor-a-la-tarjeta.mp4](videos/video-1-del-sensor-a-la-tarjeta.mp4) | [.srt](videos/video-1-del-sensor-a-la-tarjeta.srt) |
| 2. Dentro del agente | 1 min 21 s | [video-2-dentro-del-agente.mp4](videos/video-2-dentro-del-agente.mp4) | [.srt](videos/video-2-dentro-del-agente.srt) |
| 3. La persona decide | 1 min 8 s | [video-3-la-persona-decide.mp4](videos/video-3-la-persona-decide.mp4) | [.srt](videos/video-3-la-persona-decide.srt) |

---

## 1. Del sensor a la tarjeta

**De qué se trata:** el recorrido completo de una alerta, desde que el sensor la envía hasta que el supervisor la ve en Teams, y cómo el sistema evita que un sensor ruidoso sature al equipo.

**Qué se ve:**
- **La consola.** El simulador envía una *puerta forzada* en la zona Z-03 (bodega norte) y muestra el `eventId` del evento.
- **La lista `Eventos de seguridad` en SharePoint.** El incidente aparece como `Nuevo` y, segundos después, pasa a `Pendiente de decisión`.
- **La tarjeta en el canal `Centro de operaciones` de Teams.** Muestra qué pasó, dónde, la severidad inicial (Alta), la propuesta del agente (Crítica, por ocurrir fuera de horario) con su justificación, el resumen y los pasos del protocolo. La referencia de la tarjeta es el mismo `eventId` de la consola.
- **La ráfaga.** Se envían 20 eventos iguales de movimiento en zona restringida en unos 5 segundos. En la lista queda **un solo incidente** con `Repeticiones = 20`, y el supervisor recibe **una sola tarjeta**.

**Qué te llevas:** la deduplicación ocurre en Azure, antes de llegar al agente. Así se cuida la atención del equipo (la alerta que más daño hace es la que se ignora por cansancio) y también el costo, porque cada ejecución del agente consume créditos.

---

## 2. Dentro del agente

**De qué se trata:** cómo está construido el agente de Copilot Studio y por qué no puede hacer más de lo que debe.

**Qué se ve:**
- **Las instrucciones del Agente de Operaciones.** La sección "Lo que nunca haces" dice que nunca llama a nadie, nunca abre ni bloquea una puerta y nunca cierra un caso. Está también el bloque `REGLA-HORARIO`: fuera de horario, la severidad sube un nivel, y nunca más de uno.
- **El conocimiento.** La biblioteca `Protocolos` en SharePoint, con un protocolo por tipo de evento. Cada protocolo tiene su sección "Lo que decide una persona". El agente los consulta, pero no los cambia.
- **Las herramientas.** Son solo dos: `LeerIncidente`, que lee el incidente de la lista, y `PublicarIncidente`, que publica la propuesta y espera a la persona. Ninguna envía correos, llama ni abre nada.
- **El flujo `DisparoAgente`.** Azure crea primero el registro en la lista y después llama a este flujo con un solo dato: el identificador del evento. Solo la identidad administrada de la Function puede llamarlo.
- **La actividad.** La bitácora de cada ejecución del agente, con cada herramienta y cada consulta.

**Qué te llevas:** los límites del agente están escritos en sus instrucciones y, además, garantizados por el diseño. Lo que no está como herramienta, el agente no lo puede hacer. Y si alguien pregunta por qué propuso algo, la respuesta está en la actividad.

---

## 3. La persona decide

**De qué se trata:** la decisión humana, cómo queda registrada y cómo cambia el comportamiento del agente cuando cambia una regla.

**Qué se ve:**
- **La decisión.** El supervisor escribe una observación y pulsa *Escalar a autoridades*. La tarjeta se reemplaza por una versión de solo lectura con la decisión, quién la tomó y a qué hora.
- **El registro en la lista.** Quedan `Decision`, `DecididoPor` y `FechaDecision`. El sistema no llamó a nadie: registró que una persona decidió escalar. La llamada la hace esa persona.
- **El cambio de regla.** El jefe de seguridad edita el bloque `REGLA-HORARIO` con texto, no con código, y publica el agente.
- **El segundo evento.** Llegan accesos denegados repetidos en la recepción (zona Z-02), con severidad inicial Media. Con la regla nueva, la hora del evento queda dentro del horario y el agente propone la misma severidad, con su justificación: "sin cambio".

**Qué te llevas:** el registro de quién decidió es tan importante como la decisión. Y las reglas del negocio las mantiene quien conoce el negocio: mismo sistema, otra regla, otra propuesta.

---

## Para reproducirlo

El paso a paso para desplegar la solución en tu propio tenant está en el [README](../README.md#despliegue-paso-a-paso) y en el [instructivo para asistentes](Instructivo_Asistente_Evento.md).
