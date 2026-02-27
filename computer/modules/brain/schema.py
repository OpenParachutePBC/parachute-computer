"""
Brain Schema Manager

Loads and saves entity_types.yaml from vault/.brain/entity_types.yaml.
Provides hot-reloadable schema without server restarts.

The ontology starts empty and grows through use. Types crystallize when patterns
emerge — not because they were predefined. Use brain_create_type to add structured
field definitions to any entity_type string agents are already using.
"""

import logging
import os
import tempfile
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

# No predefined types — the ontology is discovered, not imposed.
# Agents write any entity_type string they want. Types crystallize via brain_create_type.
DEFAULT_ENTITY_TYPES: dict[str, dict[str, Any]] = {}


def _schema_path(vault_path: Path) -> Path:
    return vault_path / ".brain" / "entity_types.yaml"


def load_entity_types(vault_path: Path) -> dict[str, dict[str, Any]]:
    """Load entity_types.yaml, creating an empty file if absent."""
    path = _schema_path(vault_path)
    if not path.exists():
        save_entity_types(vault_path, DEFAULT_ENTITY_TYPES)
        return DEFAULT_ENTITY_TYPES
    try:
        data = yaml.safe_load(path.read_text()) or {}
        if not isinstance(data, dict):
            logger.warning(f"entity_types.yaml is not a dict, ignoring: {path}")
            return {}
        return data
    except Exception as e:
        logger.warning(f"Failed to load entity_types.yaml: {e}, using empty schema")
        return {}


def save_entity_types(vault_path: Path, entity_types: dict[str, dict[str, Any]]) -> None:
    """Write entity_types.yaml atomically."""
    path = _schema_path(vault_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=".entity_types-", suffix=".yaml.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            yaml.safe_dump(entity_types, f, default_flow_style=False, sort_keys=False)
        os.replace(tmp_path, path)
    except Exception:
        Path(tmp_path).unlink(missing_ok=True)
        raise


def to_api_schema(entity_types: dict[str, dict[str, Any]], entity_counts: dict[str, int] | None = None) -> list[dict]:
    """Convert to the list[BrainSchemaDetail] shape the Flutter UI expects."""
    counts = entity_counts or {}
    result = []
    for type_name, fields in entity_types.items():
        field_list = []
        for field_name, field_def in fields.items():
            field_list.append({
                "name": field_name,
                "type": field_def.get("type", "text"),
                "required": field_def.get("required", False),
                "description": field_def.get("description"),
            })
        result.append({
            "name": type_name,
            "description": f"{type_name} entity",
            "fields": field_list,
            "entity_count": counts.get(type_name, 0),
        })
    return result


def all_field_names(entity_types: dict[str, dict[str, Any]]) -> set[str]:
    """Return the union of all field names across all entity types."""
    fields = set()
    for type_fields in entity_types.values():
        fields.update(type_fields.keys())
    return fields
