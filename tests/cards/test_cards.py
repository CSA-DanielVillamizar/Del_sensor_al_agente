"""T-030 HU-09 (CA-09.1 a CA-09.5, RNF-07, RNF-08) y HU-10 (CA-10.2, CA-10.5): contrato de las tarjetas.

Las tarjetas son JSON de Adaptive Cards 1.5 sin plantillas. Llevan marcadores `{{campo}}` dentro de
cadenas que el flujo `PublicarIncidente` reemplaza con expresiones (ver `cards/README.md`). Las pruebas
reemplazan los marcadores con `cards/ejemplos/*.data.json`, escapando cada valor como cadena JSON, y
validan el resultado contra la copia versionada del esquema oficial (`cards/schema/adaptive-card-1.5.json`).
"""

import json
import re
from pathlib import Path

import pytest
from jsonschema import Draft6Validator

ROOT = Path(__file__).resolve().parents[2]
CARDS_DIR = ROOT / "cards"
EXAMPLES_DIR = CARDS_DIR / "ejemplos"
SCHEMA = json.loads((CARDS_DIR / "schema" / "adaptive-card-1.5.json").read_text(encoding="utf-8"))
VALIDATOR = Draft6Validator(SCHEMA)
README = (CARDS_DIR / "README.md").read_text(encoding="utf-8")

INTERACTIVE = ["incidente-normal", "incidente-alta"]
READ_ONLY = ["incidente-solo-lectura", "sin-respuesta"]
ALL_CARDS = INTERACTIVE + READ_ONLY

HEADER = "Propuesta del Agente de Operaciones"
DECISIONS = ["Atender", "Escalar a autoridades", "Falsa alarma"]
MAX_BYTES = 28 * 1024
# Topes que aplica el flujo con substring() antes de insertar los textos libres.
LONG_FIELDS = {"resumen": 1000, "pasosProtocolo": 1000, "justificacionSeveridad": 500, "observacion": 500}
PLACEHOLDER = re.compile(r"\{\{([A-Za-z][A-Za-z0-9]*)\}\}")

# Frases que afirmarían una acción ejecutada por el agente o por el sistema (CA-09.5, Art. 1).
FORBIDDEN = [
    r"\bllam[ée]\b",
    r"\bllamamos\b",
    r"\bhe llamado\b",
    r"\bse llam[óo]\b",
    r"\bcontact[ée]\b",
    r"\bcontactamos\b",
    r"\bhe contactado\b",
    r"\bse contact[óo]\b",
    r"\bse notific[óo]\b",
    r"\bnotifiqu[ée]\b",
    r"\bse avis[óo]\b",
    r"\bavis[ée]\b",
    r"\bse alert[óo] a\b",
    r"\balert[ée]\b",
    # Publicar la propuesta en el canal no es contactar, pero nunca se afirma haber avisado,
    # escrito, informado o notificado a una persona o autoridad (ajuste del 2026-10-26).
    r"\b(?:le |les )?escrib[íi]\b",
    r"\b(?:le |les )?inform[ée]\b",
    r"\bse (?:le |les )?inform[óo]\b",
    r"\bse (?:le |les )?escribi[óo]\b",
    r"\bya (?:se )?(?:avis|notific|inform)",
    r"\bse envi[óo] a la polic[íi]a\b",
    r"\bpolic[íi]a (?:ya )?(?:fue|está) en camino\b",
    r"\bdespach[ée]\b",
    r"\bse despach[óo]\b",
    r"\bse bloque[óo]\b",
    r"\bbloque[ée]\b",
    r"\bse abri[óo]\b",
    r"\babr[íi] la\b",
    r"\bse cerr[óo] (?:el caso|la puerta|el acceso)\b",
    r"\bcerr[ée] el caso\b",
    r"\bse retuvo\b",
    r"\bya se escal[óo]\b",
    r"\bescal[ée]\b",
]


def load_card(name: str) -> dict:
    return json.loads((CARDS_DIR / f"{name}.json").read_text(encoding="utf-8"))


def load_data(name: str) -> dict:
    return json.loads((EXAMPLES_DIR / f"{name}.data.json").read_text(encoding="utf-8"))


def fill(raw: str, data: dict) -> str:
    """Reemplaza `{{campo}}` por el valor escapado como contenido de cadena JSON (lo que hará el flujo)."""

    def repl(match: re.Match) -> str:
        key = match.group(1)
        if key not in data:
            raise KeyError(f"Falta el marcador {key!r} en los datos de ejemplo")
        return json.dumps(str(data[key]), ensure_ascii=False)[1:-1]

    return PLACEHOLDER.sub(repl, raw)


def rendered(name: str) -> tuple[str, dict]:
    raw = (CARDS_DIR / f"{name}.json").read_text(encoding="utf-8")
    text = fill(raw, load_data(name))
    return text, json.loads(text)


def walk(node):
    """Recorre todos los diccionarios del JSON."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            if key not in ("type", "id", "style", "size", "weight", "color", "spacing", "version", "$schema"):
                yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)


def visible_text(card: dict) -> str:
    return "\n".join(strings(card))


def textblock_with(card: dict, marker: str) -> dict:
    blocks = [n for n in walk(card) if n.get("type") == "TextBlock" and marker in n.get("text", "")]
    assert len(blocks) == 1, f"Se esperaba un solo TextBlock con {marker}"
    return blocks[0]


# --- Esquema ---------------------------------------------------------------------------------


def test_schema_copy_is_valid_draft_06():
    Draft6Validator.check_schema(SCHEMA)


def test_schema_copy_is_strict():
    # La copia oficial rechaza propiedades desconocidas; sin esto la validación no probaría nada.
    assert SCHEMA["definitions"]["TextBlock"]["additionalProperties"] is False


@pytest.mark.parametrize("name", ALL_CARDS)
def test_template_is_valid_json_and_schema(name):
    card = load_card(name)
    assert list(VALIDATOR.iter_errors(card)) == []


@pytest.mark.parametrize("name", ALL_CARDS)
def test_rendered_card_validates_against_schema(name):
    _, card = rendered(name)
    assert list(VALIDATOR.iter_errors(card)) == []
    assert PLACEHOLDER.search(json.dumps(card, ensure_ascii=False)) is None


@pytest.mark.parametrize("name", ALL_CARDS)
def test_version_is_1_5(name):
    card = load_card(name)
    assert card["type"] == "AdaptiveCard"
    assert card["version"] == "1.5"


def test_schema_rejects_unknown_property():
    card = load_card("incidente-normal")
    card["body"][0]["noExiste"] = True
    assert list(VALIDATOR.iter_errors(card)) != []


# --- Sin plantillas, solo Action.Submit, sin isEnabled (CA-09.1, CA-09.4) -----------------------


@pytest.mark.parametrize("name", ALL_CARDS)
def test_no_templating_syntax(name):
    raw = (CARDS_DIR / f"{name}.json").read_text(encoding="utf-8")
    assert "${" not in raw
    assert "$data" not in raw
    assert "$when" not in raw


@pytest.mark.parametrize("name", ALL_CARDS)
def test_only_action_submit(name):
    card = load_card(name)
    action_types = {n["type"] for n in walk(card) if str(n.get("type", "")).startswith("Action.")}
    assert action_types <= {"Action.Submit"}
    assert all("selectAction" not in n for n in walk(card))


@pytest.mark.parametrize("name", ALL_CARDS)
def test_no_is_enabled(name):
    card = load_card(name)
    assert all("isEnabled" not in n for n in walk(card))


# --- Tamaño (< 28 KB) ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ALL_CARDS)
def test_size_under_limit_with_example(name):
    text, _ = rendered(name)
    assert len(text.encode("utf-8")) < MAX_BYTES


@pytest.mark.parametrize("name", ALL_CARDS)
def test_size_under_limit_worst_case(name):
    # Textos libres en su tope (cards/README.md, "Topes de longitud") y el resto a 100 caracteres,
    # todos no ASCII (2 bytes en UTF-8): margen ante textos largos del agente.
    raw = (CARDS_DIR / f"{name}.json").read_text(encoding="utf-8")
    keys = set(PLACEHOLDER.findall(raw))
    text = fill(raw, {k: "á" * LONG_FIELDS.get(k, 100) for k in keys})
    assert len(text.encode("utf-8")) < MAX_BYTES


# --- Contenido (CA-09.2, RNF-07, RNF-08) ---------------------------------------------------------


@pytest.mark.parametrize("name", ALL_CARDS)
def test_header(name):
    _, card = rendered(name)
    first = card["body"][0]
    texts = [n.get("text", "") for n in walk(first) if n.get("type") == "TextBlock"]
    assert HEADER in texts


@pytest.mark.parametrize("name", ALL_CARDS)
def test_local_time_with_cot(name):
    raw = load_card(name)
    assert "{{horaLocal}} COT" in visible_text(raw)
    _, card = rendered(name)
    assert re.search(r"\b\d{2}:\d{2} COT\b", visible_text(card))


@pytest.mark.parametrize("name", ALL_CARDS)
def test_reference_for_tramo2(name):
    # `Ref. {eventId}` en letra pequeña: demo/measure.ps1 une el mensaje con el elemento por este texto.
    card = load_card(name)
    block = textblock_with(card, "Ref. {{eventId}}")
    assert block.get("size") == "Small"


@pytest.mark.parametrize("name", INTERACTIVE + ["incidente-solo-lectura"])
def test_incident_fields_present(name):
    text = visible_text(load_card(name))
    for marker in [
        "{{tipoEvento}}",
        "{{zona}}",
        "{{nombreZona}}",
        "{{severidadInicial}}",
        "{{severidadPropuesta}}",
        "{{justificacionSeveridad}}",
        "{{repeticiones}}",
        "{{resumen}}",
        "{{pasosProtocolo}}",
    ]:
        assert marker in text, marker


@pytest.mark.parametrize("name", INTERACTIVE + ["incidente-solo-lectura"])
@pytest.mark.parametrize("marker", ["{{resumen}}", "{{pasosProtocolo}}"])
def test_summary_and_protocol_max_three_lines(name, marker):
    block = textblock_with(load_card(name), marker)
    assert block.get("maxLines") == 3
    assert block.get("wrap") is True


def test_high_variant_uses_attention_and_text():
    card = load_card("incidente-alta")
    attention = [n for n in walk(card) if n.get("type") == "Container" and n.get("style") == "attention"]
    assert len(attention) == 1
    # RNF-07: la severidad también va en texto, no solo en color.
    inner = visible_text(attention[0])
    assert "{{severidadPropuesta}}" in inner


def test_normal_variant_has_no_attention():
    card = load_card("incidente-normal")
    assert all(n.get("style") != "attention" for n in walk(card))


# --- Acciones y observación (CA-09.3) ------------------------------------------------------------


@pytest.mark.parametrize("name", INTERACTIVE)
def test_three_decisions(name):
    card = load_card(name)
    actions = card["actions"]
    assert [a["type"] for a in actions] == ["Action.Submit"] * 3
    assert [a["title"] for a in actions] == DECISIONS
    assert [a["data"]["decision"] for a in actions] == DECISIONS
    assert all(a["data"].get("eventId") == "{{eventId}}" for a in actions)


@pytest.mark.parametrize("name", INTERACTIVE)
def test_optional_observation_input(name):
    card = load_card(name)
    inputs = [n for n in walk(card) if str(n.get("type", "")).startswith("Input.")]
    assert len(inputs) == 1
    field = inputs[0]
    assert field["type"] == "Input.Text"
    assert field["id"] == "observacion"
    assert field.get("isRequired", False) is False
    assert field.get("label")


@pytest.mark.parametrize("name", READ_ONLY)
def test_read_only_cards_have_no_actions_or_inputs(name):
    card = load_card(name)
    assert not card.get("actions")
    assert not [n for n in walk(card) if str(n.get("type", "")).startswith(("Input.", "Action."))]


def test_read_only_shows_decision_who_and_when():
    text = visible_text(load_card("incidente-solo-lectura"))
    for marker in ["{{decision}}", "{{decididoPor}}", "{{horaDecision}} COT", "{{observacion}}"]:
        assert marker in text, marker


def test_no_response_card_says_no_decision_recorded():
    _, card = rendered("sin-respuesta")
    text = visible_text(card)
    assert "Sin respuesta" in text
    assert "no se registró ninguna decisión" in text
    assert "15 minutos" in text


# --- Ningún texto afirma una acción ejecutada (CA-09.5) --------------------------------------------


@pytest.mark.parametrize("name", ALL_CARDS)
def test_no_text_claims_executed_action(name):
    _, card = rendered(name)
    text = visible_text(card).lower()
    hits = [p for p in FORBIDDEN if re.search(p, text)]
    assert hits == []


@pytest.mark.parametrize(
    "phrase",
    [
        "Llamé a la policía",
        "Se notificó a la policía",
        "Contacté al vigilante",
        "Se bloqueó el acceso",
        "Avisé al supervisor",
        "Le escribí al jefe de turno",
        "Informé a la recepción",
        "Ya se avisó a seguridad",
    ],
)
def test_forbidden_list_catches_examples(phrase):
    assert any(re.search(p, phrase.lower()) for p in FORBIDDEN)


@pytest.mark.parametrize("name", INTERACTIVE)
def test_escalation_is_presented_as_record_only(name):
    text = visible_text(load_card(name))
    assert "solo se registra" in text


# --- Datos de ejemplo y documentación de marcadores ---------------------------------------------


@pytest.mark.parametrize("name", ALL_CARDS)
def test_example_covers_exactly_the_placeholders(name):
    raw = (CARDS_DIR / f"{name}.json").read_text(encoding="utf-8")
    assert set(PLACEHOLDER.findall(raw)) == set(load_data(name))


def test_every_placeholder_documented_in_readme():
    used = set()
    for name in ALL_CARDS:
        used |= set(PLACEHOLDER.findall((CARDS_DIR / f"{name}.json").read_text(encoding="utf-8")))
    missing = [k for k in sorted(used) if f"`{{{{{k}}}}}`" not in README]
    assert missing == []


def test_escaping_keeps_json_valid():
    # Un resumen con comillas, barra invertida y salto de línea no rompe la tarjeta si se escapa.
    raw = (CARDS_DIR / "incidente-normal.json").read_text(encoding="utf-8")
    data = load_data("incidente-normal") | {"resumen": 'Puerta "B"\nruta C:\\demo'}
    card = json.loads(fill(raw, data))
    assert list(VALIDATOR.iter_errors(card)) == []


def test_examples_use_fictional_catalog():
    zones = {z["zone"]: z for z in json.loads((ROOT / "data" / "zonas.json").read_text(encoding="utf-8"))}
    for path in EXAMPLES_DIR.glob("*.data.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        if "zona" in data:
            assert data["nombreZona"] == zones[data["zona"]]["zoneName"], path.name
