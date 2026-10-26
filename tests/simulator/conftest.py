"""Dobles de prueba del simulador: transporte falso sin red y reloj falso (T-005, T-006)."""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "schemas" / "evento-dispositivo.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)

# Valor ficticio, no es una credencial real.
FAKE_CONNECTION_STRING = "HostName=hub-falso.example;DeviceId=sim-01;SharedAccessKey=Y2xhdmVmYWxzYQ=="


class FakeClock:
    """Reloj monotónico falso: avanza solo cuando el transporte lo indica."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class FakeTransport:
    """Transporte que guarda los mensajes en memoria y simula latencia de envío."""

    def __init__(self, clock: FakeClock | None = None, latency: float = 0.0, fail: bool = False) -> None:
        self.sent: list[dict] = []
        self.closed = False
        self.clock = clock
        self.latency = latency
        self.fail = fail

    def send(self, event: dict) -> None:
        if self.fail:
            raise ConnectionError("fallo simulado de red")
        if self.clock is not None:
            self.clock.advance(self.latency)
        self.sent.append(event)

    def close(self) -> None:
        self.closed = True


class TransportFactory:
    """Fábrica que registra la cadena de conexión recibida y entrega el transporte falso."""

    def __init__(self, transport: FakeTransport) -> None:
        self.transport = transport
        self.connection_strings: list[str] = []

    def __call__(self, connection_string: str) -> FakeTransport:
        self.connection_strings.append(connection_string)
        return self.transport


@pytest.fixture
def validator():
    return VALIDATOR


@pytest.fixture
def fake_clock():
    return FakeClock()


@pytest.fixture
def transport():
    return FakeTransport()


@pytest.fixture
def factory(transport):
    return TransportFactory(transport)


@pytest.fixture
def env():
    return {"IOTHUB_DEVICE_CONNECTION_STRING": FAKE_CONNECTION_STRING}


@pytest.fixture
def no_dotenv(tmp_path):
    """Ruta a un .env que no existe, para que las pruebas no lean el .env real del desarrollador."""
    return tmp_path / "no-existe.env"
