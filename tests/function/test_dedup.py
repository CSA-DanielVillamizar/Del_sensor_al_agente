"""T-009 HU-05 CA-05.2, HU-02 CA-02.2: ventana fija de 60 s en un repositorio en memoria (ADR-006)."""

from datetime import timedelta

import pytest

from function.core.dedup import ConcurrencyExhausted, DedupWindow, WindowReplaced

from .conftest import T0, InMemoryTableStore, event_id

DEV, TYPE = "DEV-SIM-01", "movimiento_zona_restringida"


def claim(window, n, seconds=0.0, device=DEV, type_=TYPE):
    return window.claim(
        event_id=event_id(n), device_id=device, type=type_, enqueued_utc=T0 + timedelta(seconds=seconds)
    )


@pytest.fixture
def store():
    return InMemoryTableStore()


@pytest.fixture
def window(store):
    return DedupWindow(store)


def test_first_event_opens_a_window(window):
    c = claim(window, 1)
    assert c.kind == "opened"
    assert c.is_opener
    assert not c.redelivery
    assert c.window.window_id == event_id(1)
    assert c.window.state == "open"
    assert c.window.item_id is None
    assert not c.window.flow_triggered
    assert not c.window.quota_taken


def test_burst_of_20_gives_one_incident_with_20_repetitions(window):
    # CA-02.2: 20 eventos en menos de 10 s → un incidente, Repeticiones = 20.
    kinds = [claim(window, n, seconds=n * 0.4).kind for n in range(1, 21)]
    assert kinds.count("opened") == 1
    assert kinds.count("repetition") == 19
    assert window.repetitions(event_id(1)) == 20


def test_event_at_60_seconds_opens_another_window(window):
    claim(window, 1, seconds=0)
    assert claim(window, 2, seconds=59.9).kind == "repetition"
    c = claim(window, 3, seconds=60)
    assert c.kind == "opened"
    assert c.window.window_id == event_id(3)
    assert window.repetitions(event_id(1)) == 2
    assert window.repetitions(event_id(3)) == 1


def test_window_is_fixed_not_sliding(window):
    # Cada repetición no extiende la ventana: cuenta desde el primer evento.
    claim(window, 1, seconds=0)
    claim(window, 2, seconds=50)
    assert claim(window, 3, seconds=65).kind == "opened"


def test_different_device_or_type_has_its_own_window(window):
    claim(window, 1)
    assert claim(window, 2, type_="puerta_forzada").kind == "opened"
    assert claim(window, 3, device="DEV-SIM-02").kind == "opened"


def test_redelivery_of_a_repetition_is_not_counted_twice(window):
    claim(window, 1)
    claim(window, 2, seconds=5)
    again = claim(window, 2, seconds=5)
    assert again.kind == "repetition"
    assert again.redelivery
    assert window.repetitions(event_id(1)) == 2


def test_redelivery_of_the_opener_keeps_the_window(window):
    claim(window, 1)
    again = claim(window, 1)
    assert again.kind == "opened"
    assert again.is_opener
    assert again.redelivery
    assert window.repetitions(event_id(1)) == 1


def test_late_event_from_a_closed_window_is_ignored(window):
    claim(window, 1, seconds=0)
    claim(window, 2, seconds=70)  # abre otra ventana
    late = claim(window, 3, seconds=30)  # llega tarde, su ventana ya se cerró
    assert late.kind == "late"
    assert window.repetitions(event_id(2)) == 1


def test_insert_conflict_rereads_and_becomes_repetition(store, window):
    # Otra instancia crea la cabecera justo antes que nosotros (409) → se relee.
    other = DedupWindow(store)
    store.before_insert.append(
        lambda s: other.claim(event_id=event_id(9), device_id=DEV, type=TYPE, enqueued_utc=T0)
    )
    c = claim(window, 1, seconds=1)
    assert c.kind == "repetition"
    assert c.window.window_id == event_id(9)


def test_replace_conflict_is_retried(store, window):
    claim(window, 1, seconds=0)
    other = DedupWindow(store)
    # Al ir a reemplazar la ventana vencida, otra instancia ya la reemplazó (412) → se relee.
    store.before_update.append(
        lambda s: other.claim(
            event_id=event_id(8), device_id=DEV, type=TYPE, enqueued_utc=T0 + timedelta(seconds=61)
        )
    )
    c = claim(window, 2, seconds=62)
    assert c.kind == "repetition"
    assert c.window.window_id == event_id(8)


def test_concurrency_loop_is_bounded(store):
    window = DedupWindow(store, max_attempts=5)

    def conflict(s):
        # Cada inserción encuentra una cabecera que desaparece al releer.
        s.tables.setdefault("dedup", {})[(f"{DEV}|{TYPE}", "current")] = ({"x": 1}, "e")

    original_get = store.get
    store.get = lambda t, pk, rk: None if rk == "current" else original_get(t, pk, rk)
    store.before_insert.extend([conflict] * 10)
    with pytest.raises(ConcurrencyExhausted):
        claim(window, 1)


def test_update_header_merges_changes(window):
    c = claim(window, 1)
    header = window.update(c.window, DEV, TYPE, item_id="17", quota_taken=True)
    assert header.item_id == "17"
    assert header.quota_taken
    header = window.update(header, DEV, TYPE, flow_triggered=True, state="discarded")
    again = claim(window, 1)
    assert again.window.item_id == "17"
    assert again.window.flow_triggered
    assert again.window.state == "discarded"


def test_update_retries_on_etag_conflict(store, window):
    c = claim(window, 1)
    # Otra instancia toca la cabecera (mismo windowId) entre la lectura y la escritura.
    store.before_update.append(lambda s: DedupWindow(s).update(c.window, DEV, TYPE, quota_taken=True))
    header = window.update(c.window, DEV, TYPE, item_id="5")
    assert header.item_id == "5"
    assert header.quota_taken


def test_update_fails_if_window_was_replaced(store, window):
    c = claim(window, 1)
    claim(window, 2, seconds=61)
    with pytest.raises(WindowReplaced):
        window.update(c.window, DEV, TYPE, item_id="5")


def test_rows_only_store_ids_and_times(store, window):
    # Art. 4: las entidades solo guardan deviceId, type, eventId y horas.
    claim(window, 1)
    for (_pk, _rk), (entity, _etag) in store.tables["dedup"].items():
        assert set(entity) <= {
            "PartitionKey",
            "RowKey",
            "windowId",
            "windowStartUtc",
            "state",
            "itemId",
            "flowTriggered",
            "quotaTaken",
            "enqueuedTimeUtc",
        }
