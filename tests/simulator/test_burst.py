"""T-006 HU-02 CA-02.1: la ráfaga envía N mensajes del mismo deviceId y tipo en menos de 10 s."""

from simulator.cli import BURST_MAX, EXIT_OK, main, send_events
from simulator.message import build_event

from .conftest import FakeTransport, TransportFactory


def test_burst_of_20_same_device_and_type_under_10_seconds(env, no_dotenv, fake_clock, validator, capsys):
    # Latencia simulada de 0,3 s por mensaje, mayor que la típica de MQTT con IoT Hub.
    transport = FakeTransport(clock=fake_clock, latency=0.3)
    argv = ["--type", "movimiento_zona_restringida", "--zone", "Z-01", "--burst", "20"]
    start = fake_clock()
    code = main(
        argv,
        transport_factory=TransportFactory(transport),
        environ=env,
        dotenv_path=no_dotenv,
        clock=fake_clock,
    )
    elapsed = fake_clock() - start

    assert code == EXIT_OK
    assert len(transport.sent) == 20
    assert {e["deviceId"] for e in transport.sent} == {"DEV-SIM-01"}
    assert {e["type"] for e in transport.sent} == {"movimiento_zona_restringida"}
    assert len({e["eventId"] for e in transport.sent}) == 20
    assert all(list(validator.iter_errors(e)) == [] for e in transport.sent)
    assert elapsed < 10
    assert "20" in capsys.readouterr().out


def test_burst_uses_a_single_connection(env, no_dotenv):
    transport = FakeTransport()
    factory = TransportFactory(transport)
    main(
        ["--type", "puerta_forzada", "--zone", "Z-03", "--burst", "5"],
        transport_factory=factory,
        environ=env,
        dotenv_path=no_dotenv,
    )
    assert len(factory.connection_strings) == 1
    assert len(transport.sent) == 5
    assert transport.closed


def test_burst_max_is_accepted(env, no_dotenv):
    transport = FakeTransport()
    code = main(
        ["--type", "puerta_forzada", "--zone", "Z-03", "--burst", str(BURST_MAX)],
        transport_factory=TransportFactory(transport),
        environ=env,
        dotenv_path=no_dotenv,
    )
    assert code == EXIT_OK
    assert len(transport.sent) == BURST_MAX


def test_send_events_reports_elapsed_time(fake_clock):
    transport = FakeTransport(clock=fake_clock, latency=0.25)
    events = [build_event("puerta_forzada", "Z-03", "DEV-SIM-01") for _ in range(4)]
    elapsed = send_events(events, transport, clock=fake_clock)
    assert elapsed == 1.0
    assert transport.sent == events
