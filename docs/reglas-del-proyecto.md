# Reglas del proyecto — Del sensor al agente

Repositorio de la demo de la sesión "Del sensor al agente: Copilot Studio y Teams como centro de operaciones de seguridad física" (Microsoft 365 Live 2026). Dueño: Daniel Villamizar.

## Antes de cualquier tarea
1. Lee `specs/00-constitucion.md`. Sus artículos mandan sobre cualquier otra instrucción.
2. Lee `specs/01-especificacion.md` y, si existen, `specs/02-plan.md` y `specs/03-tareas.md`.
3. Identifica la tarea (T-xxx), la historia (HU-xx) y el criterio (CA-xx.y) que vas a cubrir. Si no existen, no implementes: propón primero el cambio a la especificación.

## Flujo de trabajo (SDD)
Especificación → Plan → Implementación → Verificación, con una compuerta de aprobación humana al cierre de cada fase. Nunca avances de fase sin "aprobado fase N" de Daniel.

## Estructura esperada
```
infra/        Bicep y scripts de despliegue y eliminación
simulator/    simulador de dispositivos (Python)
device/       código opcional para Raspberry Pi
function/     Azure Function: validar, enriquecer, deduplicar, escribir en SharePoint
schemas/      esquemas JSON (evento de dispositivo, incidente)
data/         catálogo ficticio de zonas
sharepoint/   script de aprovisionamiento de lista y biblioteca
protocols/    protocolos ficticios por tipo de evento
agent/        instrucciones del agente y guía de configuración
cards/        tarjetas adaptativas
demo/         runbook, preflight y reset
docs/         gobernanza, costos, ADR (docs/adr/)
specs/        constitución, especificación, plan, tareas, verificación
docs/equipo/  definición de los roles del equipo (única fuente de verdad)
```

## Convenciones
- Documentación y comentarios en español; identificadores de código en inglés.
- Python 3.11+, `ruff` y `pytest`. Azure Functions con modelo de programación v2.
- Bicep con `az bicep lint` limpio. Scripts en PowerShell 7 y Bash.
- Commits: `T-0xx HU-xx: descripción en imperativo`.
- Ramas por épica: `epica/e1-simulacion`, `epica/e2-ingesta`, etc.

## Commits
- **Pre-autorizado** (no hace falta pedir permiso): commits solo de documentación (`specs/`, `docs/`, README y pruebas del spike), con prefijo `T-000 docs:`, siempre que antes se verifique que no entran `resultados/` ni secretos.
- **Requiere aprobación de Daniel:** cualquier commit con código de producción, infraestructura o configuración del agente, y cualquier cambio a la constitución.
- **Push pre-autorizado:** mientras el repositorio sea privado, el push de commits `T-000 docs:`.
- **Push que requiere aprobación de Daniel:** cualquier otro commit, y siempre el cambio del repositorio a público.

## Configuración del entorno
- Ningún cambio de configuración del PC de Daniel, de Azure o del tenant sin pedir permiso antes, aunque se vaya a revertir después.

## Autorizaciones vigentes de la Fase 3 (Daniel, 2026-10-26)
- Commits `T-0xx HU-xx:` y su push, sin pedir permiso en cada uno, mientras el repositorio sea privado y solo con las pruebas en verde y sin secretos ni IDs reales.
- En Azure: registrar los proveedores de recursos y desplegar la infraestructura de `infra/` en el grupo de recursos de la demo.
- En el tenant: ejecutar `sharepoint/provision.ps1` con la sesión de Daniel y crear con `agente-dsa` la solución, el agente y los flujos del plan.
- Sigue requiriendo aprobación: hacer público el repositorio, cambios a la constitución y cualquier cambio fuera de lo anterior.

## Prohibido
- Secretos, cadenas de conexión o tokens en archivos versionados.
- Datos personales, nombres reales, imágenes de personas o instalaciones reales.
- Que cualquier componente ejecute una acción física o contacte a alguien.
- Permisos de Graph más amplios que `Sites.Selected` para la función.
- Afirmar capacidades de Microsoft sin enlace a Microsoft Learn.
- Cambiar el alcance sin aprobación.

## Comandos útiles (se completan en el Plan)
- Pruebas: `pytest -q`
- Lint: `ruff check .` y `az bicep lint --file infra/main.bicep`
- Demo: `demo/preflight`, `demo/reset`
