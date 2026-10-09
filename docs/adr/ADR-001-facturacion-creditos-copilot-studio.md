# ADR-001 — Facturación de Copilot Credits con pago por uso vinculado a Azure

| Campo | Valor |
| --- | --- |
| Estado | Propuesto; **actualizado el 2026-10-09** (ver la sección final): la decisión de pago por uso queda diferida |
| Fecha | 2026-10-08 |
| Decisión relacionada | B-01 en `specs/01-especificacion.md` §8 |
| Historias | HU-08, HU-12 (CA-12.4) |
| Responsables | arquitecto-m365, arquitecto-cloud; revisión: revisor-seguridad |

## Contexto

- El tenant tiene Copilot Studio en **prueba**. Con esa licencia no se puede publicar un agente ([Licensing](https://learn.microsoft.com/microsoft-copilot-studio/billing-licensing#get-access-to-copilot-studio)), y los disparadores de evento solo reaccionan con el agente publicado ([Add an event trigger](https://learn.microsoft.com/microsoft-copilot-studio/authoring-trigger-event#publish-an-agent-with-a-trigger)).
- Una cuenta con licencia de Microsoft 365 Copilot cumple uno de los criterios que habilitan publicar ([FAQ de facturación](https://learn.microsoft.com/microsoft-copilot-studio/faq-billing-licensing)). Daniel publicará con esa cuenta.
- Las ejecuciones autónomas consumen Copilot Credits. La inclusión "sin cargo" para usuarios con Microsoft 365 Copilot aplica cuando el agente opera con la identidad autenticada de ese usuario; los flujos con disparadores distintos de *When an agent calls the flow* consumen créditos a la tarifa estándar ([Billing rates](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)). Learn no dice de forma explícita si un disparador de evento con credenciales del creador queda incluido, así que **suponemos que se cobra**.
- El consumo de la demo es bajo y puntual (spike, ensayos y una sesión de 60 minutos).

## Decisión

Usar **pago por uso de Copilot Studio** con un plan de facturación del Power Platform admin center que vincula **solo** el entorno Sandbox `DSA-Demo` a la suscripción de Azure de la demo.

1. **Plan de facturación.** Power Platform admin center → *Licensing* → *Pay-as-you-go plans* → *New billing plan*, con producto Copilot Studio y el entorno `DSA-Demo` ([Set up pay-as-you-go](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan)). Learn indica que el pago por uso solo admite entornos de Producción y Sandbox ([Throttling errors](https://learn.microsoft.com/troubleshoot/power-platform/copilot-studio/licensing/throttling-errors-agents#solution)), lo que encaja con la decisión de no usar *Trial*.
2. **Grupo de recursos separado.** El recurso *Power Platform account* del plan se crea en un grupo de recursos propio, `rg-dsa-creditos`, distinto del grupo de la infraestructura. Así el presupuesto de USD 20 de Azure (CA-12.2) mide solo la infraestructura, y los créditos tienen su propio presupuesto.
3. **Presupuesto de créditos** (CA-12.4). En Azure Cost Management, con alcance en `rg-dsa-creditos`: **USD 40 al mes**, con alertas al 50 %, 80 % y 100 % ([Create budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)). Los cargos pueden tardar hasta 24 horas en aparecer ([View usage and billing](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-usage-costs)).
4. **Freno real.** Un presupuesto avisa pero **no detiene** el consumo ([Manage pay-as-you-go costs](https://learn.microsoft.com/power-platform/admin/manage-usage-github-copilot-harness#manage-pay-as-you-go-costs)). Por eso se fija además un **límite mensual de créditos por agente** en *Licensing* → *Copilot Studio* → *Manage Agents* ([Billing rates — enforcement](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#overage-enforcement)): **886 créditos** para el agente del spike (peor caso de 770 + 15 %: el límite está para frenar un error, no para dejarlo correr) y **3 000** para el agente de la demo.
5. **Desvincular al terminar.** Después del evento, el entorno se desvincula del plan; desde ese momento no se factura ([Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/billing-licensing#get-access-to-copilot-studio)).

## Estimación de consumo

Tarifas oficiales: acción del agente (incluye disparadores) 5 créditos, respuesta generativa 2, acciones de flujo 13 por cada 100 ([Billing rates](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)).

| Unidad | Composición | Créditos |
| --- | --- | --- |
| Evento del spike | disparador 5 + herramienta 5 + ~4 acciones de flujo 0,5 | ≈ 11 |
| Incidente de la demo | disparador 5 + respuesta con conocimiento 2 + herramienta `PublicarIncidente` 5 + ~15 acciones de flujo 2 | ≈ 14, se redondea a **15** |

| Fase | Supuesto | Créditos |
| --- | --- | --- |
| SPK-01 | Secuencia A → B, C solo si ambas fallan; corte p90 al tercer evento lento. Esperado entre 33 y 50 eventos; peor caso teórico 70 | 363–550 (peor caso 770) |
| Desarrollo e integración | 40 incidentes | 600 |
| Pruebas del agente (CA-08.5) | 5 casos × 3 corridas | 225 |
| Ensayos (OBJ-1, OBJ-2) | 20 incidentes | 300 |
| Preflight | 20 ejecuciones con incidente de prueba | 300 |
| Ensayo general y evento | 15 incidentes | 225 |
| **Total** | | **≈ 2 200 (peor caso ≈ 2 420)** |

En dinero: Learn no publica el precio por crédito y la página de precios de Copilot Studio tampoco muestra la cifra por crédito; Daniel la confirma con la calculadora de precios de Azure antes de configurar el presupuesto. Con la referencia habitual de USD 0,01 por crédito, el total es del orden de **USD 22–25**, repartido entre octubre y noviembre. El presupuesto de USD 40 al mes deja margen para repetir ensayos sin pasar del límite del agente. Si el precio confirmado es distinto, se ajustan el presupuesto y los límites en la misma proporción.

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Paquete prepagado de Copilot Credits (suscripción mensual del Microsoft 365 admin center) | Compromiso mensual mayor que el consumo esperado; los créditos no usados no se acumulan ([Licensing](https://learn.microsoft.com/microsoft-copilot-studio/billing-licensing#capacity-enforcement)). |
| Plan de precompra de Copilot Credits (CCCU, un año) | Compromiso de un año para una demo puntual ([Purchase credits](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/billing-manage-buy-credits)). |
| Quedarse en la prueba | No permite publicar; bloquea la demo. |
| Entorno *Trial* | Se elimina con sus agentes a los 30 días y no admite pago por uso. |

La alternativa más barata si el pago por uso no estuviera disponible es el paquete prepagado más pequeño, contratado un solo mes y cancelado después.

## Consecuencias

- **Positivas:** se paga solo lo consumido; el costo queda visible en Azure Cost Management junto a la infraestructura, pero en un grupo de recursos aparte; se puede apagar desvinculando el entorno.
- **Negativas:** el presupuesto solo avisa, con hasta 24 horas de retraso; el freno es el límite por agente, y al alcanzarlo el agente deja de responder en plena demo. Por eso el preflight revisa el consumo del mes frente al límite (CA-14.3).
- **Requisitos:** Daniel necesita permisos de Owner o Contributor en la suscripción y rol de administrador en el Power Platform admin center para crear el plan.
- **Riesgo abierto:** si las ejecuciones con credenciales de un creador con Microsoft 365 Copilot resultaran incluidas sin cargo, el consumo real será menor que la estimación. El spike lo mostrará en el informe de consumo del entorno.

## Actualización 2026-10-09

Hechos verificados en sistema (Microsoft Graph y portal) que cambian el contexto:

- El tenant de la demo es el de la empresa del speaker (especificación §8). Tiene **capacidad de Copilot Studio en prueba** (25 unidades) que vence el **2026-11-07 a las 05:01 UTC**, y Microsoft 365 Business Premium en prueba que vence el mismo día a las 04:50 UTC.
- Con esa capacidad, la cuenta de Daniel **publicó** un agente del standard harness con orquestación generativa. El bloqueante B-01 queda resuelto mientras dure la prueba.
- No se pudo crear el Sandbox `DSA-Demo` por falta de capacidad de base de datos de Dataverse; la demo usa el **entorno predeterminado**, renombrado `DSA-Demo`.
- El tenant de la empresa del speaker **no tiene suscripción de Azure**.

Decisión actualizada:

1. **Hasta el 7 de noviembre** los créditos salen de la capacidad de prueba del tenant. No se configura pago por uso ahora.
2. **Se mantiene el freno real:** límite mensual de créditos por agente (886 para el spike, 3 000 para la demo). El presupuesto de Azure de USD 40 en `rg-dsa-creditos` solo aplica si después se activa el pago por uso.
3. **Pago por uso diferido.** Learn indica que el pago por uso de Copilot Studio admite entornos de Producción y Sandbox; **no está verificado** que el entorno predeterminado se pueda vincular a un plan. Si la sesión cae el 7 de noviembre o hay que extender la demo, las alternativas son: pasar a pago la capacidad de Copilot Studio (paquete de créditos) o crear un Sandbox con pago por uso cuando exista la suscripción de Azure en el tenant. Se decide antes del congelamiento del 28 de octubre (riesgo R-12).
