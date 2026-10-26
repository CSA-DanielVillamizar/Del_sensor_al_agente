"""T-005 HU-01 CA-01.1: el transporte MQTT serializa el evento como JSON UTF-8, sin red."""

import json

from simulator.transport import IoTHubTransport


class FakeDeviceClient:
    def __init__(self) -> None:
        self.connected = False
        self.messages = []
        self.shut_down = False

    def connect(self) -> None:
        self.connected = True

    def send_message(self, message) -> None:
        self.messages.append(message)

    def shutdown(self) -> None:
        self.shut_down = True


def test_sends_json_utf8_message():
    client = FakeDeviceClient()
    transport = IoTHubTransport(client)
    event = {"type": "puerta_forzada", "rawSeverity": "Crítica"}
    transport.send(event)

    assert client.connected
    assert len(client.messages) == 1
    message = client.messages[0]
    assert message.content_type == "application/json"
    assert message.content_encoding == "utf-8"
    assert json.loads(message.data.decode("utf-8")) == event


def test_connects_once_for_several_messages():
    client = FakeDeviceClient()
    transport = IoTHubTransport(client)
    transport.send({"n": 1})
    transport.send({"n": 2})
    assert len(client.messages) == 2


def test_close_shuts_down_client():
    client = FakeDeviceClient()
    transport = IoTHubTransport(client)
    transport.close()
    assert client.shut_down
