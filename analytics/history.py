"""Histórico ficticio de incidentes para la charla de IA DAY (T-061, HU-16, CA-16.1, CA-16.4).

Genera N días de incidentes coherentes con el pipeline de la demo: mismas zonas (`data/zonas.json`),
mismos tipos de evento y severidad base del simulador, la misma regla de severidad inicial
(máximo entre la severidad del evento y la de la zona) y la misma regla de horario del agente
(fuera de 06:00-18:00 en America/Bogota sube un nivel, nunca más de uno).

Es determinista: la misma semilla y la misma fecha final producen exactamente el mismo archivo.
No contiene datos personales: quien decide es un turno ficticio, no una persona (artículo 5).

Incluye a propósito una anomalía para la demo: en los últimos 5 días se disparan los accesos
denegados en el Archivo documental (Z-05). La consulta KQL de anomalías y el agente la deben encontrar.

Uso:
    python -m analytics.history --days 30 --end 2026-11-26 --out analytics/out/historico.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import uuid
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path

from function.core.severity import LEVELS, max_severity

REPO_ROOT = Path(__file__).resolve().parent.parent
ZONES_FILE = REPO_ROOT / "data" / "zonas.json"
# Colombia no tiene horario de verano: UTC-5 fijo, sin depender de la base tzdata (ausente en Windows).
BOGOTA = timezone(timedelta(hours=-5), "America/Bogota")

# Mismos valores que simulator/message.py.
EVENT_SEVERITY = {
    "movimiento_zona_restringida": "Media",
    "puerta_forzada": "Alta",
    "acceso_denegado_repetido": "Media",
}
# Peso relativo de cada tipo en un día normal.
EVENT_WEIGHTS = {"movimiento_zona_restringida": 5, "puerta_forzada": 1, "acceso_denegado_repetido": 3}
DECISIONS = ("Atender", "Escalar a autoridades", "Falsa alarma")
SHIFTS = ("Turno A", "Turno B", "Turno C")
ANOMALY_ZONE = "Z-05"
ANOMALY_TYPE = "acceso_denegado_repetido"
ANOMALY_DAYS = 5

FIELDS = (
    "eventId",
    "fechaUtc",
    "horaLocal",
    "zona",
    "nombreZona",
    "sitio",
    "tipoEvento",
    "severidadInicial",
    "severidadPropuesta",
    "fueraDeHorario",
    "repeticiones",
    "decision",
    "decididoPor",
    "minutosHastaDecision",
    "estado",
)


@dataclass(frozen=True)
class Incident:
    eventId: str  # noqa: N815 - nombres de columna del contrato
    fechaUtc: str  # noqa: N815
    horaLocal: str  # noqa: N815
    zona: str
    nombreZona: str  # noqa: N815
    sitio: str
    tipoEvento: str  # noqa: N815
    severidadInicial: str  # noqa: N815
    severidadPropuesta: str  # noqa: N815
    fueraDeHorario: bool  # noqa: N815
    repeticiones: int
    decision: str
    decididoPor: str  # noqa: N815
    minutosHastaDecision: int | None  # noqa: N815
    estado: str


def load_zones(path: Path = ZONES_FILE) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))


def is_off_hours(local: datetime) -> bool:
    """Regla de horario del agente: fuera de 06:00-18:00 hora de Bogotá."""
    return not (6 <= local.hour < 18)


def proposed_severity(initial: str, off_hours: bool) -> str:
    """Sube un nivel fuera de horario y nunca más de uno (REGLA-HORARIO)."""
    if not off_hours:
        return initial
    return LEVELS[min(LEVELS.index(initial) + 1, len(LEVELS) - 1)]


def _pick_type(rng: random.Random) -> str:
    types = list(EVENT_WEIGHTS)
    return rng.choices(types, weights=[EVENT_WEIGHTS[t] for t in types], k=1)[0]


def _decide(rng: random.Random, severity: str) -> tuple[str, str, int | None, str]:
    """Decisión ficticia: más escalamientos cuanto más severo; 1 de cada 20 queda sin respuesta."""
    if rng.random() < 0.05:
        return "", "", None, "Sin respuesta"
    idx = LEVELS.index(severity)
    weights = {
        "Atender": 6,
        "Escalar a autoridades": 1 + 2 * idx,
        "Falsa alarma": max(1, 5 - 2 * idx),
    }
    decision = rng.choices(list(weights), weights=list(weights.values()), k=1)[0]
    minutes = max(1, int(rng.gauss(6 - idx, 2)))
    return decision, rng.choice(SHIFTS), minutes, "Decidido"


def generate(days: int = 30, end: date | None = None, seed: int = 27) -> list[Incident]:
    """Genera los incidentes de los `days` días que terminan en `end` (incluido)."""
    if days < 1:
        raise ValueError("days debe ser al menos 1")
    end = end or date(2026, 11, 26)
    rng = random.Random(seed)  # noqa: S311 - datos ficticios, no criptografía
    zones = load_zones()
    zone_by_id = {z["zone"]: z for z in zones}
    incidents: list[Incident] = []
    first = end - timedelta(days=days - 1)
    for offset in range(days):
        day = first + timedelta(days=offset)
        planned: list[tuple[str, str]] = []
        for _ in range(rng.randint(3, 7)):
            planned.append((rng.choice(zones)["zone"], _pick_type(rng)))
        if offset >= days - ANOMALY_DAYS:
            planned.extend((ANOMALY_ZONE, ANOMALY_TYPE) for _ in range(rng.randint(6, 9)))
        for zone_id, event_type in planned:
            zone = zone_by_id[zone_id]
            local = datetime(day.year, day.month, day.day, tzinfo=BOGOTA) + timedelta(
                minutes=rng.randint(0, 24 * 60 - 1)
            )
            initial = max_severity(EVENT_SEVERITY[event_type], zone["baseSeverity"])
            off_hours = is_off_hours(local)
            proposed = proposed_severity(initial, off_hours)
            repetitions = 1 if rng.random() < 0.8 else rng.randint(2, 25)
            decision, by, minutes, state = _decide(rng, proposed)
            incidents.append(
                Incident(
                    eventId=str(uuid.UUID(int=rng.getrandbits(128), version=4)),
                    fechaUtc=local.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    horaLocal=local.strftime("%H:%M"),
                    zona=zone_id,
                    nombreZona=zone["zoneName"],
                    sitio=zone["site"],
                    tipoEvento=event_type,
                    severidadInicial=initial,
                    severidadPropuesta=proposed,
                    fueraDeHorario=off_hours,
                    repeticiones=repetitions,
                    decision=decision,
                    decididoPor=by,
                    minutosHastaDecision=minutes,
                    estado=state,
                )
            )
    incidents.sort(key=lambda i: i.fechaUtc)
    return incidents


def write_csv(incidents: list[Incident], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for incident in incidents:
            row = asdict(incident)
            row["fueraDeHorario"] = "true" if incident.fueraDeHorario else "false"
            minutes = incident.minutosHastaDecision
            row["minutosHastaDecision"] = "" if minutes is None else minutes
            writer.writerow(row)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Genera el histórico ficticio de incidentes de IA DAY.")
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--end", type=date.fromisoformat, default=date(2026, 11, 26))
    parser.add_argument("--seed", type=int, default=27)
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "analytics" / "out" / "historico.csv")
    args = parser.parse_args(argv)
    incidents = generate(days=args.days, end=args.end, seed=args.seed)
    write_csv(incidents, args.out)
    print(f"{len(incidents)} incidentes ficticios de {args.days} días en {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
