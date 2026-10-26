"""T-008 HU-05 CA-05.1: enriquecimiento con el catálogo de zonas; zona desconocida → rechazo."""

import pytest

from function.core.contracts import load_contracts
from function.core.enrich import UnknownZone, ZoneCatalog, enrich

from .conftest import VALID_EVENT

CATALOG = ZoneCatalog(load_contracts().zones)


def test_adds_zone_name_camera_site_and_initial_severity():
    enriched = enrich(VALID_EVENT, CATALOG)  # Z-03: Bodega norte, base Media; raw Alta
    assert enriched.zone_name == "Bodega norte"
    assert enriched.camera_id == "CAM-03"
    assert enriched.site == "Sede Demo Centro"
    assert enriched.initial_severity == "Alta"
    assert enriched.event_id == VALID_EVENT["eventId"]
    assert enriched.device_id == "DEV-SIM-01"
    assert enriched.type == "puerta_forzada"
    assert enriched.zone == "Z-03"
    assert enriched.raw_severity == "Alta"
    assert enriched.timestamp == "2026-11-04T19:32:05Z"


def test_base_severity_wins_when_higher():
    enriched = enrich({**VALID_EVENT, "zone": "Z-01", "rawSeverity": "Baja"}, CATALOG)
    assert enriched.initial_severity == "Alta"


def test_unknown_zone_is_rejected():
    with pytest.raises(UnknownZone, match="Z-99"):
        enrich({**VALID_EVENT, "zone": "Z-99"}, CATALOG)


def test_catalog_rejects_duplicate_zones():
    zone = {"zone": "Z-01", "zoneName": "A", "cameraId": "CAM-01", "site": "S", "baseSeverity": "Baja"}
    with pytest.raises(ValueError):
        ZoneCatalog([zone, zone])
