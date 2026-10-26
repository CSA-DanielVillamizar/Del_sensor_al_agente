"""Modelo de severidad común (especificación §5.0)."""

from __future__ import annotations

LEVELS: tuple[str, ...] = ("Baja", "Media", "Alta", "Crítica")


def level_index(level: str) -> int:
    try:
        return LEVELS.index(level)
    except ValueError:
        raise ValueError(f"Severidad fuera de la escala: {level!r}") from None


def max_severity(raw: str, base: str) -> str:
    """SeveridadInicial: el mayor entre `rawSeverity` del evento y la severidad base de la zona."""
    return LEVELS[max(level_index(raw), level_index(base))]
