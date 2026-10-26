"""Límite de incidentes creados por minuto en Table Storage (ADR-006, CA-12.1).

Ventanas fijas de reloj (`yyyyMMddHHmm` UTC de procesamiento): en el cambio de minuto pueden
crearse hasta 2N incidentes en 60 s; ADR-006 lo acepta para la demo.
"""

from __future__ import annotations

from datetime import UTC, datetime

from .dedup import ConcurrencyExhausted
from .ports import EntityExists, EtagMismatch, TableStore

TABLE = "ratelimit"
PARTITION = "minute"
DEFAULT_MAX_PER_MINUTE = 10


def minute_key(now_utc: datetime) -> str:
    return now_utc.astimezone(UTC).strftime("%Y%m%d%H%M")


class RateLimiter:
    def __init__(
        self, store: TableStore, *, max_per_minute: int = DEFAULT_MAX_PER_MINUTE, max_attempts: int = 5
    ) -> None:
        if max_per_minute < 1:
            raise ValueError("max_per_minute debe ser al menos 1")
        self._store = store
        self._max = max_per_minute
        self._max_attempts = max_attempts

    def try_take(self, now_utc: datetime) -> bool:
        """Toma un cupo del minuto. Devuelve False si ya no quedan."""
        rk = minute_key(now_utc)
        for _ in range(self._max_attempts):
            found = self._store.get(TABLE, PARTITION, rk)
            if found is None:
                try:
                    self._store.insert(TABLE, {"PartitionKey": PARTITION, "RowKey": rk, "count": 1})
                except EntityExists:
                    continue
                return True
            entity, etag = found
            count = int(entity.get("count", 0))
            if count >= self._max:
                return False
            try:
                self._store.update(TABLE, {"PartitionKey": PARTITION, "RowKey": rk, "count": count + 1}, etag)
            except EtagMismatch:
                continue
            return True
        raise ConcurrencyExhausted(f"ratelimit: {self._max_attempts} intentos sin tomar cupo")
