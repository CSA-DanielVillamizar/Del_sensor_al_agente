# Ensayos de punta a punta (T-052) y tramo 2 (T-039)

HU-14, HU-08 · OBJ-1, OBJ-2, CA-05.5, CA-08.6

## Primera serie: 2026-10-26, 17:46–17:59 COT

- **Vía:** la real de la demo. `python -m simulator` con el dispositivo `sim-01` → IoT Hub → Function → lista → `DisparoAgente` → agente → `PublicarIncidente` → tarjeta en `Centro de operaciones`.
- **Configuración:** Function con una instancia *always ready* (escenario `ensayo`), agente con las instrucciones publicadas a las 17:37 COT y búsqueda web desactivada.
- **Eventos:** 10, de los tres tipos y de cinco zonas, con 70 s entre uno y otro para que cada uno abra su propia ventana de deduplicación (ADR-006).
- **Medición:** `demo/measure.ps1 -Last 10`. Une cada elemento de la lista con el primer mensaje del canal que lleva su `Ref. {eventId}`.

| Tramo | p50 | p90 | Máximo | Meta | Resultado |
| --- | --- | --- | --- | --- | --- |
| Tramo 1 (aproximado; el oficial es la KQL) | 1,0 s | 1,0 s | 4,0 s | p90 ≤ 10 s | Cumple |
| Tramo 2 (elemento creado → tarjeta visible) | 18,7 s | 20,7 s | 35,1 s | p90 ≤ 20 s | **No cumple, por 0,7 s** |
| Total (evento recibido → tarjeta visible) | 20,4 s | 22,6 s | 36,1 s | p90 ≤ 30 s y ningún ensayo > 60 s | Cumple |

Exitosos: **10 de 10**. Los 10 incidentes tienen tarjeta y ninguno quedó pendiente.

### Lectura

- El total cumple OBJ-2 con margen: el p90 está 7,4 s por debajo de la meta.
- El tramo 2 se pasa por poco del presupuesto que le asigna el plan (R-18): lo dominan el agente (lectura, búsqueda del protocolo y redacción) y la publicación de la tarjeta.
- Las instrucciones crecieron unos 300 caracteres en la corrección de los casos (T-041). Puede haber influido, pero con 10 muestras no se puede afirmar.

### Opciones para R-18 (decisión de Daniel)

1. **Aceptar** el tramo 2 tal como está, porque el total, que es lo que ve el público, cumple con margen.
2. **Plan B del plan (§10):** una sola herramienta que lea el incidente y devuelva también el protocolo, para evitar una vuelta del orquestador.
3. **Instrucciones más cortas:** quitar del bloque lo que repiten las descripciones de las herramientas.

## Pendiente de T-052

- El runbook completo dos veces (después de T-050).
- Una segunda serie de 10 ensayos después de cualquier cambio por R-18.
