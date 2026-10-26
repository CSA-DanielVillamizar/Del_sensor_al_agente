"""T-005 HU-01 CA-01.1, CA-01.2, CA-01.4: CLI del simulador, validación de argumentos y configuración."""

import pytest

from simulator.cli import (
    EXIT_CONFIG,
    EXIT_OK,
    EXIT_SEND_FAILED,
    EXIT_USAGE,
    load_connection_string,
    main,
)

from .conftest import FAKE_CONNECTION_STRING, FakeTransport, TransportFactory


def run(argv, factory, env, dotenv_path):
    return main(argv, transport_factory=factory, environ=env, dotenv_path=dotenv_path)


# --- Envío válido (CA-01.1) ---


def test_sends_one_valid_message(factory, transport, env, no_dotenv, validator):
    code = run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, env, no_dotenv)
    assert code == EXIT_OK
    assert len(transport.sent) == 1
    event = transport.sent[0]
    assert list(validator.iter_errors(event)) == []
    assert event["type"] == "puerta_forzada"
    assert event["zone"] == "Z-03"
    assert event["deviceId"] == "DEV-SIM-01"
    assert transport.closed


def test_device_and_severity_options(factory, transport, env, no_dotenv):
    argv = [
        "--type",
        "acceso_denegado_repetido",
        "--zone",
        "Z-05",
        "--device",
        "DEV-SIM-02",
        "--severity",
        "Alta",
    ]
    assert run(argv, factory, env, no_dotenv) == EXIT_OK
    assert transport.sent[0]["deviceId"] == "DEV-SIM-02"
    assert transport.sent[0]["rawSeverity"] == "Alta"


def test_output_does_not_leak_connection_string(factory, env, no_dotenv, capsys):
    run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, env, no_dotenv)
    out = capsys.readouterr()
    assert "SharedAccessKey" not in out.out + out.err
    assert FAKE_CONNECTION_STRING not in out.out + out.err


# --- Validación de argumentos (CA-01.2) ---


def test_invalid_type_exits_2_with_clear_message(factory, transport, env, no_dotenv, capsys):
    code = run(["--type", "incendio", "--zone", "Z-03"], factory, env, no_dotenv)
    assert code == EXIT_USAGE == 2
    err = capsys.readouterr().err
    assert "incendio" in err
    assert "Tipo de evento no válido" in err
    for valid in ("movimiento_zona_restringida", "puerta_forzada", "acceso_denegado_repetido"):
        assert valid in err
    assert transport.sent == []
    assert factory.connection_strings == []


@pytest.mark.parametrize(
    "argv, fragment",
    [
        (["--zone", "Z-03"], "--type"),
        (["--type", "puerta_forzada"], "--zone"),
        (["--type", "puerta_forzada", "--zone", "Bodega"], "Zona no válida"),
        (["--type", "puerta_forzada", "--zone", "Z-3"], "Zona no válida"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--device", "Juan Perez"], "Dispositivo no válido"),
        (
            ["--type", "puerta_forzada", "--zone", "Z-03", "--device", "DEV-" + "A" * 40],
            "Dispositivo no válido",
        ),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--severity", "Urgente"], "Severidad no válida"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--burst", "0"], "--burst"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--burst", "-5"], "--burst"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--burst", "101"], "--burst"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--burst", "veinte"], "--burst"),
        (["--type", "puerta_forzada", "--zone", "Z-03", "--opcion-rara"], "--opcion-rara"),
    ],
)
def test_invalid_arguments_exit_2(argv, fragment, factory, transport, env, no_dotenv, capsys):
    code = run(argv, factory, env, no_dotenv)
    assert code == EXIT_USAGE
    assert fragment in capsys.readouterr().err
    assert transport.sent == []


def test_help_exits_0(factory, env, no_dotenv, capsys):
    assert run(["--help"], factory, env, no_dotenv) == EXIT_OK
    assert "--burst" in capsys.readouterr().out


# --- Cadena de conexión (CA-01.4) ---


def test_missing_connection_string_is_clear_error(factory, transport, no_dotenv, capsys):
    code = run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, {}, no_dotenv)
    assert code == EXIT_CONFIG
    err = capsys.readouterr().err
    assert "IOTHUB_DEVICE_CONNECTION_STRING" in err
    assert ".env" in err
    assert transport.sent == []


def test_empty_connection_string_counts_as_missing(factory, no_dotenv):
    env = {"IOTHUB_DEVICE_CONNECTION_STRING": "   "}
    assert run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, env, no_dotenv) == EXIT_CONFIG


def test_connection_string_from_environment(factory, env, no_dotenv):
    run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, env, no_dotenv)
    assert factory.connection_strings == [FAKE_CONNECTION_STRING]


def test_connection_string_from_dotenv_file(tmp_path, factory):
    dotenv_file = tmp_path / ".env"
    dotenv_file.write_text(f"IOTHUB_DEVICE_CONNECTION_STRING={FAKE_CONNECTION_STRING}\n", encoding="utf-8")
    code = run(["--type", "puerta_forzada", "--zone", "Z-03"], factory, {}, dotenv_file)
    assert code == EXIT_OK
    assert factory.connection_strings == [FAKE_CONNECTION_STRING]


def test_environment_wins_over_dotenv(tmp_path):
    dotenv_file = tmp_path / ".env"
    dotenv_file.write_text("IOTHUB_DEVICE_CONNECTION_STRING=desde-archivo\n", encoding="utf-8")
    env = {"IOTHUB_DEVICE_CONNECTION_STRING": "desde-entorno"}
    assert load_connection_string(env, dotenv_file) == "desde-entorno"


def test_load_connection_string_does_not_modify_environment(tmp_path):
    dotenv_file = tmp_path / ".env"
    dotenv_file.write_text("IOTHUB_DEVICE_CONNECTION_STRING=desde-archivo\n", encoding="utf-8")
    env: dict[str, str] = {}
    assert load_connection_string(env, dotenv_file) == "desde-archivo"
    assert env == {}


# --- Fallo de envío ---


def test_send_failure_exits_1_without_leaking_secret(env, no_dotenv, capsys):
    transport = FakeTransport(fail=True)
    code = run(["--type", "puerta_forzada", "--zone", "Z-03"], TransportFactory(transport), env, no_dotenv)
    assert code == EXIT_SEND_FAILED
    err = capsys.readouterr().err
    assert "No se pudo enviar" in err
    assert "SharedAccessKey" not in err
    assert transport.closed


def test_transport_factory_failure_exits_1(env, no_dotenv, capsys):
    def broken_factory(_connection_string):
        raise ValueError(f"cadena mal formada: {_connection_string}")

    code = run(["--type", "puerta_forzada", "--zone", "Z-03"], broken_factory, env, no_dotenv)
    assert code == EXIT_SEND_FAILED
    err = capsys.readouterr().err
    assert "SharedAccessKey" not in err
