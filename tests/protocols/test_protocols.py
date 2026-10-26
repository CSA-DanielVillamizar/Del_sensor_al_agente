"""T-028 HU-07 CA-07.3: un protocolo ficticio por tipo de evento, de una página, y su versión .docx."""

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest
from docx import Document

ROOT = Path(__file__).resolve().parents[2]
PROTOCOLS = ROOT / "protocols"
BUILD_SCRIPT = ROOT / "sharepoint" / "build-protocols.py"
SCHEMA = json.loads((ROOT / "schemas" / "evento-dispositivo.schema.json").read_text(encoding="utf-8"))
EVENT_TYPES = SCHEMA["properties"]["type"]["enum"]

DECISION_HEADING = "## Lo que decide una persona"
MAX_WORDS = 450

# Verbos con los que empieza cada paso: el supervisor verifica, nunca ejecuta una acción física automática.
VERIFY_VERBS = (
    "Verifica",
    "Revisa",
    "Confirma",
    "Consulta",
    "Compara",
    "Identifica",
    "Observa",
    "Registra",
    "Lee",
)

# Frases que afirmarían una acción ejecutada por el agente o por el sistema (Art. 1).
FORBIDDEN = [
    r"\bel agente (ya )?(llam|abr|bloque|cerr|cierr|contact|notific|avis|confront|reten|escal|despach|activ)",
    r"\bse (llamó|notificó|avisó|contactó|bloqueó|abrió|cerró|escaló|despachó|activó)\b",
    r"\bautomáticamente\b",
    r"\bse (ha|han) (llamado|notificado|avisado|contactado|bloqueado|abierto|cerrado|escalado)\b",
]

# Art. 5 y prohibiciones del repositorio: sin teléfonos, correos ni direcciones.
PHONE = re.compile(r"(\+?\d[\d\s().-]{6,}\d)")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
ADDRESS = re.compile(r"\b(calle|carrera|avenida|cra\.|cl\.|av\.)\s*\d", re.IGNORECASE)


def load_build_module():
    spec = importlib.util.spec_from_file_location("build_protocols", BUILD_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(event_type):
    return (PROTOCOLS / f"{event_type}.md").read_text(encoding="utf-8")


def section(text, heading):
    """Devuelve el cuerpo de un apartado de nivel 2, hasta el siguiente apartado de nivel 2."""
    start = text.index(heading) + len(heading)
    rest = text[start:]
    following = re.search(r"^## ", rest, flags=re.MULTILINE)
    return rest[: following.start()] if following else rest


def numbered_steps(text):
    return [m.group(1).strip() for m in re.finditer(r"^\d+\.\s+(.+)$", text, flags=re.MULTILINE)]


def word_count(text):
    plain = re.sub(r"[#*`>_|-]", " ", text)
    return len(re.findall(r"\w+", plain))


def test_there_is_exactly_one_protocol_per_event_type():
    found = {p.stem for p in PROTOCOLS.glob("*.md")}
    assert found == set(EVENT_TYPES)


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_required_sections_are_present(event_type):
    text = read(event_type)
    assert text.startswith("# "), "el protocolo empieza con un título"
    assert "## Alcance" in text
    assert "## Pasos" in text
    assert text.count(DECISION_HEADING + "\n") == 1, "apartado exacto y único"
    assert re.search(r"^\*\*Versión:\*\* \d+\.\d+", text, flags=re.MULTILINE)


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_steps_are_numbered_and_only_verify(event_type):
    steps = numbered_steps(section(read(event_type), "## Pasos"))
    assert 4 <= len(steps) <= 8
    for step in steps:
        assert step.startswith(VERIFY_VERBS), f"el paso no es una verificación: {step}"


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_human_decisions_cover_article_1(event_type):
    decisions = section(read(event_type), DECISION_HEADING).lower()
    for keyword in ("autoridades", "abrir", "bloquear", "confrontar", "falsa alarma"):
        assert keyword in decisions, f"falta la decisión humana: {keyword}"


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_fits_one_page(event_type):
    assert word_count(read(event_type)) <= MAX_WORDS


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_no_phrase_claims_an_action_executed_by_the_agent(event_type):
    text = read(event_type).lower()
    for pattern in FORBIDDEN:
        assert not re.search(pattern, text), f"frase prohibida: {pattern}"


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_no_real_contact_data(event_type):
    text = read(event_type)
    assert not PHONE.search(text)
    assert not EMAIL.search(text)
    assert not ADDRESS.search(text)
    assert "http" not in text


def test_forbidden_patterns_catch_an_agent_claim():
    # Control de la propia prueba: la lista sí detecta una afirmación prohibida.
    sample = "el agente llamó a la policía y se bloqueó la puerta."
    assert any(re.search(p, sample) for p in FORBIDDEN)


def test_docx_is_generated_with_real_headings_and_numbered_steps(tmp_path):
    module = load_build_module()
    outputs = module.build(PROTOCOLS, tmp_path)
    assert {p.name for p in outputs} == {f"{t}.docx" for t in EVENT_TYPES}

    for event_type in EVENT_TYPES:
        doc = Document(str(tmp_path / f"{event_type}.docx"))
        paragraphs = doc.paragraphs
        styles = [p.style.name for p in paragraphs]
        texts = [p.text for p in paragraphs]

        assert styles[0] == "Title"
        assert "Lo que decide una persona" in [p.text for p in paragraphs if p.style.name == "Heading 1"]

        expected_steps = [
            re.sub(r"\*\*", "", s) for s in numbered_steps(section(read(event_type), "## Pasos"))
        ]
        numbered = [p for p in paragraphs if p.style.name == "List Number"]
        assert [p.text for p in numbered] == expected_steps
        # Lista numerada real de Word: el estilo lleva numeración (w:numPr), no números escritos a mano.
        assert numbered[0].style.element.pPr.numPr is not None
        assert not any(re.match(r"^\d+\.", t) for t in texts)
        assert any(t.startswith("Versión:") for t in texts)


def test_build_script_runs_from_the_command_line(tmp_path):
    result = subprocess.run(  # noqa: S603
        [sys.executable, str(BUILD_SCRIPT), "--out", str(tmp_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert len(list(tmp_path.glob("*.docx"))) == len(EVENT_TYPES)
