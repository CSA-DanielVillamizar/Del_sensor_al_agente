"""T-007 HU-05 CA-05.1 (§5.0): la SeveridadInicial es la mayor entre rawSeverity y la base de la zona."""

import pytest

from function.core.severity import LEVELS, max_severity


def test_scale_has_four_ordered_levels():
    assert LEVELS == ("Baja", "Media", "Alta", "Crítica")


@pytest.mark.parametrize(
    "raw,base,expected",
    [
        ("Baja", "Baja", "Baja"),
        ("Baja", "Alta", "Alta"),
        ("Alta", "Media", "Alta"),
        ("Media", "Crítica", "Crítica"),
        ("Crítica", "Baja", "Crítica"),
    ],
)
def test_initial_severity_is_the_highest(raw, base, expected):
    assert max_severity(raw, base) == expected


def test_unknown_level_raises():
    with pytest.raises(ValueError):
        max_severity("Urgente", "Baja")
