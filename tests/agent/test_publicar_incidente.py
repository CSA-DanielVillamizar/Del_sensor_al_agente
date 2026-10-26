"""T-037 y T-038 HU-10: la definición generada de PublicarIncidente sigue ADR-008."""

import json
from pathlib import Path

import pytest

from agent.flows.build_publicar_incidente import build_definition

ROOT = Path(__file__).resolve().parents[2]

PARAMS = {
    "site_url": "https://contoso.sharepoint.com/sites/demo",
    "team_id": "00000000-0000-0000-0000-000000000001",
    "channel_id": "19:canal-ficticio@thread.tacv2",
    "timeout": "PT15M",
    "sharepoint_reference": "new_sharedsharepointonline_ficticio",
    "teams_reference": "new_sharedteams_ficticio",
}


@pytest.fixture(scope="module")
def flow() -> dict:
    return build_definition(**PARAMS)


def _actions(node: dict) -> dict:
    """Todas las acciones, incluidas las anidadas en ramas y condiciones."""
    found = {}
    for name, action in node.get("actions", {}).items():
        found[name] = action
        found.update(_actions(action))
        if "else" in action:
            found.update(_actions(action["else"]))
    return found


def test_trigger_is_agent_tool_with_six_text_inputs(flow):
    trigger = flow["definition"]["triggers"]["manual"]
    assert trigger["kind"] == "Skills"
    props = trigger["inputs"]["schema"]["properties"]
    titles = [p["title"] for p in props.values()]
    assert titles == [
        "eventId",
        "severidadPropuesta",
        "justificacionSeveridad",
        "resumen",
        "pasosProtocolo",
        "protocoloAplicado",
    ]


def test_not_express_mode_because_it_waits(flow):
    # El modo express no admite esperas de tipo webhook (ADR-008).
    meta = flow["definition"]["triggers"]["manual"].get("metadata", {})
    assert meta.get("flowSystemMetadata", {}).get("flowKind") != "Stateless"


def test_responds_to_agent_before_posting_the_card(flow):
    actions = _actions(flow["definition"])
    post = actions["Publicar_tarjeta_y_esperar"]
    assert "Responder_publicado" in post["runAfter"]
    assert actions["Responder_publicado"]["type"] == "Response"


def test_idempotent_when_state_is_not_new(flow):
    cond = flow["definition"]["actions"]["Si_estado_es_Nuevo"]
    assert "Nuevo" in json.dumps(cond["expression"], ensure_ascii=False)
    else_actions = cond["else"]["actions"]
    assert "ya publicado" in json.dumps(else_actions["Responder_ya_publicado"]["inputs"]["body"])


def test_wait_has_fifteen_minute_timeout_and_flow_bot_in_channel(flow):
    post = _actions(flow["definition"])["Publicar_tarjeta_y_esperar"]
    assert post["type"] == "OpenApiConnectionWebhook"
    assert post["inputs"]["host"]["operationId"] == "PostCardAndWaitForResponse"
    assert post["limit"]["timeout"] == "PT15M"
    params = post["inputs"]["parameters"]
    assert params["poster"] == "Flow bot"
    assert params["location"] == "Channel"


def test_timeout_branch_marks_sin_respuesta_without_decision(flow):
    actions = _actions(flow["definition"])
    assert actions["Leer_estado_al_vencer"]["runAfter"]["Publicar_tarjeta_y_esperar"] == ["TimedOut"]
    timeout_branch = actions["Si_vencio_sigue_pendiente"]
    assert "Leer_estado_al_vencer" in timeout_branch["runAfter"]
    assert "Pendiente de decisión" in json.dumps(timeout_branch["expression"], ensure_ascii=False)
    merge = json.dumps(actions["Marcar_sin_respuesta"]["inputs"])
    assert "Sin respuesta" in merge
    assert "Decision" not in merge and "DecididoPor" not in merge


def test_response_branch_checks_state_before_writing(flow):
    actions = _actions(flow["definition"])
    cond = actions["Si_sigue_pendiente"]
    assert "Pendiente de decisión" in json.dumps(cond["expression"], ensure_ascii=False)
    assert "Registrar_decision" in cond["actions"]


def test_no_action_contacts_anyone(flow):
    # CA-10.3 y Art. 1: solo SharePoint y tarjetas en el canal; nada de correo, llamadas ni mensajes directos.
    allowed = {"HttpRequest", "PostCardAndWaitForResponse", "PostCardToConversation"}
    for action in _actions(flow["definition"]).values():
        host = action.get("inputs", {}).get("host", {}) if isinstance(action.get("inputs"), dict) else {}
        if host:
            assert host["operationId"] in allowed
            params = action["inputs"].get("parameters", {})
            if "location" in params:
                assert params["location"] == "Channel"


@pytest.mark.parametrize(
    "action,card",
    [
        ("Armar_tarjeta", "incidente-normal.json"),
        ("Armar_tarjeta", "incidente-alta.json"),
        ("Armar_tarjeta_solo_lectura", "incidente-solo-lectura.json"),
        ("Armar_tarjeta_sin_respuesta", "sin-respuesta.json"),
    ],
)
def test_every_card_marker_is_replaced(flow, action, card):
    import re

    markers = set(re.findall(r"\{\{(\w+)\}\}", (ROOT / "cards" / card).read_text(encoding="utf-8")))
    expression = json.dumps(_actions(flow["definition"])[action]["inputs"])
    for marker in markers:
        assert f"'{{{{{marker}}}}}'" in expression, f"{card}: falta reemplazar {marker}"


def test_no_tenant_values_in_definition_besides_parameters(flow):
    text = json.dumps(flow)
    assert "contoso.sharepoint.com/sites/demo" in text
    assert ".sharepoint.com" not in text.replace("contoso.sharepoint.com", "")


def test_uses_existing_connection_references(flow):
    refs = flow["connectionReferences"]
    assert set(refs) == {"shared_sharepointonline", "shared_teams"}


def _strings(node):
    if isinstance(node, dict):
        for value in node.values():
            yield from _strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from _strings(value)
    elif isinstance(node, str):
        yield node


def test_every_expression_fits_the_platform_limit(flow):
    # La plataforma rechaza al activar cualquier expresión de más de 8192 caracteres.
    longest = max(len(s) for s in _strings(flow["definition"]) if "@" in s)
    assert longest <= 8192


def test_handled_timeout_ends_the_run_as_succeeded(flow):
    # El vencimiento es un resultado esperado (CA-10.5): la ejecución no debe quedar en rojo en el historial.
    branch = _actions(flow["definition"])["Si_vencio_sigue_pendiente"]["actions"]
    end = branch["Terminar_sin_respuesta"]
    assert end["type"] == "Terminate"
    assert end["inputs"]["runStatus"] == "Succeeded"
    assert end["runAfter"] == {"Publicar_sin_respuesta": ["Succeeded"]}
