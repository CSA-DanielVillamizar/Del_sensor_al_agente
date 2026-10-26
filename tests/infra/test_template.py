"""Pruebas sobre la plantilla compilada de infra/main.bicep (T-018, HU-04, CA-04.2, CA-04.4).

Compilan la plantilla con `az bicep build` (local, sin Azure) y comprueban:
- ninguna salida (`outputs`) expone claves, cadenas de conexión ni secretos;
- la única política de IoT Hub es `func-reader` y solo tiene `ServiceConnect`;
- la Function consume la cadena de IoT Hub como referencia `@Microsoft.KeyVault(...)`,
  resuelta con la identidad asignada por el usuario;
- la cuenta de almacenamiento tiene `allowSharedKeyAccess: false`.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess  # noqa: S404 - se invoca la CLI de Azure local con argumentos fijos
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[2]
MAIN_BICEP = ROOT / "infra" / "main.bicep"

SECRET_NAME_PATTERN = re.compile(r"(key|secret|password|connectionstring|sas|token)", re.IGNORECASE)
SECRET_VALUE_PATTERN = re.compile(
    r"(listkeys|listsecrets|listconnectionstrings|primaryKey|secondaryKey|SharedAccessKey|AccountKey"
    r"|ConnectionString|secretUri)",
    re.IGNORECASE,
)


def _az_executable() -> str | None:
    return shutil.which("az") or shutil.which("az.cmd")


@pytest.fixture(scope="module")
def template(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    az = _az_executable()
    if az is None:
        pytest.skip("La CLI de Azure no está instalada; la prueba de plantilla necesita 'az bicep'.")
    out = tmp_path_factory.mktemp("bicep") / "main.json"
    result = subprocess.run(  # noqa: S603 - argumentos fijos, sin entrada del usuario
        [az, "bicep", "build", "--file", str(MAIN_BICEP), "--outfile", str(out)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"az bicep build falló:\n{result.stderr}"
    return json.loads(out.read_text(encoding="utf-8"))


def _resources(node: dict[str, Any]) -> list[dict[str, Any]]:
    res = node.get("resources", [])
    return list(res.values()) if isinstance(res, dict) else list(res)


def _walk_templates(tpl: dict[str, Any], path: str = "main") -> Iterator[tuple[str, dict[str, Any]]]:
    """Recorre la plantilla principal y las plantillas anidadas de cada módulo."""
    yield path, tpl
    for res in _resources(tpl):
        if res.get("type", "").lower() == "microsoft.resources/deployments":
            nested = res.get("properties", {}).get("template")
            if nested:
                yield from _walk_templates(nested, f"{path}/{res.get('name')}")


def _all_resources(tpl: dict[str, Any]) -> list[dict[str, Any]]:
    return [r for _, t in _walk_templates(tpl) for r in _resources(t)]


def _of_type(tpl: dict[str, Any], rtype: str) -> list[dict[str, Any]]:
    return [r for r in _all_resources(tpl) if r.get("type", "").lower() == rtype.lower()]


def test_ninguna_salida_expone_secretos(template: dict[str, Any]) -> None:
    hallazgos = []
    for path, tpl in _walk_templates(template):
        for name, out in tpl.get("outputs", {}).items():
            value = json.dumps(out.get("value", ""))
            if out.get("type", "").lower() in {"securestring", "secureobject"}:
                hallazgos.append(f"{path}.{name}: tipo seguro en salida")
            # Nombres de recursos e identificadores públicos (keyVaultName, identityClientId) no son claves.
            public = name.lower().endswith(("name", "clientid", "principalid"))
            if SECRET_NAME_PATTERN.search(name) and not public:
                hallazgos.append(f"{path}.{name}: nombre sospechoso")
            if SECRET_VALUE_PATTERN.search(value):
                hallazgos.append(f"{path}.{name}: valor sospechoso {value}")
    assert not hallazgos, "Salidas con posibles secretos:\n" + "\n".join(hallazgos)


def test_iothub_solo_politica_func_reader_con_service_connect(template: dict[str, Any]) -> None:
    hubs = _of_type(template, "Microsoft.Devices/IotHubs")
    assert len(hubs) == 1
    policies = hubs[0]["properties"]["authorizationPolicies"]
    assert [p["keyName"] for p in policies] == ["func-reader"]
    rights = {r.strip() for r in policies[0]["rights"].split(",")}
    assert rights == {"ServiceConnect"}
    assert all("primaryKey" not in p and "secondaryKey" not in p for p in policies)


def test_iothub_sku_por_defecto_f1(template: dict[str, Any]) -> None:
    assert template["parameters"]["iotHubSku"]["defaultValue"] == "F1"
    assert template["parameters"]["location"]["defaultValue"] == "eastus2"


def test_function_usa_referencia_de_key_vault(template: dict[str, Any]) -> None:
    sites = _of_type(template, "Microsoft.Web/sites")
    assert len(sites) == 1
    props = sites[0]["properties"]
    settings_json = json.dumps(props["siteConfig"]["appSettings"])
    settings = props["siteConfig"]["appSettings"]
    iot = settings if isinstance(settings, str) else json.dumps(settings)
    assert "IoTHubConnection" in iot
    assert "@Microsoft.KeyVault(VaultName=" in settings_json
    assert "SecretName=" in settings_json
    # Ninguna clave en texto plano en la configuración de la app.
    assert not re.search(r"listkeys|SharedAccessKey=|AccountKey=", settings_json, re.IGNORECASE)
    # La referencia se resuelve con la identidad asignada por el usuario.
    assert "keyVaultReferenceIdentity" in props
    assert sites[0]["identity"]["type"] == "UserAssigned"


def test_secreto_de_iothub_solo_en_key_vault(template: dict[str, Any]) -> None:
    secrets = _of_type(template, "Microsoft.KeyVault/vaults/secrets")
    assert len(secrets) == 1
    assert "iothub-func-reader" in json.dumps(template)
    value = json.dumps(secrets[0]["properties"]["value"])
    assert "SharedAccessKeyName=" in value
    # La clave viene de listkeys dentro del despliegue, nunca de un parámetro.
    assert "listkeys" in value.lower()


def test_key_vault_rbac_y_rol_secrets_user(template: dict[str, Any]) -> None:
    vaults = _of_type(template, "Microsoft.KeyVault/vaults")
    assert len(vaults) == 1
    assert vaults[0]["properties"]["enableRbacAuthorization"] is True
    # El rol Key Vault Secrets User se asigna dentro del módulo del almacén.
    kv_module = next(t for path, t in _walk_templates(template) if path.endswith("/keyvault"))
    assert "4633458b-17de-408a-b874-0445c86b69e6" in json.dumps(kv_module)
    assert any(r["type"] == "Microsoft.Authorization/roleAssignments" for r in _resources(kv_module))


def test_storage_sin_claves_compartidas(template: dict[str, Any]) -> None:
    accounts = _of_type(template, "Microsoft.Storage/storageAccounts")
    assert len(accounts) == 1
    assert accounts[0]["properties"]["allowSharedKeyAccess"] is False
    assert accounts[0]["properties"]["allowBlobPublicAccess"] is False


def test_flex_consumption_512_mb_y_una_instancia(template: dict[str, Any]) -> None:
    params = template["parameters"]
    assert params["instanceMemoryMB"]["defaultValue"] == 512
    assert params["maximumInstanceCount"]["defaultValue"] == 1
    assert params["alwaysReadyCount"]["defaultValue"] == 0
    plans = _of_type(template, "Microsoft.Web/serverfarms")
    assert plans[0]["sku"]["tier"] == "FlexConsumption"


def test_presupuesto_80_por_ciento_al_rol_owner_sin_correos(template: dict[str, Any]) -> None:
    budgets = _of_type(template, "Microsoft.Consumption/budgets")
    assert len(budgets) == 1
    notif = next(iter(budgets[0]["properties"]["notifications"].values()))
    assert notif["contactRoles"] == ["Owner"]
    assert notif["contactEmails"] == []
    assert template["parameters"]["budgetAmount"]["defaultValue"] == 20
    assert template["parameters"]["budgetThresholdPercent"]["defaultValue"] == 80
    assert "@" not in json.dumps(budgets[0]["properties"]).replace("@Microsoft", "")


def test_sin_parametros_con_valores_de_secretos(template: dict[str, Any]) -> None:
    for name, param in template["parameters"].items():
        assert not SECRET_NAME_PATTERN.search(name) or name == "iotHubKeySlot", name
        default = json.dumps(param.get("defaultValue", ""))
        assert not re.search(r"SharedAccessKey=|AccountKey=", default), name


def test_iothub_tiene_el_grupo_de_consumidores_de_la_function(template: dict[str, Any]) -> None:
    # function/function_app.py lee el endpoint integrado con consumer_group="func" (ADR-004 §1).
    groups = _of_type(template, "Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups")
    assert groups, "Falta el grupo de consumidores de la Function en IoT Hub"
    assert any("events/func" in str(g.get("name", "")) for g in groups)
