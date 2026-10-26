"""T-010 HU-12 CA-12.1: como máximo N incidentes creados por minuto (por defecto 10).

Que las repeticiones no consumen cupo y que lo descartado se registra se prueba en
`test_orchestration.py`, donde vive esa decisión.
"""

from datetime import timedelta

import pytest

from function.core.dedup import ConcurrencyExhausted
from function.core.ratelimit import DEFAULT_MAX_PER_MINUTE, TABLE, RateLimiter, minute_key

from .conftest import T0, InMemoryTableStore


@pytest.fixture
def store():
    return InMemoryTableStore()


def test_default_is_ten():
    assert DEFAULT_MAX_PER_MINUTE == 10


def test_minute_key_format():
    assert minute_key(T0) == "202611041932"


def test_eleventh_incident_of_the_minute_is_refused(store):
    limiter = RateLimiter(store)
    results = [limiter.try_take(T0 + timedelta(seconds=i)) for i in range(11)]
    assert results == [True] * 10 + [False]
    assert store.get(TABLE, "minute", "202611041932")[0]["count"] == 10


def test_next_minute_has_a_fresh_quota(store):
    limiter = RateLimiter(store, max_per_minute=1)
    assert limiter.try_take(T0)
    assert not limiter.try_take(T0)
    assert limiter.try_take(T0 + timedelta(minutes=1))


def test_limit_is_configurable(store):
    limiter = RateLimiter(store, max_per_minute=2)
    assert [limiter.try_take(T0) for _ in range(3)] == [True, True, False]


def test_rejects_non_positive_limit(store):
    with pytest.raises(ValueError):
        RateLimiter(store, max_per_minute=0)


def test_insert_conflict_is_retried(store):
    limiter = RateLimiter(store, max_per_minute=10)
    store.before_insert.append(lambda s: RateLimiter(s).try_take(T0))  # otra instancia toma el primero
    assert limiter.try_take(T0)
    assert store.get(TABLE, "minute", minute_key(T0))[0]["count"] == 2


def test_etag_conflict_is_retried(store):
    limiter = RateLimiter(store, max_per_minute=10)
    limiter.try_take(T0)
    store.before_update.append(lambda s: RateLimiter(s).try_take(T0))
    assert limiter.try_take(T0)
    assert store.get(TABLE, "minute", minute_key(T0))[0]["count"] == 3


def test_loop_is_bounded(store):
    limiter = RateLimiter(store, max_attempts=3)
    limiter.try_take(T0)

    def bump(s):
        entity, _ = s.get(TABLE, "minute", minute_key(T0))
        s.force_put(TABLE, entity)

    store.before_update.extend([bump] * 5)
    with pytest.raises(ConcurrencyExhausted):
        limiter.try_take(T0)
