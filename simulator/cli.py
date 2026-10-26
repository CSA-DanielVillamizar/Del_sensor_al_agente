"""CLI del simulador de dispositivos (T-005 HU-01, T-006 HU-02).

Uso: python -m simulator --type <tipo> --zone Z-03 [--burst N] [--device DEV-SIM-01] [--severity Alta]

Códigos de salida: 0 envío correcto, 1 fallo de envío, 2 argumentos no válidos, 3 falta configuración.
"""

import argparse
import os
import re
import sys
import time
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path

from dotenv import dotenv_values

from simulator.message import EVENT_TYPES, SEVERITIES, EventValidationError, build_event, validate_event
from simulator.transport import IoTHubTransport, Transport

EXIT_OK = 0
EXIT_SEND_FAILED = 1
EXIT_USAGE = 2
EXIT_CONFIG = 3

CONNECTION_STRING_VAR = "IOTHUB_DEVICE_CONNECTION_STRING"
DEFAULT_DEVICE = "DEV-SIM-01"
BURST_MAX = 100

ZONE_PATTERN = re.compile(r"^Z-\d{2}$")
DEVICE_PATTERN = re.compile(r"^DEV-[A-Z0-9-]+$")
DEVICE_MAX_LENGTH = 32

TransportFactory = Callable[[str], Transport]


class UsageError(Exception):
    """Argumentos no válidos: termina con código 2."""


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        if message.startswith("unrecognized arguments:"):
            message = "Opción no reconocida:" + message.removeprefix("unrecognized arguments:")
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog="simulate",
        description="Envía eventos ficticios de seguridad física a IoT Hub.",
        epilog=f"La cadena de conexión se lee de {CONNECTION_STRING_VAR} (entorno o archivo .env).",
    )
    parser.add_argument("--type", dest="event_type", help="Tipo de evento: " + ", ".join(EVENT_TYPES))
    parser.add_argument("--zone", help="Zona del catálogo, por ejemplo Z-03")
    parser.add_argument("--burst", default="1", help=f"Número de mensajes que se envían (1 a {BURST_MAX})")
    parser.add_argument(
        "--device", default=DEFAULT_DEVICE, help=f"Identificador del dispositivo ({DEFAULT_DEVICE})"
    )
    parser.add_argument("--severity", help="Severidad reportada: " + ", ".join(SEVERITIES))
    return parser


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Interpreta y valida los argumentos; lanza `UsageError` con un mensaje en español."""
    args = build_parser().parse_args(argv)

    if args.event_type is None:
        raise UsageError("Falta el argumento obligatorio --type.")
    if args.event_type not in EVENT_TYPES:
        raise UsageError(
            f"Tipo de evento no válido: '{args.event_type}'. Tipos admitidos: {', '.join(EVENT_TYPES)}."
        )
    if args.zone is None:
        raise UsageError("Falta el argumento obligatorio --zone.")
    if not ZONE_PATTERN.match(args.zone):
        raise UsageError(f"Zona no válida: '{args.zone}'. Usa el formato Z-NN, por ejemplo Z-03.")
    if not DEVICE_PATTERN.match(args.device) or len(args.device) > DEVICE_MAX_LENGTH:
        raise UsageError(
            f"Dispositivo no válido: '{args.device}'. Usa el formato DEV-XXX (mayúsculas, dígitos y guiones, "
            f"máximo {DEVICE_MAX_LENGTH} caracteres)."
        )
    if args.severity is not None and args.severity not in SEVERITIES:
        raise UsageError(
            f"Severidad no válida: '{args.severity}'. Valores admitidos: {', '.join(SEVERITIES)}."
        )
    try:
        burst = int(args.burst)
    except ValueError:
        burst = 0
    if not 1 <= burst <= BURST_MAX:
        raise UsageError(f"--burst debe ser un entero entre 1 y {BURST_MAX}; se recibió '{args.burst}'.")
    args.burst = burst
    return args


def load_connection_string(environ: Mapping[str, str], dotenv_path: Path) -> str | None:
    """Lee la cadena del entorno y, si falta, del archivo .env. No modifica el entorno."""
    value = environ.get(CONNECTION_STRING_VAR, "").strip()
    if not value and dotenv_path.is_file():
        value = (dotenv_values(dotenv_path).get(CONNECTION_STRING_VAR) or "").strip()
    return value or None


def send_events(
    events: Iterable[dict], transport: Transport, clock: Callable[[], float] = time.monotonic
) -> float:
    """Envía los eventos uno tras otro, sin pausas, y devuelve los segundos transcurridos."""
    start = clock()
    for event in events:
        transport.send(event)
    return clock() - start


def main(
    argv: list[str] | None = None,
    transport_factory: TransportFactory = IoTHubTransport.from_connection_string,
    environ: Mapping[str, str] | None = None,
    dotenv_path: Path | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
    except UsageError as error:
        print(f"simulate: error: {error}", file=sys.stderr)
        print("Ejecuta 'python -m simulator --help' para ver las opciones.", file=sys.stderr)
        return EXIT_USAGE
    except SystemExit as exit_request:  # --help
        return int(exit_request.code or 0)

    # Todos los eventos se arman y validan antes de abrir la conexión (CA-01.1).
    events = [build_event(args.event_type, args.zone, args.device, args.severity) for _ in range(args.burst)]
    try:
        for event in events:
            validate_event(event)
    except EventValidationError as error:
        print(f"simulate: error: {error}", file=sys.stderr)
        return EXIT_USAGE

    connection_string = load_connection_string(
        os.environ if environ is None else environ, dotenv_path or Path.cwd() / ".env"
    )
    if connection_string is None:
        print(
            f"simulate: error: falta la variable {CONNECTION_STRING_VAR}. Defínela en el entorno o en un "
            "archivo .env no versionado (copia .env.example).",
            file=sys.stderr,
        )
        return EXIT_CONFIG

    transport: Transport | None = None
    try:
        transport = transport_factory(connection_string)
        elapsed = send_events(events, transport, clock)
    # Se informa solo el tipo del error, nunca el detalle, que podría incluir la cadena de conexión.
    except Exception as error:  # noqa: BLE001
        print(
            f"simulate: error: No se pudo enviar a IoT Hub ({type(error).__name__}). "
            f"Revisa la red y la cadena de conexión en {CONNECTION_STRING_VAR}.",
            file=sys.stderr,
        )
        return EXIT_SEND_FAILED
    finally:
        if transport is not None:
            try:
                transport.close()
            except Exception:  # noqa: BLE001, S110 - el cierre no debe ocultar el resultado del envío
                pass

    first = events[0]
    print(
        f"Enviados {len(events)} evento(s) {first['type']} desde {first['deviceId']} en {first['zone']} "
        f"(severidad {first['rawSeverity']}) en {elapsed:.2f} s."
    )
    for event in events:
        print(f"  eventId {event['eventId']}")
    return EXIT_OK
