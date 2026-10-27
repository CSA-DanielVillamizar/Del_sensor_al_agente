# Runbook de la demo en vivo

| Campo | Valor |
| --- | --- |
| Tarea | T-050 (HU-14, CA-14.1, CA-14.4) |
| Duración de la demo | Minutos 18 a 40 de la sesión, en tres actos |
| Promesa | Una alerta de un sensor llega a Teams como propuesta, y una persona decide. Nada más. |

Regla del día: todo lo que tarda más de un minuto ya está construido. En vivo solo se dispara un evento, se muestra el resultado y se cambia una regla.

Todos los comandos se ejecutan en PowerShell 7, desde la raíz del repositorio. Los datos son ficticios: zonas, cámaras, protocolos y cuentas.

---

## 1. Preparación

### T-120 min: el entorno

- [ ] Cable de red conectado. Hotspot de respaldo encendido y probado.
- [ ] Notificaciones del sistema, correo y chat en silencio.
- [ ] Cámara, luz y audio probados en una llamada de Teams con el organizador.
- [ ] Zoom del navegador y de Teams al 125 %.
- [ ] Los 3 videos de respaldo abiertos en pestañas, en orden (sección 6).
- [ ] El moderador tiene el enlace a los videos.
- [ ] QR y enlace del repositorio listos en la diapositiva final.

### T-60 min: la demo

Abre una consola de PowerShell 7 en la raíz del repositorio y deja esa ventana para toda la sesión.

**1. Activar el entorno de Python y cargar `.env` en la sesión.** `demo/inject.ps1` lee las variables del entorno, no del archivo.

```powershell
.\.venv\Scripts\Activate.ps1
Get-Content .env | Where-Object { $_ -match '^[A-Z_]+=.+' } | ForEach-Object { $n, $v = $_ -split '=', 2; Set-Item "env:$n" $v }
```

**2. Iniciar sesión.** Con la cuenta del operador.

```powershell
az login
az account show --query name -o tsv
```

En pantalla: el nombre de la suscripción de la demo.

**3. Encender la instancia *always ready*.** Evita el arranque en frío de la Function.

```powershell
./infra/set-always-ready.ps1 -Scenario sesion
```

En pantalla: `-> escenario sesion, always ready = 1`.

**4. Preflight.** Tarda 3 minutos o menos.

```powershell
./demo/preflight.ps1
```

En pantalla: un resultado verde, amarillo o rojo por componente. Lo esperado:

| Comprobación | Resultado esperado |
| --- | --- |
| PowerShell 7 | Verde |
| IoT Hub, Function y SharePoint | Verde |
| Entorno de Power Platform | Amarillo en la demo en vivo, con referencia a [ADR-002](../docs/adr/ADR-002-entorno-demo-en-vivo.md). Es esperado |
| Auditoría de Dataverse | Verde |
| Créditos: forma de pago y días hasta el vencimiento | Verde. Rojo si la capacidad vence antes de la sesión |
| Consumo del mes frente al límite del agente | Verde, por debajo del 80 %. Amarillo si `DSA_CREDITS_USED` está vacío: copia el dato del centro de administración de Power Platform a `.env` antes de empezar |
| Nueva infraestructura de Power Platform | Se informa. Amarillo mientras `DSA_NEW_INFRA` esté vacío |
| Prueba de punta a punta con `EsPrueba = Sí` | Verde: llega a `Pendiente de decisión` a tiempo (20,5 s en el ensayo del 2026-10-26). Publica una tarjeta de prueba en el canal |

Resultado general esperado: **amarillo**, por el entorno predeterminado. El preflight tardó 103 s en el ensayo.

Cualquier rojo se resuelve ahora o se decide pasar a los videos. No se empieza la sesión con un rojo sin decidir.

**5. Reautenticar las conexiones.** En Copilot Studio y Power Automate, con la cuenta de servicio `agente-dsa`, abre las conexiones de la solución y confirma que ninguna pide iniciar sesión. Si alguna lo pide, reautentícala.

**6. Tres ensayos de punta a punta.** Uno por tipo de evento. Espera al menos 60 s entre uno y otro: dos eventos del mismo dispositivo y tipo dentro de 60 s se cuentan como uno solo (ADR-006).

```powershell
python -m simulator --type puerta_forzada --zone Z-03
python -m simulator --type movimiento_zona_restringida --zone Z-01
python -m simulator --type acceso_denegado_repetido --zone Z-02
```

En pantalla: tres tarjetas en el canal `Centro de operaciones`, cada una en 30 segundos o menos. Responde las tres desde la tarjeta.

**7. Dejar todo en estado inicial.** Tarda 2 minutos o menos.

```powershell
./demo/reset.ps1 -All
```

En pantalla: los elementos van a la papelera del sitio y las tablas `dedup` y `ratelimit` quedan vacías. El tiempo total aparece al final.

**8. Probar la sesión del plan B sin escribir nada.**

```powershell
./demo/inject.ps1 -Type puerta_forzada -Zone Z-03 -WhatIf
```

En pantalla: los campos del incidente y ningún elemento creado.

### Ventanas abiertas, en este orden

| Ventana | Cuenta | Qué muestra |
| --- | --- | --- |
| Consola de PowerShell 7 | Operador | Raíz del repositorio, entorno activado, letra grande |
| Teams | `Supervisor Demo` | Canal `Centro de operaciones` del equipo `DSA-Demo`, desplazado al final |
| Navegador, pestaña 1 | Operador | Lista `Eventos de seguridad`, vista con `Estado`, `SeveridadInicial`, `SeveridadPropuesta`, `Repeticiones`, `Decision`, `DecididoPor`, `FechaDecision` |
| Navegador, pestaña 2 | `agente-dsa` | Copilot Studio, agente "Agente de Operaciones", página *Overview* |
| Navegador, pestaña 3 | `agente-dsa` | Copilot Studio, página *Activity* del agente |
| Navegador, pestañas 4 a 6 | — | Videos de respaldo 1, 2 y 3 |

La página *Activity* muestra por defecto solo las ejecuciones que usaron las credenciales de quien la mira ([Review agent activity](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity#historical-activity)). Por eso la pestaña 3 usa la cuenta `agente-dsa`.

Comparte la **ventana** de Teams, nunca la pantalla completa: así el público ve la tarjeta tal como la ves tú.

En las notificaciones y en la vista previa del canal, Teams muestra "Card - access it on go.skype.com/cards.unsupported". Es normal: la tarjeta completa se ve dentro del canal. No abras la tarjeta desde la notificación.

---

## 2. Acto 1: el resultado primero (minutos 18 a 25)

Idea del acto: primero el resultado, después cómo funciona.

### Paso 1.1: disparar una puerta forzada

**Comando**

```powershell
python -m simulator --type puerta_forzada --zone Z-03
```

**Qué se ve**

- En la consola: `Enviados 1 evento(s) puerta_forzada desde DEV-SIM-01 en Z-03 (severidad Alta)` y el `eventId`.
- En la lista, en unos 10 segundos: un elemento `puerta_forzada · Z-03`, `Estado = Nuevo`, que pasa a `Pendiente de decisión`.

**Qué decir**

> "Esto es un sensor de puerta en la bodega norte. Acaba de reportar una apertura sin credencial. Miren el reloj."

### Paso 1.2: la tarjeta en Teams

**Comando:** ninguno. Cambia a la ventana de Teams.

**Qué se ve, en 30 segundos o menos desde el envío**

- Una tarjeta con el encabezado "Propuesta del Agente de Operaciones".
- Tipo de evento, zona `Z-03 · Bodega norte`, hora local `HH:mm COT`.
- Severidad inicial y severidad propuesta, con su justificación.
- Un resumen de tres líneas y tres pasos del protocolo.
- Tres botones: *Atender*, *Escalar a autoridades* y *Falsa alarma*.
- `Ref. {eventId}` en letra pequeña, el mismo `eventId` de la consola.

**Qué decir**

> "Qué pasó, dónde, qué tan grave y qué dice el protocolo. En tres líneas, en el lugar donde el equipo ya trabaja. El agente propone. La decisión es de la persona."

No pulses ningún botón todavía. La decisión se toma en el acto 3.

### Paso 1.3: un sensor ruidoso

**Comando**

```powershell
python -m simulator --type movimiento_zona_restringida --zone Z-01 --burst 20
```

**Qué se ve**

- En la consola: `Enviados 20 evento(s) ... en` menos de 10 segundos, y 20 `eventId`.
- En la lista: **un solo** elemento nuevo `movimiento_zona_restringida · Z-01`. La columna `Repeticiones` sube hasta 20.
- En Teams: **una sola** tarjeta nueva, con severidad alta resaltada y escrita en texto.

**Qué decir**

> "Veinte alertas iguales en diez segundos. El supervisor recibe una tarjeta, no veinte. La alerta que más daño hace es la que se ignora por cansancio."

> "Cada ejecución del agente consume créditos. Por eso se deduplica antes de llegar a él."

**Transición:** "Ahora veamos qué hay dentro."

---

## 3. Acto 2: dentro del agente (minutos 25 a 33)

Idea del acto: lo importante no es lo que hace el agente, sino lo que no lo dejamos hacer.

Este acto no lleva comandos. Todo se muestra en Copilot Studio, en la pestaña 2.

### Paso 2.1: las instrucciones

**Qué se ve:** *Overview* → *Instructions*. Desplázate a la sección "Lo que nunca haces" y después al bloque `REGLA-HORARIO`.

**Qué decir**

> "El agente lee, clasifica, resume y propone. Nunca llama a nadie, nunca abre ni bloquea una puerta, nunca cierra un caso. Eso está escrito aquí, y además el diseño no le da ninguna herramienta para hacerlo."

> "Este bloque es la regla de horario. Lo vamos a cambiar en vivo en unos minutos."

### Paso 2.2: el conocimiento

**Qué se ve:** *Knowledge*. La biblioteca de SharePoint `Protocolos`, con un documento por tipo de evento. Abre el de puerta forzada y muestra la sección "Lo que decide una persona".

**Qué decir**

> "Los protocolos viven en SharePoint, donde el jefe de seguridad ya los mantiene. El agente los consulta. No los cambia."

### Paso 2.3: las herramientas

**Qué se ve:** *Tools*. `LeerIncidente` y `PublicarIncidente`.

**Qué decir**

> "Dos herramientas. Una lee el incidente de la lista. La otra publica la propuesta y espera a la persona. Ninguna envía correos, llama o abre algo."

### Paso 2.4: cómo se dispara

**Qué se ve:** el flujo `DisparoAgente` en la solución. El disparador HTTP con *Specific users in my tenant* y la acción *Execute Agent*.

**Qué decir**

> "Azure crea primero el registro en la lista. Después llama a este flujo con un solo dato: el identificador del evento. Solo la identidad de la Function puede llamarlo."

Sin identificadores en pantalla: no abras el detalle del disparador que muestra el object ID ni la URL.

### Paso 2.5: qué hizo el agente

**Qué se ve:** la pestaña 3, *Activity*. Abre la ejecución del paso 1.1. Muestra el paso a paso: `LeerIncidente`, la consulta al conocimiento y `PublicarIncidente`.

**Qué decir**

> "Esta es la bitácora. Cada ejecución, cada herramienta, cada consulta. Si alguien pregunta por qué el agente propuso algo, la respuesta está aquí."

**Transición:** "Ahora la persona decide."

---

## 4. Acto 3: la persona decide (minutos 33 a 40)

Idea del acto: la decisión queda registrada, y una regla se cambia sin programar.

### Paso 3.1: escalar

**Comando:** ninguno. En Teams, en la tarjeta de la puerta forzada, escribe una observación corta sin nombres de personas, por ejemplo "Puerta abierta en cámara", y pulsa *Escalar a autoridades*.

**Qué se ve**

- La tarjeta se reemplaza por una versión de solo lectura, sin botones, con la decisión, quién la tomó y la hora `COT`.
- En la lista: `Estado = Escalado`, `Decision = Escalar a autoridades`, `DecididoPor = Supervisor Demo`, `FechaDecision` con la hora.

**Qué decir**

> "El agente no llamó a nadie. Registró que una persona decidió escalar, quién fue y a qué hora. La llamada la hace esa persona."

> "El registro de quién decidió es tan importante como la decisión."

### Paso 3.2: cambiar la regla en vivo

**Qué se hace:** en la pestaña 2, *Overview* → *Instructions* → *Edit*. Cambia **solo** el texto entre `REGLA-HORARIO: inicio` y `REGLA-HORARIO: fin`. Guarda y pulsa **Publish**. Toma el tiempo desde *Publish* hasta el aviso de publicación terminada.

Qué cambiar, según la hora de la sesión:

| Hora de la sesión (COT) | Cambio en el bloque | Efecto en el segundo evento |
| --- | --- | --- |
| Entre 06:00 y 18:00 | Reemplaza las dos apariciones de `18:00` por la hora en punto anterior a la actual. Ejemplo: si son las 15:20, usa `15:00` | La hora actual queda "fuera de horario": la severidad sube un nivel |
| Después de 18:00 (la sesión es a las 21:00) | Reemplaza las dos apariciones de `18:00` por `24:00` | La hora actual queda "en horario": la severidad no sube |
| Antes de 06:00 (solo ensayos de madrugada) | Reemplaza las dos apariciones de `18:00` por `24:00` y las dos de `06:00` por `00:00` | La hora actual queda "en horario": la severidad no sube. Con solo el cambio a `24:00`, la hora sigue fuera del horario y la severidad sube igual |

Fuera del bloque no hay horas ni zona horaria, así que el resto de las instrucciones no cambia.

**Qué decir mientras publica**

> "Fuera de horario, la severidad sube un nivel. El jefe de seguridad cambia esa regla con texto, no con código. Y la regla tiene un tope: nunca más de un nivel."

### Paso 3.3: el segundo evento

Espera a que termine la publicación. Después:

**Comando**

```powershell
python -m simulator --type acceso_denegado_repetido --zone Z-02
```

**Qué se ve**

- Una tarjeta nueva para `Z-02 · Recepción`. La severidad inicial es `Media`.
- Sesión de día, con la regla cambiada: propuesta `Alta`, con la justificación "fuera de horario". La tarjeta usa el estilo de severidad alta.
- Sesión de noche, con la regla cambiada: propuesta `Media`, "sin cambio respecto a la severidad inicial".

**Qué decir**

> "Mismo sistema, otra regla, otra propuesta. Y la decisión sigue siendo de la persona."

### Paso 3.4: cerrar el ciclo

**Comando:** ninguno. Pulsa *Atender* en la tarjeta del paso 3.3. Muestra la lista con los tres incidentes y sus estados. Abre en *Activity* la ejecución del paso 3.3.

Deja la tarjeta del acto 1, la del movimiento en `Z-01`, sin responder. A los 15 minutos pasa sola a `Sin respuesta`, sin ninguna decisión registrada.

**Qué decir**

> "Si nadie responde, el sistema no decide por nadie: el incidente queda sin respuesta, a la vista."

**Transición a gobernanza:** "Esto funciona porque hay cosas que nunca le dejamos al agente."

---

## 5. Si algo falla

Frase de salida para cualquier falla: "Esto es lo que debería pasar." Abre el video del acto y sigue sin perder el ritmo.

| Señal | Qué hacer | Comando |
| --- | --- | --- |
| Más de 60 s sin tarjeta y el elemento está en `Nuevo` | La Function no pudo llamar al flujo. Toma el `eventId` de la consola y reintenta | `./demo/retrigger.ps1 -EventId <eventId>` |
| Más de 60 s sin tarjeta y no hay elemento en la lista | Falla el tramo de Azure. Crea el incidente sin Azure y dispara el flujo directamente | `./demo/inject.ps1 -Type puerta_forzada -Zone Z-03` |
| El simulador termina con `No se pudo enviar a IoT Hub` | Red o cadena de conexión. Usa la contingencia sin Azure | `./demo/inject.ps1 -Type puerta_forzada -Zone Z-03` |
| El elemento llega a `Pendiente de decisión` pero no hay tarjeta | Falla la publicación en Teams. Muestra la lista y pasa al video | Video 1 |
| Error de autenticación en un flujo | Conexión vencida. No se repara en vivo | Video del acto en curso |
| La publicación del paso 3.2 pasa de 3 minutos | Sigue con el registro del paso 3.1 mientras espera; si no termina, video | Video 3 |
| La tarjeta del paso 3.3 muestra la regla anterior | La versión publicada aún no se usa. Muestra el efecto con un evento nocturno, sin depender del reloj | `./demo/inject.ps1 -Type acceso_denegado_repetido -Zone Z-02 -FechaEventoUtc 2026-11-04T03:40:00Z` (22:40 COT de la noche anterior; `inject` rechaza una fecha futura), o video 3 |
| Ves la tarjeta, el público no | Compartes la pantalla equivocada | Comparte la ventana de Teams |
| Internet inestable | Cortes de audio | Cable, hotspot; el moderador comparte los videos |

Reglas del plan B:

- Ningún comando se repite más de una vez en vivo.
- `retrigger` solo actúa si el incidente sigue en `Nuevo`, así que no publica dos veces.
- `inject` crea un incidente con `DeviceId = DEV-INJECT-01`. Dilo en voz alta: "este evento lo creo directamente en la lista".

---

## 6. Videos de respaldo

Se graban el día del congelamiento de contenido, después de un ensayo completo en verde (T-053). No se versionan en el historial: se publican como archivos de la versión `videos-demo` del repositorio, con su reseña en [docs/videos.md](../docs/videos.md). Cada video muestra el resultado esperado, con voz y subtítulos; en vivo se puede bajar el volumen y narrarlo.

| Video | Duración | Acto | Qué debe mostrar |
| --- | --- | --- | --- |
| 1. Del sensor a la tarjeta | 2 a 3 min | Acto 1 | La consola con el comando del paso 1.1 y su `eventId`. El elemento en la lista pasando de `Nuevo` a `Pendiente de decisión`. La tarjeta en Teams con el mismo `Ref.` y un reloj visible. La ráfaga del paso 1.3: 20 envíos, un solo elemento con `Repeticiones = 20` y una sola tarjeta |
| 2. Dentro del agente | 2 a 3 min | Acto 2 | Las instrucciones con la sección "Lo que nunca haces" y el bloque `REGLA-HORARIO`. La biblioteca `Protocolos` y la sección "Lo que decide una persona". Las herramientas `LeerIncidente` y `PublicarIncidente`. El flujo `DisparoAgente` sin identificadores visibles. Una ejecución en *Activity*, paso a paso |
| 3. La persona decide | 2 a 3 min | Acto 3 | *Escalar a autoridades* en la tarjeta, el reemplazo por la versión de solo lectura y los campos `Decision`, `DecididoPor` y `FechaDecision` en la lista. El cambio del bloque `REGLA-HORARIO`, la publicación y su duración. El segundo evento con la severidad distinta y su justificación |

Antes de grabar: ninguna URL de sitio, correo, ID de tenant ni object ID en pantalla. Las cuentas visibles son las de la demo.

---

## 7. Cierre (después de la sesión)

**1. Apagar la instancia *always ready*.** Vuelve al costo de centavos ([docs/costos.md](../docs/costos.md)).

```powershell
./infra/set-always-ready.ps1 -Scenario reposo
```

En pantalla: `-> escenario reposo, always ready = 0`.

**2. Medir la sesión (opcional).** Guarda el resultado fuera del repositorio.

```powershell
./demo/measure.ps1 -Last 3 -OutFile "$env:TEMP\medicion-sesion.md"
```

**3. Dejar la lista limpia.**

```powershell
./demo/reset.ps1 -All
```

**4. Si no habrá más demos**, borra toda la infraestructura de Azure. Pide confirmación.

```powershell
./infra/destroy.ps1
```

Después, desvincula el entorno del plan de pago por uso de créditos, si lo usaste ([ADR-001](../docs/adr/ADR-001-facturacion-creditos-copilot-studio.md)).
