"""Genera la definición del flujo del agente `PublicarIncidente` (ADR-008, T-037 y T-038).

La definición sale de las tarjetas versionadas en `cards/` y de parámetros del entorno (sitio, equipo,
canal, referencias de conexión). Ningún identificador del tenant se versiona: se pasan al ejecutar.

Uso:
    python -m agent.flows.build_publicar_incidente --site-url https://<tenant>.sharepoint.com/sites/<sitio> \\
        --team-id <groupId> --channel-id <channelId> --sharepoint-reference <logicalName> \\
        --teams-reference <logicalName> --out <archivo fuera del repositorio>

El resultado es el `clientdata` del flujo (propiedades `connectionReferences` y `definition`), listo para
crear el flujo con la API de Dataverse o para comparar con lo que se configuró en el diseñador.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CARDS = ROOT / "cards"
LIST_TITLE = "Eventos de seguridad"
TIME_ZONE = "SA Pacific Standard Time"

# Entradas de la herramienta, en el orden en que el agente las ve (plan §4.6).
INPUTS = [
    ("text", "eventId", "Identificador UUID del incidente."),
    (
        "text_1",
        "severidadPropuesta",
        "Severidad propuesta: Baja, Media, Alta o Crítica (a lo sumo un nivel de diferencia).",
    ),
    ("text_2", "justificacionSeveridad", "Razón del cambio de severidad; vacía si no cambia."),
    ("text_3", "resumen", "Resumen de máximo 3 líneas para el supervisor."),
    ("text_4", "pasosProtocolo", "Máximo 3 pasos numerados del protocolo."),
    ("text_5", "protocoloAplicado", "Nombre del documento del protocolo usado."),
]

ITEM = "first(body('LeerElemento')?['value'])"
WAIT = "Publicar_tarjeta_y_esperar"


def _lit(text: str) -> str:
    """Literal de cadena del lenguaje de expresiones (comillas simples duplicadas)."""
    return "'" + text.replace("'", "''") + "'"


def _trigger(key: str) -> str:
    return f"coalesce(triggerBody()?['{key}'], '')"


def _str(expr: str) -> str:
    return f"string(coalesce({expr}, ''))"


def _esc(expr: str) -> str:
    """Valor escapado como contenido de una cadena JSON (sin las comillas)."""
    wrapped = f"string(createArray({_str(expr)}))"
    return f"substring({wrapped}, 2, sub(length({wrapped}), 4))"


def _trunc(expr: str, size: int) -> str:
    return f"substring({_str(expr)}, 0, min(length({_str(expr)}), {size}))"


def _card(name: str) -> dict[str, Any]:
    return json.loads((CARDS / name).read_text(encoding="utf-8"))


def _markers(name: str) -> list[str]:
    return sorted(set(re.findall(r"\{\{(\w+)\}\}", (CARDS / name).read_text(encoding="utf-8"))))


def _card_steps(
    target: str, cards: list[str], values: dict[str, str], after: dict, high_expr: str | None = None
) -> dict[str, Any]:
    """Acciones que arman una tarjeta: plantilla, valores escapados y reemplazo de marcadores.

    Cada expresión del lenguaje de flujos admite como máximo 8192 caracteres; por eso la plantilla va como
    objeto en su propio Compose y cada valor se escapa en una propiedad aparte.
    """
    ok = ["Succeeded"]
    steps: dict[str, Any] = {}
    previous = after
    names = []
    for card in cards:
        name = "Plantilla_" + Path(card).stem.replace("-", "_")
        steps[name] = {"type": "Compose", "inputs": _card(card), "runAfter": previous}
        previous, names = {name: ok}, [*names, name]
    markers = sorted({m for card in cards for m in _markers(card)})
    values_name = "Valores_" + target
    steps[values_name] = {
        "type": "Compose",
        "inputs": {m: "@{" + _esc(values[m]) + "}" for m in markers},
        "runAfter": previous,
    }
    if high_expr:
        # cards = [normal, alta]
        expr = f"if({high_expr}, string(outputs('{names[1]}')), string(outputs('{names[0]}')))"
    else:
        expr = f"string(outputs('{names[0]}'))"
    for marker in markers:
        expr = f"replace({expr}, {_lit('{{' + marker + '}}')}, string(outputs('{values_name}')?['{marker}']))"
    steps[target] = _compose("@" + expr, {values_name: ok})
    return steps


def _item_values(item: str) -> dict[str, str]:
    return {
        "eventId": f"{item}?['EventId']",
        "tipoEvento": "replace(" + _str(f"{item}?['TipoEvento']") + ", '_', ' ')",
        "zona": f"{item}?['Zona']",
        "nombreZona": f"{item}?['NombreZona']",
        "sitio": f"{item}?['Sitio']",
        "severidadInicial": f"{item}?['SeveridadInicial']",
        "horaLocal": f"convertFromUtc({item}?['FechaEventoUtc'], {_lit(TIME_ZONE)}, 'HH:mm')",
        "repeticiones": f"string({item}?['Repeticiones'])",
    }


def _sp_request(
    method: str,
    uri: str,
    body: str | None = None,
    merge: bool = False,
    after: dict | None = None,
    site_url: str = "",
) -> dict[str, Any]:
    headers = {"Accept": "application/json;odata=nometadata"}
    if body is not None:
        headers["Content-Type"] = "application/json;odata=nometadata"
    if merge:
        headers["IF-MATCH"] = "*"
        headers["X-HTTP-Method"] = "MERGE"
    params: dict[str, Any] = {
        "dataset": site_url,
        "parameters/method": method,
        "parameters/uri": uri,
        "parameters/headers": headers,
    }
    if body is not None:
        params["parameters/body"] = body
    return {
        "type": "OpenApiConnection",
        "inputs": {
            "parameters": params,
            "host": {
                "apiId": "/providers/Microsoft.PowerApps/apis/shared_sharepointonline",
                "operationId": "HttpRequest",
                "connectionName": "shared_sharepointonline",
            },
        },
        "runAfter": after or {},
    }


def _items_uri(select: str, filter_expr: str) -> str:
    return (
        f"@concat({_lit(f'_api/web/lists/getbytitle({_lit(LIST_TITLE)})/items?$select={select}&$filter=')}, "
        f"{filter_expr}, '&$top=1')"
    )


def _item_uri(id_expr: str) -> str:
    return f"@concat({_lit(f'_api/web/lists/getbytitle({_lit(LIST_TITLE)})/items(')}, string({id_expr}), ')')"


def _response(result: str, after: dict) -> dict[str, Any]:
    return {
        "type": "Response",
        "kind": "Skills",
        "inputs": {
            "schema": {
                "type": "object",
                "properties": {
                    "resultado": {
                        "title": "resultado",
                        "description": "publicado o ya publicado",
                        "type": "string",
                        "x-ms-content-hint": "TEXT",
                        "x-ms-dynamically-added": True,
                    }
                },
                "additionalProperties": {},
            },
            "statusCode": 200,
            "body": {"resultado": result},
        },
        "runAfter": after,
    }


def _post_card(message_expr: str, team_id: str, channel_id: str, after: dict) -> dict[str, Any]:
    return {
        "type": "OpenApiConnection",
        "inputs": {
            "parameters": {
                "poster": "Flow bot",
                "location": "Channel",
                "body/recipient/groupId": team_id,
                "body/recipient/channelId": channel_id,
                "body/messageBody": message_expr,
            },
            "host": {
                "apiId": "/providers/Microsoft.PowerApps/apis/shared_teams",
                "operationId": "PostCardToConversation",
                "connectionName": "shared_teams",
            },
        },
        "runAfter": after,
    }


def _compose(expr: str, after: dict | None = None) -> dict[str, Any]:
    return {"type": "Compose", "inputs": expr, "runAfter": after or {}}


def build_definition(
    site_url: str,
    team_id: str,
    channel_id: str,
    timeout: str = "PT15M",
    sharepoint_reference: str = "",
    teams_reference: str = "",
) -> dict[str, Any]:
    minutes = re.fullmatch(r"PT(\d+)M", timeout)
    if not minutes:
        raise ValueError("timeout debe tener la forma PT<n>M, por ejemplo PT15M")
    ok = ["Succeeded"]

    # --- Severidad final: a lo sumo un nivel de diferencia con la inicial (§5.0, ADR-008 paso 3) ---
    ini = _str(f"{ITEM}?['SeveridadInicial']")
    prop = _str("triggerBody()?['text_1']")

    def ordinal(x: str, fallback: str) -> str:
        return (
            f"if(equals({x}, 'Baja'), 0, if(equals({x}, 'Media'), 1, if(equals({x}, 'Alta'), 2, "
            f"if(equals({x}, {_lit('Crítica')}), 3, {fallback}))))"
        )

    final_values = _item_values(ITEM)
    final_values.update(
        {
            "severidadPropuesta": "outputs('Severidad_final')",
            "justificacionSeveridad": (
                f"if(empty({_trigger('text_2')}), {_lit('Sin cambio respecto a la severidad inicial.')}, "
                f"{_trunc(_trigger('text_2'), 500)})"
            ),
            "resumen": _trunc(_trigger("text_3"), 1000),
            "pasosProtocolo": _trunc(_trigger("text_4"), 1000),
            "protocoloAplicado": (
                f"if(empty({_trigger('text_5')}), 'Sin protocolo encontrado', {_trigger('text_5')})"
            ),
        }
    )
    is_high = (
        "or(equals(outputs('Severidad_final'), 'Alta'), equals(outputs('Severidad_final'), "
        + _lit("Crítica")
        + "))"
    )

    pending_body = (
        '{"Estado": "Pendiente de decisión", '
        '"SeveridadPropuesta": "@{outputs(\'Severidad_final\')}", '
        f'"JustificacionSeveridad": "@{{{_esc(final_values["justificacionSeveridad"])}}}", '
        f'"ResumenAgente": "@{{{_esc(final_values["resumen"])}}}", '
        f'"ProtocoloAplicado": "@{{{_esc(final_values["protocoloAplicado"])}}}", '
        '"PublicacionSolicitadaUtc": "@{utcNow()}"}'
    )

    # --- Rama de respuesta del supervisor ---
    current = "first(body('Leer_estado_actual')?['value'])"
    decision = f"body('{WAIT}')?['data']?['decision']"
    observacion = f"body('{WAIT}')?['data']?['observacion']"
    estado_por_decision = (
        f"if(equals({decision}, 'Atender'), 'Atendido', "
        f"if(equals({decision}, 'Escalar a autoridades'), 'Escalado', 'Falsa alarma'))"
    )
    decision_body = (
        '{"Estado": "@{' + estado_por_decision + '}", '
        '"Decision": "@{' + _esc(decision) + '}", '
        "\"DecididoPorId\": @{body('Asegurar_usuario')?['Id']}, "
        '"FechaDecision": "@{utcNow()}", '
        '"Observacion": "@{' + _esc(_trunc(observacion, 500)) + '}"}'
    )
    readonly_values = dict(final_values)
    readonly_values.update(
        {
            "decision": decision,
            # R-M4: el nombre exacto del campo del respondiente se confirma en la primera ejecución.
            "decididoPor": (
                f"coalesce(body('{WAIT}')?['responder']?['displayName'], "
                f"body('{WAIT}')?['responder']?['userPrincipalName'])"
            ),
            "horaDecision": f"convertFromUtc(utcNow(), {_lit(TIME_ZONE)}, 'HH:mm')",
            "observacion": (
                f"if(empty({_str(observacion)}), {_lit('Sin observación')}, {_trunc(observacion, 500)})"
            ),
            "minutosEspera": _lit(minutes.group(1)),
        }
    )

    wait_action = {
        "type": "OpenApiConnectionWebhook",
        "inputs": {
            "parameters": {
                "poster": "Flow bot",
                "location": "Channel",
                "body/body/recipient/groupId": team_id,
                "body/body/recipient/channelId": channel_id,
                "body/body/messageBody": "@{outputs('Armar_tarjeta')}",
                "body/body/updateMessage": (
                    "Respuesta recibida. La decisión del supervisor queda registrada en la lista "
                    "Eventos de seguridad."
                ),
            },
            "host": {
                "apiId": "/providers/Microsoft.PowerApps/apis/shared_teams",
                "operationId": "PostCardAndWaitForResponse",
                "connectionName": "shared_teams",
            },
        },
        "limit": {"timeout": timeout},
        "runAfter": {"Responder_publicado": ok},
    }

    new_branch = {
        "Ord_inicial": _compose("@" + ordinal(ini, "1")),
        "Ord_propuesta": _compose("@" + ordinal(prop, "outputs('Ord_inicial')"), {"Ord_inicial": ok}),
        "Ord_final": _compose(
            "@if(greater(sub(outputs('Ord_propuesta'), outputs('Ord_inicial')), 1), "
            "add(outputs('Ord_inicial'), 1), "
            "if(less(sub(outputs('Ord_propuesta'), outputs('Ord_inicial')), -1), "
            "sub(outputs('Ord_inicial'), 1), outputs('Ord_propuesta')))",
            {"Ord_propuesta": ok},
        ),
        "Severidad_final": _compose(
            "@createArray('Baja', 'Media', 'Alta', " + _lit("Crítica") + ")[outputs('Ord_final')]",
            {"Ord_final": ok},
        ),
        "Actualizar_pendiente": _sp_request(
            "POST",
            _item_uri(f"{ITEM}?['Id']"),
            pending_body,
            merge=True,
            after={"Severidad_final": ok},
            site_url=site_url,
        ),
        **_card_steps(
            "Armar_tarjeta",
            ["incidente-normal.json", "incidente-alta.json"],
            final_values,
            {"Actualizar_pendiente": ok},
            high_expr=is_high,
        ),
        "Responder_publicado": _response("publicado", {"Armar_tarjeta": ok}),
        WAIT: wait_action,
        "Leer_estado_actual": _sp_request(
            "GET",
            _items_uri("Id,Estado", f"concat('Id eq ', string({ITEM}?['Id']))"),
            after={WAIT: ok},
            site_url=site_url,
        ),
        "Si_sigue_pendiente": {
            "type": "If",
            "expression": {
                "and": [{"equals": [f"@coalesce({current}?['Estado'], '')", "Pendiente de decisión"]}]
            },
            "actions": {
                "Asegurar_usuario": _sp_request(
                    "POST",
                    "_api/web/ensureuser",
                    '{"logonName": "i:0#.f|membership|@{body(\''
                    + WAIT
                    + "')?['responder']?['userPrincipalName']}\"}",
                    site_url=site_url,
                ),
                "Registrar_decision": _sp_request(
                    "POST",
                    _item_uri(f"{ITEM}?['Id']"),
                    decision_body,
                    merge=True,
                    after={"Asegurar_usuario": ok},
                    site_url=site_url,
                ),
                **_card_steps(
                    "Armar_tarjeta_solo_lectura",
                    ["incidente-solo-lectura.json"],
                    readonly_values,
                    {"Registrar_decision": ok},
                ),
                "Publicar_solo_lectura": _post_card(
                    "@{outputs('Armar_tarjeta_solo_lectura')}",
                    team_id,
                    channel_id,
                    {"Armar_tarjeta_solo_lectura": ok},
                ),
            },
            "else": {
                "actions": {
                    # CA-10.6: la respuesta llegó con el incidente ya resuelto; no se escribe nada.
                    "Segunda_respuesta_ignorada": _compose(
                        "@concat('Ignorada: estado ', coalesce(" + current + "?['Estado'], ''))"
                    )
                }
            },
            "runAfter": {"Leer_estado_actual": ok},
        },
        # --- Rama de vencimiento (CA-10.5): sin decisión por defecto ---
        "Leer_estado_al_vencer": _sp_request(
            "GET",
            _items_uri("Id,Estado", f"concat('Id eq ', string({ITEM}?['Id']))"),
            after={WAIT: ["TimedOut"]},
            site_url=site_url,
        ),
        "Si_vencio_sigue_pendiente": {
            "type": "If",
            "expression": {
                "and": [
                    {
                        "equals": [
                            "@coalesce(first(body('Leer_estado_al_vencer')?['value'])?['Estado'], '')",
                            "Pendiente de decisión",
                        ]
                    }
                ]
            },
            "actions": {
                "Marcar_sin_respuesta": _sp_request(
                    "POST",
                    _item_uri(f"{ITEM}?['Id']"),
                    '{"Estado": "Sin respuesta"}',
                    merge=True,
                    site_url=site_url,
                ),
                **_card_steps(
                    "Armar_tarjeta_sin_respuesta",
                    ["sin-respuesta.json"],
                    readonly_values,
                    {"Marcar_sin_respuesta": ok},
                ),
                "Publicar_sin_respuesta": _post_card(
                    "@{outputs('Armar_tarjeta_sin_respuesta')}",
                    team_id,
                    channel_id,
                    {"Armar_tarjeta_sin_respuesta": ok},
                ),
            },
            "else": {"actions": {}},
            "runAfter": {"Leer_estado_al_vencer": ok},
        },
    }

    actions = {
        "LeerElemento": _sp_request(
            "GET",
            _items_uri(
                "Id,EventId,TipoEvento,Zona,NombreZona,Sitio,SeveridadInicial,Repeticiones,FechaEventoUtc,Estado",
                "concat('EventId eq ''', triggerBody()?['text'], '''')",
            ),
            site_url=site_url,
        ),
        "Si_estado_es_Nuevo": {
            "type": "If",
            "expression": {"and": [{"equals": [f"@coalesce({ITEM}?['Estado'], '')", "Nuevo"]}]},
            "actions": new_branch,
            "else": {"actions": {"Responder_ya_publicado": _response("ya publicado", {})}},
            "runAfter": {"LeerElemento": ok},
        },
    }

    trigger = {
        "type": "Request",
        "kind": "Skills",
        "inputs": {
            "schema": {
                "type": "object",
                "properties": {
                    key: {
                        "description": description,
                        "title": title,
                        "type": "string",
                        "x-ms-content-hint": "TEXT",
                        "x-ms-dynamically-added": True,
                    }
                    for key, title, description in INPUTS
                },
                "required": [key for key, _, _ in INPUTS[:4]],
            }
        },
    }

    def reference(api: str, logical: str) -> dict[str, Any]:
        return {
            "api": {"name": api},
            "connection": {"connectionReferenceLogicalName": logical},
            "runtimeSource": "embedded",
        }

    return {
        "connectionReferences": {
            "shared_sharepointonline": reference("shared_sharepointonline", sharepoint_reference),
            "shared_teams": reference("shared_teams", teams_reference),
        },
        "definition": {
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "contentVersion": "1.0.0.0",
            "metadata": {"defaultToEmbeddedConnections": True},
            "parameters": {
                "$authentication": {"defaultValue": {}, "type": "SecureObject"},
                "$connections": {"defaultValue": {}, "type": "Object"},
            },
            "triggers": {"manual": trigger},
            "actions": actions,
            "outputs": {},
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--site-url", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--channel-id", required=True)
    parser.add_argument("--timeout", default="PT15M")
    parser.add_argument("--sharepoint-reference", required=True)
    parser.add_argument("--teams-reference", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    definition = build_definition(
        args.site_url,
        args.team_id,
        args.channel_id,
        args.timeout,
        args.sharepoint_reference,
        args.teams_reference,
    )
    args.out.write_text(
        json.dumps({"properties": definition, "schemaVersion": "1.0.0.0"}, ensure_ascii=False),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
