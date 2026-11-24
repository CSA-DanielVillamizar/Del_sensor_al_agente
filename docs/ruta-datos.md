# Ruta "solo datos" (20 minutos, sin licencias)

T-064 · HU-17 · CA-17.4. Esta guía es para quien asistió a la charla "Un agente vale lo que valen sus datos" y quiere repetir la parte de datos en su propio equipo. No hace falta Azure, Microsoft 365, Copilot Studio ni Fabric. Solo se necesitan Python 3.11 o superior y, para el paso 4, una cuenta Microsoft.

| Paso | Qué se ve | Tiempo |
| --- | --- | --- |
| 1. Preparar el entorno | — | 5 min |
| 2. El contrato del dato | Los eventos mal formados se rechazan antes de llegar a la IA | 3 min |
| 3. El histórico ficticio | 30 días de incidentes reproducibles, con una anomalía escondida | 2 min |
| 4. Las consultas KQL | Reducción, anomalía de Z-05 y la decisión humana como dato | 10 min |

## 1. Preparar el entorno

```powershell
git clone https://github.com/CSA-DanielVillamizar/Del_sensor_al_agente.git
cd Del_sensor_al_agente
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.txt
```

En Linux o macOS, activa el entorno con `source .venv/bin/activate`.

## 2. El contrato del dato

```powershell
python -m pytest -q tests/function/test_validation.py
```

Resultado esperado: `10 passed`. Las pruebas mandan a la validación de la Function eventos que no deberían pasar:
- un cuerpo que ni siquiera es JSON;
- una zona que no cumple el formato;
- un campo de más con el nombre de una persona;
- un identificador inválido.

Todos se rechazan contra el esquema [`schemas/evento-dispositivo.schema.json`](../schemas/evento-dispositivo.schema.json), y el motivo del rechazo nunca repite el valor recibido.

**Para explorar:** abre el esquema y prueba a quitar `"additionalProperties": false`. Vuelve a correr las pruebas y mira cuál falla, y por qué eso abre la puerta a datos personales.

## 3. El histórico ficticio

```powershell
python -m analytics.history --days 30 --end 2026-11-26 --out analytics/out/historico.csv
```

El script genera 196 incidentes ficticios, que suman 682 eventos crudos, con las mismas reglas del pipeline:
- las zonas de [`data/zonas.json`](../data/zonas.json);
- la severidad inicial;
- la subida de un nivel fuera del horario diurno;
- un turno ficticio que decide, nunca una persona.

Es determinista: la misma semilla y la misma fecha producen el mismo archivo. Y trae una anomalía escondida a propósito: en los últimos 5 días se disparan los incidentes en el Archivo documental (Z-05).

## 4. Las consultas KQL en un clúster gratuito

Azure Data Explorer ofrece un clúster gratuito que solo pide una cuenta Microsoft o de Microsoft Entra, sin suscripción de Azure ni tarjeta de crédito ([Learn](https://learn.microsoft.com/azure/data-explorer/start-for-free)).

1. **Crea el clúster.** Entra a [My Cluster](https://aka.ms/kustofree), selecciona **Create cluster** y ponle a la base el nombre `dsa` ([Learn](https://learn.microsoft.com/azure/data-explorer/start-for-free-web-ui)).

2. **Crea la tabla.** En **Query**, sobre la base `dsa`, ejecuta:
   ```kusto
   .create-merge table Historico (eventId:string, fechaUtc:datetime, horaLocal:string, zona:string,
       nombreZona:string, sitio:string, tipoEvento:string, severidadInicial:string, severidadPropuesta:string,
       fueraDeHorario:bool, repeticiones:int, decision:string, decididoPor:string, minutosHastaDecision:int,
       estado:string)
   ```

3. **Carga el CSV.** Haz clic derecho en la base y elige **Get data** → **Local file**. Selecciona la tabla existente `Historico` y sube `analytics/out/historico.csv`, con formato CSV y la primera fila como encabezado ([Learn](https://learn.microsoft.com/azure/data-explorer/get-data-file)).

4. **Ejecuta las consultas** de [`analytics/kql/`](../analytics/kql/), una por una:

| Consulta | Pregunta | Qué deberías ver |
| --- | --- | --- |
| `02-reduccion-antes-del-agente.kql` | ¿Cuánto ruido quita el pipeline antes de la IA? | Muchos más eventos crudos que incidentes que llegan al agente |
| `03-anomalias-por-zona.kql` | ¿Hay una zona que se salga de lo normal? | Z-05 con puntajes altos en los últimos días, gracias a `series_decompose_anomalies()` ([Learn](https://learn.microsoft.com/kusto/query/series-decompose-anomalies-function)) |
| `04-la-decision-como-dato.kql` | ¿Qué decidieron las personas y cuánto tardaron? | Propuestas, escaladas, atendidas, falsas alarmas y propuestas sin respuesta por severidad |

La consulta `01-rafaga-crudos-vs-incidentes.kql` necesita los eventos en vivo del IoT Hub, así que no aplica en esta ruta. En la charla se mostró en vivo, con un video de respaldo.

## 5. Al terminar

- **Para borrar la base:** en el clúster gratuito, entra a **My cluster** y, en **Databases**, usa el ícono de papelera ([Learn](https://learn.microsoft.com/azure/data-explorer/create-cluster-and-database#clean-up-resources)).
- **Para seguir con la solución completa** (IoT Hub, Function, SharePoint, agente y Teams), el punto de partida es el [README](../README.md).

Todos los datos de esta ruta son ficticios: no hay personas, instalaciones ni eventos reales.
