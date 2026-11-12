"""T-061 (HU-16, CA-16.1, CA-16.4): histórico ficticio de incidentes."""

from __future__ import annotations

import csv
import re
from collections import Counter
from datetime import date, datetime

import pytest

from analytics.history import (
    ANOMALY_DAYS,
    ANOMALY_TYPE,
    ANOMALY_ZONE,
    BOGOTA,
    FIELDS,
    SHIFTS,
    generate,
    is_off_hours,
    proposed_severity,
    write_csv,
)
from function.core.severity import LEVELS

END = date(2026, 11, 26)


@pytest.fixture(scope="module")
def incidents():
    return generate(days=30, end=END, seed=27)


def test_es_determinista():
    assert generate(days=10, end=END, seed=1) == generate(days=10, end=END, seed=1)
    assert generate(days=10, end=END, seed=1) != generate(days=10, end=END, seed=2)


def test_cubre_exactamente_los_dias_pedidos(incidents):
    bogota = BOGOTA
    days = {
        datetime.fromisoformat(i.fechaUtc.replace("Z", "+00:00")).astimezone(bogota).date() for i in incidents
    }
    assert min(days) == date(2026, 10, 28)
    assert max(days) == END
    assert len(days) == 30


def test_regla_de_horario():
    assert proposed_severity("Media", off_hours=True) == "Alta"
    assert proposed_severity("Media", off_hours=False) == "Media"
    assert proposed_severity("Crítica", off_hours=True) == "Crítica"
    bogota = BOGOTA
    assert is_off_hours(datetime(2026, 11, 1, 5, 59, tzinfo=bogota))
    assert not is_off_hours(datetime(2026, 11, 1, 6, 0, tzinfo=bogota))
    assert is_off_hours(datetime(2026, 11, 1, 18, 0, tzinfo=bogota))


def test_severidades_coherentes_con_el_pipeline(incidents):
    for i in incidents:
        assert i.severidadInicial in LEVELS
        diff = LEVELS.index(i.severidadPropuesta) - LEVELS.index(i.severidadInicial)
        assert diff == (1 if i.fueraDeHorario and i.severidadInicial != "Crítica" else 0)


def test_la_anomalia_de_la_demo_esta_presente(incidents):
    bogota = BOGOTA

    def local_day(i):
        return datetime.fromisoformat(i.fechaUtc.replace("Z", "+00:00")).astimezone(bogota).date()

    per_day = Counter(
        local_day(i) for i in incidents if i.zona == ANOMALY_ZONE and i.tipoEvento == ANOMALY_TYPE
    )
    last = [per_day[d] for d in sorted(per_day)[-ANOMALY_DAYS:]]
    before = [n for d, n in per_day.items() if (END - d).days >= ANOMALY_DAYS]
    assert min(last) >= 6
    assert max(before, default=0) <= 4


def test_sin_datos_personales(incidents):
    for i in incidents:
        assert i.decididoPor in ("", *SHIFTS)
        for value in (i.decididoPor, i.nombreZona, i.sitio):
            assert "@" not in value
    assert all(re.fullmatch(r"[0-9a-f-]{36}", i.eventId) for i in incidents)
    assert len({i.eventId for i in incidents}) == len(incidents)


def test_sin_respuesta_no_tiene_decision(incidents):
    for i in incidents:
        if i.estado == "Sin respuesta":
            assert i.decision == "" and i.decididoPor == "" and i.minutosHastaDecision is None


def test_csv_tiene_el_contrato_de_columnas(incidents, tmp_path):
    out = tmp_path / "historico.csv"
    write_csv(incidents, out)
    with out.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert tuple(rows[0].keys()) == FIELDS
    assert len(rows) == len(incidents)
    assert {r["fueraDeHorario"] for r in rows} <= {"true", "false"}
