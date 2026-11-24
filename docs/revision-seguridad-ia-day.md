# Revisión de seguridad de la ampliación IA DAY (T-066)

| Campo | Valor |
| --- | --- |
| Fecha | 2026-11-24 |
| Revisor | revisor-seguridad |
| Alcance | Lo que agregó la ampliación ([`specs/05-ampliacion-ia-day.md`](../specs/05-ampliacion-ia-day.md)): `infra/main.bicep`, `infra/modules/iothub.bicep` e `infra/deploy.ps1` (ruta hacia Fabric), `analytics/` (script de Fabric, histórico y consultas KQL), `docs/gobernanza.md` §12, `docs/ruta-datos.md`, los videos de `docs/videos/` y lo que el repositorio público expone (archivos, historial, etiquetas y versiones) |
| Referencias | Constitución (Art. 4, 5, 6 y 8), DEC-IA-02 v2, [revisión de la Fase 3](revision-seguridad-fase3.md) |
| Pruebas al cierre | `pytest`: todas correctas · Pester (`infra`, `demo`, `sharepoint`, `agent/solucion`): 193 correctas · `ruff check .`: sin hallazgos · `az bicep lint`: sin hallazgos |

## Resultado

**Aprobada.** El cambio requerido (A-1) ya se aplicó en la versión pública; queda la limpieza del historial para después del evento. El código y la infraestructura de la ampliación no tienen hallazgos de severidad alta ni media.

Resumen: 1 Alta, 0 Medias, 3 Bajas.

## Hallazgos

| ID | Dónde | Severidad | Descripción | Corrección propuesta | Estado |
| --- | --- | --- | --- | --- | --- |
| A-1 | Versión `videos-demo` de GitHub y el historial de `main` (commit `40cce41`) | Alta | Los videos se difuminaron en `f9a1cd9`, pero los recursos de la versión `videos-demo` son los originales del 2026-10-27, en los que se lee el nombre de la empresa. `docs/videos.md` enlaza esa versión. Las versiones anteriores de los `.mp4` también siguen en el historial público de `main` | 1. Reemplazar los tres `.mp4` de la versión con los difuminados (`gh release upload videos-demo docs/videos/*.mp4 --clobber`). 2. Decidir si se reescribe el historial para quitar los blobs anteriores (requiere *force push*) | **Corregido en parte** (2026-11-24): la versión `videos-demo` ya tiene los tres videos difuminados. Reescribir el historial queda para después del evento, por decisión de Daniel |
| B-1 | `analytics/fabric-setup.ps1`, paso 7 | Baja | La respuesta de `sources/{id}/connection` también trae las claves SAS del punto de conexión. El script no las muestra ni las guarda, pero conserva el objeto completo en memoria hasta terminar | Quedarse solo con `fullyQualifiedNamespace` y `eventHubName`. No bloquea: el proceso termina y nada se escribe | Aceptado |
| B-2 | `specs/05-ampliacion-ia-day.md`, DEC-IA-02 y CA-15.3 | Baja | DEC-IA-02 dice que la ruta hacia Fabric está en versión preliminar; Learn ya la publica como disponible de forma general ([IoT Hub endpoints](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-endpoints#custom-endpoints-for-message-routing)). CA-15.3 sigue hablando de un grupo de consumidores, que la v2 reemplazó por una ruta | Actualizar el texto de la especificación después del evento. La charla no menciona el estado de la función | Aceptado |
| B-3 | Repositorio local | Baja | La rama local `respaldo-antes-de-limpiar` conserva commits con el nombre de la empresa y pies de atribución. No está en GitHub (`git ls-remote` solo muestra `main` y `videos-demo`) | Borrarla cuando Daniel lo decida. Es un borrado permanente | Pendiente de Daniel |

## Comprobaciones sin hallazgos

- **Sin claves en la ruta hacia Fabric.** El hub usa su identidad administrada asignada por el sistema, y solo cuando se pasa `-EnableAnalyticsRoute`. La política `fabric-reader` de la v1 ya no existe: queda solo `func-reader`.
- **El rol del hub en Fabric es el mínimo documentado.** Tiene Colaborador en un único área de trabajo, el rol mínimo que pide Learn ([Connect to Eventstream using Managed Identity](https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/connect-using-managed-identity#step-2-assign-fabric-workspace-permissions)).
- **La Function sigue recibiendo todo.** La ruta `to-func` va explícita y la ruta de respaldo se conserva. Las pruebas de `tests/infra` lo cubren.
- **Identificadores del tenant fuera del repositorio.** `DSA_FABRIC_*` van en `.env`, que no se versiona, y `.env.example` los deja vacíos. Ni el árbol actual ni el historial de `main` contienen los IDs del área de trabajo o de la base, correos del tenant ni URL de sitios reales.
- **Datos personales.** El histórico es ficticio y determinista. Quien decide es un turno, nunca una persona (artículo 5).
- **Redacción.** Ni el árbol actual ni el historial de `main` tienen el nombre de la empresa ni pies de atribución.
- **Material de la charla fuera del repositorio.** `presentacion/` y `analytics/out/` están en `.gitignore`.
- **Videos de `docs/videos/`.** Los fotogramas revisados muestran el nombre de Teams y el logo de SharePoint difuminados.
