"""T-007 HU-05 CA-05.1: los contratos se cargan desde DSA_CONTRACTS_DIR o, por defecto, desde la raíz."""

import json
import shutil
from pathlib import Path

import pytest

from function.core import contracts
from function.core.contracts import ContractsError, load_contracts, resolve_contracts_dir

ROOT = Path(__file__).resolve().parents[2]


def test_default_dir_is_repo_root_in_local(monkeypatch):
    monkeypatch.delenv("DSA_CONTRACTS_DIR", raising=False)
    assert resolve_contracts_dir() == ROOT


def test_packaged_dir_is_preferred_when_present(monkeypatch, tmp_path):
    monkeypatch.delenv("DSA_CONTRACTS_DIR", raising=False)
    packaged = tmp_path / "_contracts"
    packaged.mkdir()
    monkeypatch.setattr(contracts, "PACKAGED_DIR", packaged)
    assert resolve_contracts_dir() == packaged


def test_env_var_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("DSA_CONTRACTS_DIR", str(tmp_path))
    assert resolve_contracts_dir() == tmp_path


def test_loads_from_a_copied_folder(tmp_path):
    for rel in contracts.CONTRACT_FILES:
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    loaded = load_contracts(tmp_path)
    assert {z["zone"] for z in loaded.zones} >= {"Z-01", "Z-03"}
    assert loaded.columns["list"] == "Eventos de seguridad"


def test_missing_file_raises_clear_error(tmp_path):
    with pytest.raises(ContractsError, match="evento-dispositivo"):
        load_contracts(tmp_path)


def test_invalid_catalog_raises(tmp_path):
    for rel in contracts.CONTRACT_FILES:
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, tmp_path / rel)
    (tmp_path / "data" / "zonas.json").write_text(json.dumps([{"zone": "X"}]), encoding="utf-8")
    with pytest.raises(ContractsError, match="zonas"):
        load_contracts(tmp_path)
