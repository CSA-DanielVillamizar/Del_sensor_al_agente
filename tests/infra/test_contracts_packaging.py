"""T-019 HU-04 CA-04.3: el despliegue empaqueta exactamente los contratos que la Function carga."""

import re
from pathlib import Path

from function.core.contracts import CONTRACT_FILES

ROOT = Path(__file__).resolve().parents[2]
MODULE = (ROOT / "infra" / "lib" / "DsaInfra.psm1").read_text(encoding="utf-8")


def packaged_contracts() -> list[str]:
    block = re.search(r"\$script:ContractFiles = @\((.*?)\)", MODULE, re.DOTALL)
    assert block, "No se encontró $script:ContractFiles en DsaInfra.psm1"
    return re.findall(r"'([^']+)'", block.group(1))


def test_deploy_packages_the_same_contracts_the_function_loads():
    assert sorted(packaged_contracts()) == sorted(CONTRACT_FILES)


def test_every_packaged_contract_exists_in_the_repository():
    for rel in packaged_contracts():
        assert (ROOT / rel).is_file(), rel
