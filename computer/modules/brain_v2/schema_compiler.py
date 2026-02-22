"""
Schema Compiler for Brain v2

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
        "array": "List",  # Handled specially
    }

    # SECURITY: Valid schema name pattern (alphanumeric + underscore)
    SCHEMA_NAME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")

    async def compile_schema(self, yaml_path: Path) -> dict[str, Any]:
        """Parse YAML and generate TerminusDB JSON schema

        SECURITY: Validates schema structure to prevent injection
        PERFORMANCE: Uses aiofiles for async I/O
        """
        # PERFORMANCE FIX: Use aiofiles for async I/O
        import aiofiles

        async with aiofiles.open(yaml_path) as f:
            content = await f.read()
            schema_def = yaml.safe_load(content)  # SECURITY: safe_load, never load()

        # SECURITY: Validate schema structure
        self._validate_schema_structure(schema_def, yaml_path)

        # Build TerminusDB DocumentTemplate equivalent
        json_schema = {
            "@type": "Class",
            "@id": schema_def["name"],
            "@documentation": schema_def.get("description", ""),
            "@key": self._build_key_strategy(schema_def),
        }

        # Compile fields
        for field_name, field_spec in schema_def.get("fields", {}).items():
            json_schema[field_name] = self._compile_field(field_spec)

        return json_schema

    def _validate_schema_structure(self, schema_def: dict[str, Any], yaml_path: Path) -> None:
        """SECURITY: Validate schema structure before compilation"""
        # Required fields
        if "name" not in schema_def:
            raise ValueError(f"Schema missing required 'name' field: {yaml_path}")

        # Validate name format
        name = schema_def["name"]
        if not isinstance(name, str) or not self.SCHEMA_NAME_PATTERN.match(name):
            raise ValueError(
                f"Invalid schema name '{name}' in {yaml_path}. "
                f"Must start with letter and contain only alphanumeric/underscore"
            )

        # Validate fields is dict
        fields = schema_def.get("fields", {})
        if not isinstance(fields, dict):
            raise ValueError(f"Schema 'fields' must be a dictionary in {yaml_path}")

        # Validate key_strategy if present
        if "key_strategy" in schema_def:
            valid_strategies = {"Lexical", "Random", "Hash", "ValueHash"}
            if schema_def["key_strategy"] not in valid_strategies:
                raise ValueError(
                    f"Invalid key_strategy '{schema_def['key_strategy']}' in {yaml_path}. "
                    f"Must be one of: {valid_strategies}"
                )

    def _build_key_strategy(self, schema_def: dict[str, Any]) -> dict[str, Any]:
        """Generate @key based on key_strategy"""
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

    def _compile_field(self, field_spec: dict[str, Any]) -> str | dict[str, Any]:
        """Compile single field to TerminusDB type"""
        field_type = field_spec["type"]
        required = field_spec.get("required", False)

        # Handle primitive types
        if field_type in self.TYPE_MAP and field_type not in ("enum", "array"):
            terminus_type = self.TYPE_MAP[field_type]

        # Handle enums
        elif field_type == "enum":
            # Create inline enum (alternative: separate EnumTemplate)
            enum_name = f"{field_spec.get('name', 'Enum')}"
            terminus_type = {
                "@type": "Enum",
                "@id": enum_name,
                "@values": field_spec["values"],
            }

        # Handle arrays
        elif field_type == "array":
            item_type = field_spec["items"]
            if isinstance(item_type, str):
                # Single type array
                if item_type in self.TYPE_MAP:
                    terminus_type = {"@type": "List", "@class": self.TYPE_MAP[item_type]}
                else:
                    # Reference to another entity
                    terminus_type = {"@type": "List", "@class": item_type}
            elif isinstance(item_type, list):
                # Union type array (e.g., [Person, Project])
                terminus_type = {
                    "@type": "List",
                    "@class": {"@type": "TaggedUnion", "@classes": item_type},
                }
            else:
                raise ValueError(f"Invalid array items specification: {item_type}")

        # Handle entity references
        else:
            # Assume it's a reference to another entity type
            terminus_type = field_type

        # Wrap in Optional if not required
        if not required:
            return {"@type": "Optional", "@class": terminus_type}

        return terminus_type

    async def compile_all_schemas(self, schemas_dir: Path) -> list[dict[str, Any]]:
        """Compile all YAML schemas in directory

        PERFORMANCE: Compiles all schemas in parallel using asyncio.gather()
        """
        import asyncio

        yaml_files = list(schemas_dir.glob("*.yaml"))

        if not yaml_files:
            logger.warning(f"No schema files found in {schemas_dir}")
            return []

        # PERFORMANCE: Compile all schemas in parallel
        tasks = [self.compile_schema(yaml_file) for yaml_file in yaml_files]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        # Filter out exceptions and log errors
        schemas = []
        for schema, yaml_file in zip(results, yaml_files):
            if isinstance(schema, Exception):
                logger.error(f"Failed to compile schema {yaml_file.name}: {schema}")
                # Continue compiling other schemas instead of crashing
            else:
                schemas.append(schema)
                logger.info(f"Compiled schema: {yaml_file.name} -> {schema['@id']}")

        return schemas
