"""T-004 HU-05 CA-05.1: el catálogo de zonas es válido, único y ficticio."""

import json
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "schemas" / "zona.schema.json").read_text(encoding="utf-8"))
ZONES = json.loads((ROOT / "data" / "zonas.json").read_text(encoding="utf-8"))


def test_catalog_matches_schema():
    assert list(Draft202012Validator(SCHEMA).iter_errors(ZONES)) == []


def test_zone_codes_and_cameras_are_unique():
    assert len({z["zone"] for z in ZONES}) == len(ZONES)
    assert len({z["cameraId"] for z in ZONES}) == len(ZONES)


def test_sites_are_fictitious():
    # Art. 5: todas las sedes se llaman "Sede Demo ..." para que no identifiquen una instalación real.
    assert all(z["site"].startswith("Sede Demo ") for z in ZONES)


def test_demo_zones_used_by_the_runbook_exist():
    codes = {z["zone"] for z in ZONES}
    assert {"Z-01", "Z-03"} <= codes
