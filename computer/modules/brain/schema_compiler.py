"""
Schema Compiler for Brain

Compiles declarative YAML schema definitions to TerminusDB JSON schemas.
Uses async I/O to prevent blocking the event loop during file operations.
"""

from pathlib import Path
import yaml
import logging
from typing import Any
import re

logger = logging.getLogger(__name__)


class SchemaCompiler:
    """Compile YAML schemas to TerminusDB JSON schema format"""

    TYPE_MAP = {
        "string": "xsd:string",
        "integer": "xsd:integer",
        "boolean": "xsd:boolean",
        "datetime": "xsd:dateTime",
        "enum": "Enum",  # Handled specially
        "array": "Set",  # Handled specially
    }

    # SECURITY: Valid schema name pattern (alphanumeric + underscore)
    SCHEMA_NAME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")

    async def compile_schema(self, yaml_path: Path) -> list[dict[str, Any]]:
        """Parse YAML and generate TerminusDB JSON schema documents.

        Returns a list of schema documents (enums first, then the class).
        TerminusDB v12 requires enums as separate top-level schema documents.
        """
        import aiofiles

        async with aiofiles.open(yaml_path) as f:
            content = await f.read()
            schema_def = yaml.safe_load(content)

        self._validate_schema_structure(schema_def, yaml_path)

        # Collect enum definitions that need to be separate documents
        enum_docs: list[dict[str, Any]] = []

        # Build TerminusDB Class schema
        json_schema = {
            "@type": "Class",
            "@id": schema_def["name"],
            "@key": self._build_key_strategy(schema_def),
        }

        if schema_def.get("description"):
            json_schema["@documentation"] = {
                "@comment": schema_def["description"],
            }

        # Compile fields (enum_docs populated as side effect)
        for field_name, field_spec in schema_def.get("fields", {}).items():
            json_schema[field_name] = self._compile_field(
                field_spec, schema_def["name"], field_name, enum_docs
            )

        # Return enums first (must exist before class references them)
        return enum_docs + [json_schema]

    def _validate_schema_structure(self, schema_def: dict[str, Any], yaml_path: Path) -> None:
        """Validate schema structure before compilation."""
        if "name" not in schema_def:
            raise ValueError(f"Schema missing required 'name' field: {yaml_path}")

        name = schema_def["name"]
        if not isinstance(name, str) or not self.SCHEMA_NAME_PATTERN.match(name):
            raise ValueError(
                f"Invalid schema name '{name}' in {yaml_path}. "
                f"Must start with letter and contain only alphanumeric/underscore"
            )

        fields = schema_def.get("fields", {})
        if not isinstance(fields, dict):
            raise ValueError(f"Schema 'fields' must be a dictionary in {yaml_path}")

        if "key_strategy" in schema_def:
            valid_strategies = {"Lexical", "Random", "Hash", "ValueHash"}
            if schema_def["key_strategy"] not in valid_strategies:
                raise ValueError(
                    f"Invalid key_strategy '{schema_def['key_strategy']}' in {yaml_path}. "
                    f"Must be one of: {valid_strategies}"
                )

    def _build_key_strategy(self, schema_def: dict[str, Any]) -> dict[str, Any]:
        """Generate @key based on key_strategy."""
        strategy = schema_def.get("key_strategy", "Random")

        if strategy == "Lexical":
            return {
                "@type": "Lexical",
                "@fields": schema_def.get("key_fields", ["name"]),
            }
        elif strategy == "Random":
            return {"@type": "Random"}
        elif strategy == "Hash":
            return {
                "@type": "Hash",
                "@fields": schema_def.get("key_fields", []),
            }
        elif strategy == "ValueHash":
            return {"@type": "ValueHash"}
        else:
            raise ValueError(f"Unknown key strategy: {strategy}")

    def _compile_field(
        self,
        field_spec: dict[str, Any],
        class_name: str,
        field_name: str,
        enum_docs: list[dict[str, Any]],
    ) -> str | dict[str, Any]:
        """Compile single field to TerminusDB type.

        For enum fields, creates a separate Enum document and returns
        a reference to it (TerminusDB v12 requires top-level enums).
        """
        field_type = field_spec["type"]
        required = field_spec.get("required", False)

        # Handle primitive types
        if field_type in self.TYPE_MAP and field_type not in ("enum", "array"):
            terminus_type = self.TYPE_MAP[field_type]

        # Handle enums — separate document, reference by name
        elif field_type == "enum":
            enum_name = f"{class_name}_{field_name}"
            enum_docs.append({
                "@type": "Enum",
                "@id": enum_name,
                "@value": field_spec["values"],
            })
            terminus_type = enum_name

        # Handle arrays — Set is inherently optional in TerminusDB (empty = no values)
        elif field_type == "array":
            item_type = field_spec["items"]
            if isinstance(item_type, str):
                if item_type in self.TYPE_MAP:
                    return {"@type": "Set", "@class": self.TYPE_MAP[item_type]}
                else:
                    return {"@type": "Set", "@class": item_type}
            elif isinstance(item_type, list):
                # Multi-type arrays: store entity IRIs as strings
                # TerminusDB v12 doesn't support TaggedUnion in Set
                return {"@type": "Set", "@class": "xsd:string"}
            else:
                raise ValueError(f"Invalid array items specification: {item_type}")

        # Handle entity references
        else:
            terminus_type = field_type

        # Wrap in Optional if not required (not needed for Set/arrays)
        if not required:
            return {"@type": "Optional", "@class": terminus_type}

        return terminus_type

    async def compile_all_schemas(self, schemas_dir: Path) -> list[dict[str, Any]]:
        """Compile all YAML schemas in directory.

        Returns a flat list of all schema documents (enums + classes).
        """
        import asyncio

        yaml_files = list(schemas_dir.glob("*.yaml"))

        if not yaml_files:
            logger.warning(f"No schema files found in {schemas_dir}")
            return []

        tasks = [self.compile_schema(yaml_file) for yaml_file in yaml_files]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        # Flatten results (each compile_schema returns a list of docs)
        schemas = []
        for result, yaml_file in zip(results, yaml_files):
            if isinstance(result, Exception):
                logger.error(f"Failed to compile schema {yaml_file.name}: {result}")
            else:
                schemas.extend(result)
                class_doc = [d for d in result if d.get("@type") == "Class"]
                if class_doc:
                    logger.info(f"Compiled schema: {yaml_file.name} -> {class_doc[0]['@id']}")

        return schemas
