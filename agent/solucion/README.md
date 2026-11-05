# Solución de Power Platform: camino rápido

Esta carpeta guarda la solución **`DelSensorAlAgente`** exportada de Copilot Studio, lista para importarla en otro entorno. Reemplaza los pasos 7 a 10 del [manual técnico](../../docs/Manual_Tecnico.md#paso-7-crear-el-agente): no hay que crear a mano el agente, sus instrucciones, las herramientas ni los flujos.

El camino manual sigue en el manual y en la [guía de configuración](../GUIA-CONFIGURACION.md) porque explica qué hace cada pieza y por qué. Este es el atajo para quien ya lo entendió y quiere el escenario funcionando.

## Qué incluye

| Componente | Nombre en la solución |
| --- | --- |
| Agente del standard harness, con orquestación generativa e instrucciones | `dsa_AgentedeOperaciones` ("Agente de Operaciones") |
| Conocimiento: la biblioteca de protocolos | Tema `Protocolos` (apunta a `<tu sitio>/Protocolos`) |
| Herramienta y flujo que lee el incidente | `LeerIncidente` |
| Herramienta y flujo que publica la tarjeta y espera la decisión | `PublicarIncidente` |
| Flujo que recibe la llamada de Azure y ejecuta el agente | `DisparoAgente` |
| Variables de entorno | `dsa_SitioDemo` (URL del sitio) y `dsa_TimeoutDecision` (`PT15M`) |
| Referencias de conexión | SharePoint, Microsoft Teams y Microsoft Copilot Studio |

Las referencias de conexión no llevan credenciales: al importar, cada uno elige o crea sus propias conexiones ([Use a connection reference in a solution](https://learn.microsoft.com/power-apps/maker/data-platform/create-connection-reference)).

## Por qué hay marcadores en `src/`

La solución exportada trae datos del tenant donde se creó: la URL del sitio de SharePoint, el equipo y el canal de Teams, y las identidades autorizadas a llamar al disparador. Esos datos no se versionan. En `src/` están reemplazados por estos marcadores, y `pack.ps1` pone los tuyos:

| Marcador | Variable de `.env` | Dónde se usa | Cómo obtener el valor |
| --- | --- | --- | --- |
| `{{DSA_SITE_URL}}` | `DSA_SITE_URL` | Acciones de SharePoint de los flujos y el conocimiento del agente | La URL del sitio que creó `sharepoint/provision.ps1`, sin barra final |
| `{{DSA_TEAM_ID}}` | `DSA_TEAM_ID` | Publicar la tarjeta en Teams | En Teams, canal → **⋯** → *Obtener vínculo al canal*: es el valor de `groupId` |
| `{{DSA_CHANNEL_ID}}` | `DSA_CHANNEL_ID` | Publicar la tarjeta en Teams | En el mismo vínculo, el segmento `19:...@thread.tacv2` (decodificado) |
| `{{DSA_FLOW_ALLOWED_USERS}}` | `DSA_FLOW_ALLOWED_USERS` | Disparador HTTP de `DisparoAgente` (*Specific users in my tenant*) | El ObjectId de la identidad administrada de tu Function. Ver abajo |

El ObjectId de la identidad administrada se obtiene con:

```powershell
az functionapp identity show -g $env:DSA_RESOURCE_GROUP -n <nombre-de-la-function> --query principalId -o tsv
```

Si además quieres llamar al flujo desde tus propios scripts de medición, agrega el ObjectId de tu cuenta, separado por punto y coma. El disparador solo admite a las identidades de esa lista ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication)).

## Paso a paso

**Antes:** completa los pasos 1 a 6 del manual. Necesitas el sitio de SharePoint aprovisionado, la infraestructura de Azure desplegada y un entorno de Power Platform con Copilot Studio.

**1. Arma el paquete.** Completa los cuatro valores en `.env`, cárgalo en la sesión y ejecuta:

```powershell
Get-Content .env | Where-Object { $_ -match '^[A-Z_]+=.+' } | ForEach-Object { $n, $v = $_ -split '=', 2; Set-Item "env:$n" $v }
./agent/solucion/pack.ps1
```

✅ Siga cuando: aparece `Paquete listo: ...agent/solucion/out/DelSensorAlAgente.zip`. Si falta un valor o no tiene el formato esperado, el script lo dice y no crea nada.

**2. Importa la solución.** En Copilot Studio, abre **Soluciones** → **Importar solución** y elige el `.zip` ([Export and import agents using solutions](https://learn.microsoft.com/microsoft-copilot-studio/authoring-solutions-import-export)). Durante la importación:
- **Conexiones:** elige o crea una conexión para SharePoint, Teams y Copilot Studio con la cuenta de servicio del agente.
- **Variables de entorno:** en `dsa_SitioDemo` escribe la URL de tu sitio. Deja `dsa_TimeoutDecision` en `PT15M` ([Environment variables overview](https://learn.microsoft.com/power-apps/maker/data-platform/environmentvariables)).

✅ Siga cuando: la solución aparece en la lista sin errores.

**3. Activa los flujos.** Abre la solución y comprueba que `DisparoAgente`, `LeerIncidente` y `PublicarIncidente` estén **activados**. Si alguno está desactivado, actívalo.

**4. Publica el agente.** Abre "Agente de Operaciones" y pulsa **Publicar** (paso 11 del manual).

**5. Conecta Azure con el flujo.** Abre `DisparoAgente`, copia la URL del disparador HTTP, ponla en `DSA_FLOW_URL` y sigue el paso 12 del manual. Esa URL es distinta en cada entorno, por eso no viene en el paquete.

**6. Prueba de punta a punta.** Sigue el paso 14 del manual: un evento del simulador tiene que terminar en una tarjeta del canal en 30 segundos o menos.

## Para actualizar `src/` después de cambiar el agente

1. Exporta la solución como **no administrada** desde Copilot Studio o con la acción [`ExportSolution`](https://learn.microsoft.com/power-apps/developer/data-platform/webapi/reference/exportsolution) de la API web de Dataverse.
2. Descomprímela fuera del repositorio.
3. Reemplaza tus valores por los marcadores de la tabla y borra `environmentvariabledefinitions/*/environmentvariablevalues.json`.
4. Copia el resultado a `src/` y ejecuta las pruebas:

```powershell
Invoke-Pester agent/solucion/tests
```

Las pruebas fallan si queda una URL de SharePoint, un correo, un identificador de canal o un valor actual de variable de entorno.

## Límites conocidos

- La solución se probó volviéndola a armar con los valores del entorno original: el paquete quedó idéntico byte a byte a la exportación. La importación en un tenant nuevo se valida con la prueba del tercero (CA-13.3).
- Una solución importada no recibe los componentes que se agreguen después en el entorno de origen: hay que volver a exportar ([Agents missing components in a solution](https://learn.microsoft.com/troubleshoot/power-platform/copilot-studio/lifecycle-management/agents-solution-mapping)).
- El agente usa idioma principal `en-US` con instrucciones de responder en español (ADR-003): no lo cambies al importar.
