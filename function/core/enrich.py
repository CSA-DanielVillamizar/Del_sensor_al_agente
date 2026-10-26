"""Paso 4 de ADR-004: enriquecer el evento con el catálogo de zonas (CA-05.1). Sin E/S."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any

from .severity import max_severity


class UnknownZone(Exception):
    """La zona no está en el catálogo: se trata como evento inválido (plan §4.2)."""


@dataclass(frozen=True)
class EnrichedEvent:
    event_id: str
    device_id: str
    type: str
    zone: str
    timestamp: str
    raw_severity: str
    zone_name: str
    camera_id: str
    site: str
    initial_severity: str


class ZoneCatalog:
    def __init__(self, zones: Iterable[Mapping[str, Any]]) -> None:
        self._zones: dict[str, Mapping[str, Any]] = {}
        for zone in zones:
            code = zone["zone"]
            if code in self._zones:
                raise ValueError(f"Zona duplicada en el catálogo: {code}")
            self._zones[code] = zone

    def get(self, code: str) -> Mapping[str, Any]:
        try:
            return self._zones[code]
        except KeyError:
            raise UnknownZone(f"Zona fuera del catálogo: {code}") from None


def enrich(event: Mapping[str, Any], catalog: ZoneCatalog) -> EnrichedEvent:
    zone = catalog.get(event["zone"])
    return EnrichedEvent(
        event_id=event["eventId"],
        device_id=event["deviceId"],
        type=event["type"],
        zone=event["zone"],
        timestamp=event["timestamp"],
        raw_severity=event["rawSeverity"],
        zone_name=zone["zoneName"],
        camera_id=zone["cameraId"],
        site=zone["site"],
        initial_severity=max_severity(event["rawSeverity"], zone["baseSeverity"]),
    )
