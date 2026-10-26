"""Transporte del simulador hacia IoT Hub (T-005, HU-01, CA-01.1).

La CLI depende solo de la interfaz `Transport`; las pruebas usan un transporte falso sin red.
"""

import json
from typing import Any, Protocol


class Transport(Protocol):
    """Interfaz mínima: enviar un evento y cerrar la conexión."""

    def send(self, event: dict) -> None: ...

    def close(self) -> None: ...


class IoTHubTransport:
    """Envía eventos como mensajes de dispositivo a IoT Hub con `azure-iot-device` (MQTT)."""

    def __init__(self, client: Any) -> None:
        self._client = client
        self._connected = False

    @classmethod
    def from_connection_string(cls, connection_string: str) -> "IoTHubTransport":
        # Importación diferida: las pruebas no necesitan cargar el SDK ni abrir conexiones.
        from azure.iot.device import IoTHubDeviceClient

        # MQTT es el protocolo por defecto del cliente de dispositivo.
        return cls(IoTHubDeviceClient.create_from_connection_string(connection_string))

    def send(self, event: dict) -> None:
        from azure.iot.device import Message

        if not self._connected:
            self._client.connect()
            self._connected = True
        payload = json.dumps(event, ensure_ascii=False).encode("utf-8")
        # content_type y content_encoding permiten que el enrutamiento de IoT Hub lea el cuerpo como JSON.
        message = Message(payload, content_encoding="utf-8", content_type="application/json")
        self._client.send_message(message)

    def close(self) -> None:
        self._client.shutdown()
