# SPK-01 — Latencia del disparador del agente (P1)

> Código desechable. No es código de producción: no entra en cobertura ni en el despliegue. Se borra (o se archiva aquí como evidencia) al cerrar la decisión DEC-05.

| Campo | Valor |
| --- | --- |
| Pregunta | ¿Qué mecanismo dispara el agente con p90 ≤ 20 s desde que el incidente existe hasta que hay mensaje en Teams? |
| Traza | OBJ-2, RNF-01, CA-08.6 (tramo 2), DEC-05 |
| Time-box | 1 día |
| Regla de decisión | Gana la opción **más simple** que cumpla p90 ≤ 20 s en el tramo 2 sin eventos perdidos. Si ninguna cumple, se escala a Daniel antes de tocar OBJ-2. |
| Orden | **A**, luego **B**. **C** solo se configura y se mide si A y B no cumplen. |
| Muestras | 20 eventos por opción, uno cada 45 s |
| Corte p90 (agresivo) | En cuanto **3 eventos** superan 20 s en el tramo 2 (o llevan más de 20 s sin reacción), la opción se detiene: con 20 muestras el p90 ≤ 20 s ya es imposible. Queda como "No (corte p90)". |
| Corte de protección | Si ninguno de los primeros 5 eventos completa el tramo 2 en ≤ 60 s, la opción se detiene y queda como "No (corte 60s)". |
| Quién ejecuta | Daniel, en su tenant |

## Qué se mide

Se mide el **tramo 2**, que es donde está la incertidumbre: incidente creado → agente reacciona → mensaje publicado en Teams.

| Marca | Dónde se toma | Reloj |
| --- | --- | --- |
| `T0` | Hora de creación que devuelve el servidor: `createdDateTime` de Graph (A), `createdon` de Dataverse (B), hora del cliente al recibir el 202 del HTTP (C) | Servidor (A, B) / cliente sincronizado (C) |
| `T1` | Primera acción del flujo de la herramienta del agente: `utcNow()` | Servidor |
| `T2` | Justo después de publicar el mensaje en el canal de Teams: `utcNow()` | Servidor |

Métricas por opción: p50, p90 y máximo de `T1−T0` (reacción del disparador) y de `T2−T0` (tramo 2 completo). Percentil por rango más cercano. Un evento sin `T2` a los 10 minutos cuenta como fallo; no se descarta.

## Opciones

| Opción | Disparador del agente | Quién crea el evento en el spike | Requisito de licencia |
| --- | --- | --- | --- |
| A | SharePoint: *When an item is created* sobre la lista `SpikeEventosA` | Script con Graph (identidad delegada de Daniel) | Ninguno adicional |
| B | Dataverse: *When a row is added, modified or deleted* (Change type = Added) sobre la tabla `Spike Evento` | Script con la Web API de Dataverse (delegada) | Dataverse en el entorno. En producción la Function escribiría como *application user* (sin costo de licencia, con límites de solicitudes; [S2S](https://learn.microsoft.com/power-apps/developer/data-platform/build-web-applications-server-server-s2s-authentication)) |
| C | Sin disparador de evento: flujo con *When an HTTP request is received* → **Execute Agent** | Script con `POST` a la URL del flujo | HTTP es premium y no hay Power Automate premium; se intenta como **flujo del agente** en Copilot Studio, que puede usar conectores premium con facturación por créditos ([FAQ de flujos del agente](https://learn.microsoft.com/microsoft-copilot-studio/flows-faqs)). Si el disparador HTTP no está disponible ahí, C queda como "no viable con las licencias actuales". |

Learn define qué es un disparador *polling* y qué es uno *webhook* ([Optimize triggers](https://learn.microsoft.com/power-automate/guidance/coding-guidelines/optimize-power-automate-triggers)), pero **no** clasifica el disparador de Dataverse ni documenta cada cuánto revisa la lista el disparador de SharePoint en agentes de Copilot Studio. Por eso medimos.

## Prerrequisitos en tu PC

Todos los scripts del proyecto requieren **PowerShell 7** (`pwsh`), no Windows PowerShell 5.1.

1. Instalar PowerShell 7 (desde cualquier terminal) y abrir después una terminal nueva de **PowerShell 7**:

   ```powershell
   winget install --id Microsoft.PowerShell --source winget
   ```

2. Comprobar la versión; debe ser 7 o superior:

   ```powershell
   $PSVersionTable.PSVersion
   ```

3. Instalar Pester 5. Windows trae Pester 3.4 firmado por otro editor, por eso hacen falta `-Force` y `-SkipPublisherCheck`:

   ```powershell
   Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
   ```

   Versión mínima soportada: **Pester 5.0.0**. Las pruebas se ejecutaron con **Pester 6.2.0 en PowerShell 7.6.6** (17 de 17 correctas, 2026-10-08).

4. Para el spike real, además: módulo `Microsoft.Graph.Sites` (`Install-Module Microsoft.Graph.Sites -Scope CurrentUser`) y la CLI de Azure con sesión iniciada (`az login`).

## Antes de gastar créditos: probar la lógica de corte

La lógica de corte y el cálculo del resumen viven en `SpikeLogic.psm1`. El modo real y el modo `-DryRun` ejecutan **el mismo bucle**; solo cambian el reloj (virtual en `-DryRun`) y de dónde salen los tiempos. Las pruebas usan tiempos sintéticos: no se conectan a nada y no consumen créditos.

En PowerShell 7, desde `spikes/p1-latencia`. La primera línea obliga a cargar Pester 5 y no la 3.4 que trae Windows:

```powershell
Import-Module Pester -MinimumVersion 5.0.0 -Force
Invoke-Pester ./tests -Output Detailed
```

Deben pasar todas. Casos cubiertos: 20 eventos rápidos (sin corte); tercer evento lento en la posición 7 (corte p90 en el evento 7); 5 primeros > 60 s (corte 60s en el evento 5, con el corte p90 neutralizado, y corte p90 en el evento 3 con los parámetros por defecto); eventos sin reacción que cuentan como lentos; p50, p90 y máximo sobre un conjunto conocido; y el modo `-DryRun` del script.

Prueba manual de un escenario cualquiera (`$null` = sin reacción):

```powershell
./Invoke-LatencySpike.ps1 -Option A -DryRun -SyntheticLatency 5,30,5,30,5,5,30,5,5,5,5,5,5,5,5,5,5,5,5,5
```

> Con 20 muestras, el corte p90 siempre actúa antes que el de 60 s: si los primeros eventos no reaccionan, el tercero ya alcanza para cortar. El corte de 60 s queda como protección por si se cambian `-Count` o `-TargetSeconds`.

## Pasos en el portal y en la terminal (en orden)

### Bloque 1 — Licencia y facturación (antes de gastar un solo crédito)

1. **Entorno.** En el Power Platform admin center, crea el entorno `DSA-Demo` de tipo **Sandbox**, con Dataverse, en la región de Estados Unidos.
2. **Publicación.** Entra a Copilot Studio en `DSA-Demo` con tu cuenta que tiene **Microsoft 365 Copilot**, crea un agente vacío del standard harness ("Other ways to build") y publícalo. Si publica, B-01 está resuelto. Si aparece un error de licencia o de facturación, sigue al paso 3 y vuelve a intentar; si persiste, detente y avísame.
3. **Pago por uso** ([ADR-001](../../docs/adr/ADR-001-facturacion-creditos-copilot-studio.md)):
   1. En Azure, crea el grupo de recursos `rg-dsa-creditos` en la suscripción de la demo.
   2. En el Power Platform admin center → *Licensing* → *Pay-as-you-go plans* → *New billing plan*: suscripción de la demo, grupo `rg-dsa-creditos`, producto Copilot Studio y entorno `DSA-Demo` ([Set up pay-as-you-go](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan)).
4. **Presupuesto de créditos.** En Azure Cost Management, presupuesto mensual de **USD 40** con alcance en `rg-dsa-creditos` y alertas al 50 %, 80 % y 100 % ([Create budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)). Antes, confirma el precio por crédito en la página de precios de Copilot Studio.
5. **Requisitos del entorno.** Verifica que *solution-aware cloud flow sharing* está activo en `DSA-Demo` y que ninguna política DLP bloquea el conector Microsoft Copilot Studio ([Event trigger overview](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#troubleshooting-and-limitations)).

### Bloque 2 — Preparar las opciones A y B (~40 min)

6. **Listas** en el sitio de la demo: `SpikeEventosA` (columnas `Title`, `EventId` texto) y la lista sumidero `SpikeLatencia` (`EventId`, `Opcion`, `T1Utc`, `T2Utc`, todas texto).
7. **Tabla de Dataverse** en `DSA-Demo`: `Spike Evento` con la columna `EventId` (texto). Anota el nombre del conjunto de entidades (por ejemplo `cr123_spikeeventos`).
8. **Canal de Teams** de pruebas (no el de la demo).
9. **Agente** *Spike Latencia* (standard harness, orquestación generativa activada). Instrucciones:
   > Cuando recibas un evento, extrae `EventId` y la opción (A, B o C) y llama de inmediato a la herramienta `RegistrarReaccion`. No hagas nada más.
10. **Herramienta** `RegistrarReaccion` (flujo del agente). Entradas: `EventId`, `Opcion`.
    1. `Compose` `T1 = utcNow()` (primera acción).
    2. Teams: *Post message in a chat or channel* en el canal de pruebas: `Spike @{Opcion} @{EventId}`.
    3. `Compose` `T2 = utcNow()`.
    4. SharePoint: *Create item* en `SpikeLatencia` con `EventId`, `Opcion`, `T1Utc`, `T2Utc` (formato `o`).
    5. *Respond to the agent*.
11. **Disparadores del agente:**
    - A: SharePoint *When an item is created* → `SpikeEventosA`. En las instrucciones de la carga útil: "Opción A, EventId = {EventId}".
    - B: Dataverse *When a row is added, modified or deleted* → `Spike Evento`, Change type *Added*, Scope *Organization*. Carga útil: "Opción B, EventId = {EventId}".
12. **Verificación de representatividad.** Antes de medir, confirma que *Spike Latencia* tiene la misma configuración que tendrá el agente de la demo; si algo no coincide, la medición no sirve para decidir:
    - [ ] Creado en el **standard harness** ("Other ways to build" o experiencia clásica).
    - [ ] **Orquestación generativa** activada.
    - [ ] En el entorno **`DSA-Demo`** (Sandbox), vinculado al plan de pago por uso.
    - [ ] Disparadores autenticados con la misma cuenta que publicará la demo (con Microsoft 365 Copilot).
    - [ ] Herramienta implementada como **flujo del agente** (*When an agent calls the flow* + *Respond to the agent*), igual que `PublicarIncidente`.
13. **Publica** el agente, haz una prueba manual por opción y revisa la página *Activity*.
14. **Límite de créditos del agente.** En el Power Platform admin center → *Licensing* → *Copilot Studio* → *Manage Agents*, fija un límite mensual de **886 créditos** para *Spike Latencia* (peor caso de 770 + 15 %) ([enforcement](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#overage-enforcement)). El límite está para frenar un error, no para dejarlo correr.

### Bloque 3 — Medir A y B (~35 min desatendidos)

PowerShell 7, con el módulo `Microsoft.Graph.Sites` instalado y la CLI de Azure con sesión iniciada (`az login`). Ejecuta `w32tm /resync` antes de empezar.

```powershell
$env:SPK_SITE_ID      = '<siteId de Graph del sitio del spike>'
$env:SPK_DV_URL       = 'https://<org>.crm.dynamics.com'
$env:SPK_DV_ENTITYSET = '<conjunto de entidades de Spike Evento>'

./Invoke-LatencySpike.ps1 -Option A -Count 20
./Invoke-LatencySpike.ps1 -Option B -Count 20
```

Espera 10 minutos después del último evento y ejecuta:

```powershell
./Measure-LatencySpike.ps1
```

Si A o B dice "Sí", **terminaste**: pega `resultados/resumen.md` en el chat. C no se configura.

### Bloque 4 — Solo si A y B no cumplen: opción C (~20 min)

15. Crea un flujo del agente con *When an HTTP request is received* (esquema `{"eventId":"string"}`) → *Execute Agent* (agente *Spike Latencia*, mensaje "Opción C, EventId = …") → *Response* 202. Si el disparador HTTP no aparece en los flujos del agente, anota "C no viable" y pega el resumen de A y B.
16. Guarda la URL **solo** en una variable de la sesión y mide:

```powershell
$env:SPK_HTTP_URL = '<URL del disparador HTTP>'
./Invoke-LatencySpike.ps1 -Option C -Count 20
./Measure-LatencySpike.ps1
```

### Bloque 5 — Limpieza

17. **Conserva los componentes de la opción ganadora** hasta que el Plan decida si se reutilizan: su origen (la lista `SpikeEventosA` para A, la tabla `Spike Evento` para B o el flujo HTTP para C) y su disparador, que puedes desactivar.
18. **Borra solo** lo de las opciones que pierdan y el agente *Spike Latencia* (con su herramienta `RegistrarReaccion`). La lista `SpikeLatencia` se conserva hasta que DEC-05 quede registrada en el ADR, porque es la evidencia.
19. Cierra la sesión de PowerShell para descartar las variables. **No** desvincules el plan de pago por uso: lo usa la demo.

## Costo estimado

Por evento: disparador o acción del agente (5 créditos) + llamada a la herramienta (5) + ~4 acciones de flujo (0,5) ≈ **11 Copilot Credits** ([tarifas](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)).

| Escenario | Eventos (incluye ~10 pruebas manuales) | Créditos |
| --- | --- | --- |
| A falla rápido (corte p90 al tercer evento lento) y B cumple | 3 + 20 + 10 = 33 | ≈ 363 |
| A y B fallan rápido y se mide C | 3 + 3 + 20 + 10 = 36 | ≈ 396 |
| A y B cumplen (ambas completas) | 20 + 20 + 10 = 50 | ≈ 550 |
| Peor caso teórico: A y B fallan recién en el último evento y se mide C | 20 + 20 + 20 + 10 = 70 | ≈ 770 |

El corte p90 no cambia el peor caso teórico (una opción puede fallar recién en la muestra 20), pero lo vuelve improbable: un disparador por *polling* suele delatarse en los primeros eventos. Límite del agente: 770 × 1,15 ≈ **886 créditos**.
