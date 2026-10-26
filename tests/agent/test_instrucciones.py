"""T-031 HU-08 (CA-08.1, CA-08.2, CA-08.7): estructura y contenido de las instrucciones del agente.

La revisión de fondo contra el Art. 1 y §5.0 la hace el revisor-seguridad; estas pruebas protegen lo que
no debe romperse al editar el archivo en vivo.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
TEXT = (ROOT / "agent" / "instrucciones.md").read_text(encoding="utf-8")

INSTR_START = "<!-- INSTRUCCIONES: inicio -->"
INSTR_END = "<!-- INSTRUCCIONES: fin -->"
RULE_START = "<!-- REGLA-HORARIO: inicio -->"
RULE_END = "<!-- REGLA-HORARIO: fin -->"

# Límite del campo de instrucciones en Copilot Studio:
# https://learn.microsoft.com/microsoft-copilot-studio/authoring-first-bot#create-an-agent
MAX_INSTRUCTIONS = 8000


def section(text: str, start: str, end: str) -> str:
    return text[text.index(start) + len(start) : text.index(end)]


INSTRUCTIONS = section(TEXT, INSTR_START, INSTR_END)
RULE = section(TEXT, RULE_START, RULE_END)
OUTSIDE_RULE = INSTRUCTIONS.replace(RULE, "")
LOWER = INSTRUCTIONS.lower()


@pytest.mark.parametrize("marker", [INSTR_START, INSTR_END, RULE_START, RULE_END])
def test_markers_appear_once(marker):
    assert TEXT.count(marker) == 1


def test_markers_ordered_and_nested():
    assert TEXT.index(INSTR_START) < TEXT.index(RULE_START) < TEXT.index(RULE_END) < TEXT.index(INSTR_END)


def test_instructions_fit_copilot_studio_limit():
    # Se pega el bloque completo, marcadores de la regla incluidos.
    assert len(INSTRUCTIONS.strip()) <= MAX_INSTRUCTIONS


# --- Regla de horario aislada (CA-08.2) --------------------------------------------------------


def test_rule_defines_daytime_window():
    assert "America/Bogota" in RULE
    assert "06:00 ≤ hora < 18:00" in RULE
    assert "FechaEventoUtc" in RULE
    assert re.search(r"06:00.{0,40}dentro", RULE)
    assert re.search(r"18:00.{0,40}fuera", RULE)


def test_rule_counts_within_one_level_limit():
    assert "un nivel" in RULE
    assert "límite" in RULE


def test_schedule_lives_only_in_rule_block():
    # Cambiar la regla en vivo solo exige tocar el bloque.
    for token in ["06:00", "18:00", "America/Bogota"]:
        assert token not in OUTSIDE_RULE, token


# --- Rol, idioma y herramientas (CA-08.1) ----------------------------------------------------------


def test_answers_in_spanish():
    assert "en español" in LOWER


@pytest.mark.parametrize("tool", ["LeerIncidente", "PublicarIncidente"])
def test_tools_named(tool):
    assert tool in INSTRUCTIONS


def test_publish_called_once_and_idempotent():
    assert "una sola vez" in LOWER
    assert "ya publicado" in LOWER


@pytest.mark.parametrize(
    "param",
    [
        "eventId",
        "severidadPropuesta",
        "justificacionSeveridad",
        "resumen",
        "pasosProtocolo",
        "protocoloAplicado",
    ],
)
def test_publish_parameters(param):
    assert param in INSTRUCTIONS


# --- Lo que nunca hace (Art. 1) --------------------------------------------------------------------


@pytest.mark.parametrize(
    "prohibition",
    [
        "llamar a autoridades",
        "abrir o bloquear accesos",
        "confrontar o retener",
        "cerrar un caso como falsa alarma",
        "cambiar un protocolo",
    ],
)
def test_article_1_prohibitions(prohibition):
    assert prohibition in LOWER


def test_never_claims_to_have_notified_anyone():
    # Publicar en el canal no es contactar, pero nunca afirma haber avisado a nadie (ajuste 2026-10-26).
    for verb in ["avisado", "llamado", "escrito", "notificado"]:
        assert verb in LOWER, verb
    assert "avisé al supervisor" in LOWER
    assert "publicar la propuesta en el canal no es contactar" in LOWER


def test_person_decides():
    assert "la persona decide" in LOWER or "el supervisor decide" in LOWER


# --- Modelo de severidad §5.0 (CA-08.7) -------------------------------------------------------------


def test_severity_scale_in_order():
    assert "`Baja` < `Media` < `Alta` < `Crítica`" in INSTRUCTIONS


def test_severity_one_level_and_justification():
    assert "un solo nivel" in LOWER
    assert "SeveridadInicial" in INSTRUCTIONS
    assert "JustificacionSeveridad" in INSTRUCTIONS or "justificacionSeveridad" in INSTRUCTIONS
    assert "obligatoria" in LOWER
