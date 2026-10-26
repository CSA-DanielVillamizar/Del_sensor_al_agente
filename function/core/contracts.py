"""Carga de los contratos que la Function necesita en tiempo de ejecución.

Archivos (misma ruta relativa que en el repositorio, que es la única fuente):
- `schemas/evento-dispositivo.schema.json`: esquema del evento (plan §4.1).
- `schemas/zona.schema.json` y `data/zonas.json`: catálogo de zonas ficticio (plan §4.2).
- `sharepoint/columnas.json`: contrato de columnas de la lista (plan §4.3).

Dónde se buscan, en este orden:
1. La carpeta de la variable de entorno `DSA_CONTRACTS_DIR`, si está definida.
2. `function/_contracts/`, si existe. **El script de despliegue copia ahí los archivos de arriba,
   con su misma ruta relativa, al empaquetar `function/`**, porque la Function se publica solo
   desde esa carpeta. `_contracts/` es un artefacto de empaquetado: no se edita ni se versiona.
3. La raíz del repositorio (ejecución local y pruebas).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

EVENT_SCHEMA = "schemas/evento-dispositivo.schema.json"
ZONE_SCHEMA = "schemas/zona.schema.json"
ZONES = "data/zonas.json"
COLUMNS = "sharepoint/columnas.json"
CONTRACT_FILES: tuple[str, ...] = (EVENT_SCHEMA, ZONE_SCHEMA, ZONES, COLUMNS)

FUNCTION_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = FUNCTION_DIR.parent
PACKAGED_DIR = FUNCTION_DIR / "_contracts"


class ContractsError(Exception):
    """Falta un contrato o no es válido; la Function no puede arrancar."""


@dataclass(frozen=True)
class Contracts:
    event_validator: Draft202012Validator
    zones: list[dict[str, Any]]
    columns: dict[str, Any]


def resolve_contracts_dir() -> Path:
    env = os.environ.get("DSA_CONTRACTS_DIR")
    if env:
        return Path(env)
    if PACKAGED_DIR.is_dir():
        return PACKAGED_DIR
    return REPO_ROOT


def _read_json(base: Path, rel: str) -> Any:
    path = base / rel
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ContractsError(f"Falta el contrato {rel} en {base}") from None
    except json.JSONDecodeError as exc:
        raise ContractsError(f"El contrato {rel} no es JSON válido: línea {exc.lineno}") from None


def load_contracts(base: Path | None = None) -> Contracts:
    base = base or resolve_contracts_dir()
    event_schema = _read_json(base, EVENT_SCHEMA)
    zone_schema = _read_json(base, ZONE_SCHEMA)
    zones = _read_json(base, ZONES)
    columns = _read_json(base, COLUMNS)

    Draft202012Validator.check_schema(event_schema)
    if any(True for _ in Draft202012Validator(zone_schema).iter_errors(zones)):
        raise ContractsError(f"El catálogo {ZONES} no cumple {ZONE_SCHEMA}")
    if not isinstance(columns, dict) or not isinstance(columns.get("columns"), list):
        raise ContractsError(f"El contrato {COLUMNS} no tiene la lista 'columns'")

    return Contracts(event_validator=Draft202012Validator(event_schema), zones=zones, columns=columns)
