"""Adaptador real del puerto `TableStore` sobre Azure Table Storage (ADR-006).

Acceso con la identidad administrada `id-dsa-func` (rol Storage Table Data Contributor), sin
claves. Las tablas `dedup` y `ratelimit` las crea la infraestructura (Bicep); este adaptador
no las crea para no sumar llamadas en el arranque en frío.

Concurrencia optimista: `update_entity` con `etag` e `IfNotModified` (If-Match); 412 → EtagMismatch
(https://learn.microsoft.com/rest/api/storageservices/update-entity2#remarks). Insertar una entidad
existente → 409 → EntityExists (https://learn.microsoft.com/rest/api/storageservices/table-service-error-codes).
"""

from __future__ import annotations

from typing import Any

from azure.core import MatchConditions
from azure.core.exceptions import (
    HttpResponseError,
    ResourceExistsError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from azure.data.tables import TableServiceClient, UpdateMode

from .ports import EntityExists, EtagMismatch


class AzureTableStore:
    def __init__(self, service: Any) -> None:
        self._service = service
        self._clients: dict[str, Any] = {}

    @classmethod
    def from_endpoint(cls, endpoint: str, credential: Any) -> AzureTableStore:
        return cls(TableServiceClient(endpoint=endpoint, credential=credential))

    def _client(self, table: str) -> Any:
        if table not in self._clients:
            self._clients[table] = self._service.get_table_client(table)
        return self._clients[table]

    def get(self, table: str, pk: str, rk: str) -> tuple[dict[str, Any], str] | None:
        try:
            entity = self._client(table).get_entity(pk, rk)
        except ResourceNotFoundError:
            return None
        return dict(entity), entity.metadata["etag"]

    def insert(self, table: str, entity: dict[str, Any]) -> str:
        try:
            metadata = self._client(table).create_entity(entity)
        except ResourceExistsError:
            raise EntityExists(table) from None
        return metadata["etag"]

    def update(self, table: str, entity: dict[str, Any], etag: str, *, replace: bool = False) -> str:
        try:
            metadata = self._client(table).update_entity(
                entity,
                mode=UpdateMode.REPLACE if replace else UpdateMode.MERGE,
                etag=etag,
                match_condition=MatchConditions.IfNotModified,
            )
        except (ResourceModifiedError, ResourceNotFoundError):
            raise EtagMismatch(table) from None
        except HttpResponseError as exc:
            if exc.status_code == 412:
                raise EtagMismatch(table) from None
            raise
        return metadata["etag"]

    def count_partition(self, table: str, pk: str) -> int:
        rows = self._client(table).query_entities(
            "PartitionKey eq @pk", parameters={"pk": pk}, select=["RowKey"]
        )
        return sum(1 for _ in rows)
