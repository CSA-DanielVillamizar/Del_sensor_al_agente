"""T-011 HU-06 CA-06.3: `sharepoint/columnas.json` es la única fuente del cuerpo que arma la Function."""

import json
import re
from datetime import UTC, datetime
from pathlib import Path

import pytest

from function.core.contracts import load_contracts
from function.core.enrich import ZoneCatalog, enrich
from function.core.listitem import ColumnContract, ContractViolation, build_create_fields, repetitions_fields
from function.core.severity import LEVELS

ROOT = Path(__file__).resolve().parents[2]
COLUMNS = json.loads((ROOT / "sharepoint" / "columnas.json").read_text(encoding="utf-8"))
EVENT_SCHEMA = json.loads((ROOT / "schemas" / "evento-dispositivo.schema.json").read_text(encoding="utf-8"))
CONTRACT = ColumnContract(COLUMNS)
CATALOG = ZoneCatalog(load_contracts().zones)

EVENT = {
    "schemaVersion": "1.0",
    "eventId": "3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37",
    "deviceId": "DEV-SIM-01",
    "type": "puerta_forzada",
    "zone": "Z-03",
    "timestamp": "2026-11-04T19:32:05Z",
    "rawSeverity": "Alta",
}
RECEIVED = datetime(2026, 11, 4, 19, 32, 6, 250000, tzinfo=UTC)
ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")

# Plan §4.3: columnas, tipo y quién escribe.
PLAN_COLUMNS = {
    "Title": "text",
    "EventId": "text",
    "DeviceId": "text",
    "TipoEvento": "choice",
    "Zona": "text",
    "NombreZona": "text",
    "CamaraId": "text",
    "Sitio": "text",
    "SeveridadRaw": "choice",
    "SeveridadInicial": "choice",
    "Repeticiones": "number",
    "FechaEventoUtc": "dateTime",
    "RecibidoUtc": "dateTime",
    "EsPrueba": "boolean",
    "Estado": "choice",
    "SeveridadPropuesta": "choice",
    "JustificacionSeveridad": "text",
    "ResumenAgente": "text",
    "ProtocoloAplicado": "text",
    "PublicacionSolicitadaUtc": "dateTime",
    "Decision": "choice",
    "DecididoPor": "personOrGroup",
    "FechaDecision": "dateTime",
    "Observacion": "text",
}
FUNCTION_REQUIRED = {
    "Title",
    "EventId",
    "DeviceId",
    "TipoEvento",
    "Zona",
    "NombreZona",
    "CamaraId",
    "Sitio",
    "SeveridadRaw",
    "SeveridadInicial",
    "Repeticiones",
    "FechaEventoUtc",
    "RecibidoUtc",
    "EsPrueba",
    "Estado",
}


def fields(is_test=False):
    return build_create_fields(
        enrich(EVENT, CATALOG), received_utc=RECEIVED, is_test=is_test, contract=CONTRACT
    )


# --- El contrato en sí ---


def test_contract_matches_plan_4_3():
    assert {c["name"]: c["type"] for c in COLUMNS["columns"]} == PLAN_COLUMNS
    assert COLUMNS["list"] == "Eventos de seguridad"


def test_column_names_are_unique():
    names = [c["name"] for c in COLUMNS["columns"]]
    assert len(names) == len(set(names))


def test_event_id_is_unique_and_indexed():
    event_id = CONTRACT.column("EventId")
    assert event_id["unique"] and event_id["indexed"] and event_id["required"]


def test_function_writes_exactly_the_required_columns():
    assert set(CONTRACT.writable_by("function")) == FUNCTION_REQUIRED
    assert all(CONTRACT.column(n)["required"] for n in FUNCTION_REQUIRED)


def test_choices_match_schema_and_severity_scale():
    assert CONTRACT.column("TipoEvento")["choices"] == EVENT_SCHEMA["properties"]["type"]["enum"]
    for name in ("SeveridadRaw", "SeveridadInicial", "SeveridadPropuesta"):
        assert tuple(CONTRACT.column(name)["choices"]) == LEVELS
    assert CONTRACT.column("Estado")["choices"] == [
        "Nuevo",
        "Pendiente de decisión",
        "Atendido",
        "Escalado",
        "Falsa alarma",
        "Sin respuesta",
    ]
    assert CONTRACT.column("Decision")["choices"] == ["Atender", "Escalar a autoridades", "Falsa alarma"]


# --- El cuerpo que arma la Function ---


def test_body_uses_only_contract_columns_written_by_the_function():
    assert set(fields()) == FUNCTION_REQUIRED


def test_body_values():
    f = fields()
    assert f["Title"] == "puerta_forzada · Z-03"
    assert f["EventId"] == EVENT["eventId"]
    assert f["DeviceId"] == "DEV-SIM-01"
    assert f["TipoEvento"] == "puerta_forzada"
    assert f["Zona"] == "Z-03"
    assert f["NombreZona"] == "Bodega norte"
    assert f["CamaraId"] == "CAM-03"
    assert f["Sitio"] == "Sede Demo Centro"
    assert f["SeveridadRaw"] == "Alta"
    assert f["SeveridadInicial"] == "Alta"
    assert f["Repeticiones"] == 1
    assert f["FechaEventoUtc"] == "2026-11-04T19:32:05Z"
    assert f["RecibidoUtc"] == "2026-11-04T19:32:06.250Z"
    assert f["EsPrueba"] is False
    assert f["Estado"] == "Nuevo"


def test_types_follow_the_contract():
    f = fields()
    for name, value in f.items():
        kind = CONTRACT.column(name)["type"]
        if kind == "choice":
            assert value in CONTRACT.column(name)["choices"]
        elif kind == "number":
            assert isinstance(value, int) and not isinstance(value, bool) and value >= 1
        elif kind == "dateTime":
            assert ISO_Z.match(value)
        elif kind == "boolean":
            assert isinstance(value, bool)
        else:
            assert isinstance(value, str) and value


def test_test_flag():
    assert fields(is_test=True)["EsPrueba"] is True


def test_repetitions_body():
    assert repetitions_fields(20, CONTRACT) == {"Repeticiones": 20}


@pytest.mark.parametrize(
    "bad",
    [
        {"Desconocida": "x"},
        {"Estado": "Cerrado"},
        {"Repeticiones": 0},
        {"Repeticiones": True},
        {"Repeticiones": "3"},
        {"FechaEventoUtc": "2026-11-04 19:32"},
        {"EsPrueba": "Sí"},
        {"Zona": "Bodega"},
        {"Title": ""},
        {"Decision": "Atender"},  # la escribe PublicarIncidente, no la Function
    ],
)
def test_validation_rejects_values_outside_the_contract(bad):
    with pytest.raises(ContractViolation):
        CONTRACT.validate(bad, writer="function")


def test_validation_requires_all_function_columns_on_create():
    f = fields()
    del f["Sitio"]
    with pytest.raises(ContractViolation, match="Sitio"):
        CONTRACT.validate(f, writer="function", require_all=True)


def test_contract_rejects_unknown_type():
    with pytest.raises(ContractViolation):
        ColumnContract({"list": "x", "columns": [{"name": "A", "type": "lookup", "writers": []}]})
