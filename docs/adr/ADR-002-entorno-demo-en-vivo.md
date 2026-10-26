# ADR-002 — Desviación para la demo en vivo: tenant de la empresa y entorno predeterminado

| Campo | Valor |
| --- | --- |
| Estado | Aceptado por Daniel (2026-10-09) |
| Fecha | 2026-10-09 |
| Alcance | **Solo la demo en vivo de la sesión.** La configuración recomendada para reproducir la solución no cambia (especificación §8.1, ADR-001) |
| Decisiones relacionadas | DEC-06 (ADR-001), DEC-07 |
| Responsables | arquitecto-m365; revisión: revisor-seguridad |

## Contexto

La especificación recomienda montar la solución en un **tenant de pruebas**, con un **entorno Sandbox dedicado** (`DSA-Demo`), un grupo de seguridad, una política DLP, auditoría, pago por uso de Copilot Credits y una cuenta de servicio con licencia para publicar (§8.1).

Para la demo en vivo, Daniel no dispone de esos recursos. Lo verificado en sistema el 2026-10-09:

- El único tenant con administración global y licencias útiles es el de la **empresa del speaker**.
- No se pudo crear el Sandbox: el tenant no tiene el **1 GB de capacidad de base de datos de Dataverse** disponible que exige la creación de entornos ([Create environment](https://learn.microsoft.com/power-platform/admin/create-environment#create-an-environment-with-a-database)).
- El tenant tiene **capacidad de Copilot Studio en prueba** (vence 2026-11-07 05:01 UTC) y Microsoft 365 Business Premium en prueba (vence 2026-11-07 04:50 UTC). Con eso, la cuenta de Daniel **publicó** un agente del standard harness con orquestación generativa en el entorno predeterminado.
- El tenant no tenía suscripción de Azure. **Actualización 2026-10-26:** Daniel creó la suscripción de la demo en el mismo tenant (pago por uso, sin límite de gasto) con un grupo de recursos propio; su cuenta es Owner.

## Decisión

Para la demo en vivo se usa el **tenant de la empresa del speaker** y su **entorno predeterminado**, renombrado `DSA-Demo`. La marca de esa empresa puede verse en pantalla y en los videos; no hay mensaje comercial.

## Diferencias con la configuración recomendada y mitigaciones

| Recomendado (§8.1) | Demo en vivo | Riesgo | Mitigación |
| --- | --- | --- | --- |
| Tenant de pruebas dedicado | Tenant de la empresa del speaker (producción) | Exposición de datos o configuración de la empresa | Ningún identificador del tenant en el repositorio (CA-13.5); agente compartido solo con las cuentas de la demo; `Sites.Selected` solo sobre el sitio de la demo |
| Sandbox dedicado con grupo de seguridad | Entorno predeterminado, sin grupo de seguridad: Learn no lo permite en ese tipo de entorno ([Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)) | Cualquier usuario del tenant puede crear en el entorno | Cuenta de servicio dedicada para el agente (Art. 4); revisar antes del evento qué otros recursos hay en el entorno |
| Política DLP para el entorno de la demo | Sin DLP propia | Aplicarla afectaría a todos los creadores de la empresa | Se documenta en `docs/gobernanza.md` como práctica obligatoria de producción ([Secure the default environment](https://learn.microsoft.com/power-platform/guidance/adoption/secure-default-environment)) |
| Auditoría de Dataverse | Activada, retención de 180 días | — | — |
| Cuenta de servicio con licencia de usuario de Copilot Studio | `agente-dsa` con prueba de Copilot Studio | Vence con la capacidad de prueba del tenant (R-12) | Misma mitigación que la capacidad: confirmar la fecha antes del 28 de octubre |
| Pago por uso de créditos (ADR-001) | Capacidad de prueba del tenant | Vence el 7 de noviembre a las 00:01 hora de Colombia (R-12); no está verificado que el entorno predeterminado admita pago por uso | Límite de créditos por agente; antes del 28 de octubre, confirmar la fecha de la sesión y, si hace falta, pasar a pago la capacidad |
| Suscripción de Azure en el mismo tenant | Creada el 2026-10-26, pago por uso **sin límite de gasto** | Un error podría generar costos sin tope | Alerta de presupuesto al 80 % de USD 20 (CA-12.2), un máximo de 1 instancia de la Function y *always ready* solo en ensayos (ADR-005) |

## En la charla

La desviación se presenta tal cual: "esto es lo que recomiendo; esto es lo que usé hoy y por qué". Es material de gobernanza útil para el público: muestra el costo real de no tener un entorno dedicado.

## Consecuencias

- La guía, el README y la especificación describen la configuración recomendada; este ADR es la única referencia a la configuración de la demo en vivo.
- El preflight acepta cualquiera de los dos casos: con un Sandbox dedicado da verde; con el entorno predeterminado da aviso amarillo y remite a este ADR.
- Si después del evento hay capacidad, la demo se migra a un Sandbox dedicado y este ADR pasa a "Reemplazado".
