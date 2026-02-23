"""
Pydantic Models for Brain

Request/response models with strict validation for type safety.
All models use Pydantic v2 patterns (model_config ConfigDict).
"""

import re
from pydantic import BaseModel, Field, ConfigDict, field_validator
from typing import Any


# --- Schema type validation helpers ---

_TYPE_NAME_RE = re.compile(r'^[A-Za-z][A-Za-z0-9_]*$')
_FIELD_NAME_RE = re.compile(r'^[a-z][a-z0-9_]*$')
_RESERVED = frozenset({
    "Class", "Enum", "Set", "Optional", "TaggedUnion", "Array",
    "Sys", "xsd", "rdf", "owl", "rdfs",
})


class CreateEntityRequest(BaseModel):
    """Request to create entity via MCP tool or API"""
    model_config = ConfigDict(
        strict=True,
        validate_assignment=True,
    )

    entity_type: str = Field(description="Type of entity (Person, Project, Note)")
    data: dict[str, Any] = Field(description="Entity field values")
    commit_msg: str | None = Field(default=None, description="Commit message")


class QueryEntitiesRequest(BaseModel):
    """Request to query entities"""
    model_config = ConfigDict(strict=True)

    entity_type: str = Field(description="Type to query")
    filters: dict[str, Any] | None = Field(default=None, description="Filter conditions")
    limit: int = Field(default=100, ge=1, le=1000, description="Max results to return")
    offset: int = Field(default=0, ge=0, description="Skip first N results")


class UpdateEntityRequest(BaseModel):
    """Request to update entity"""
    model_config = ConfigDict(strict=True)

    entity_id: str = Field(description="Entity IRI to update")
    data: dict[str, Any] = Field(description="Fields to update")
    commit_msg: str | None = Field(default=None, description="Commit message")


class DeleteEntityRequest(BaseModel):
    """Request to delete entity"""
    model_config = ConfigDict(strict=True)

    entity_id: str = Field(description="Entity IRI to delete")
    commit_msg: str | None = Field(default=None, description="Commit message")


class CreateRelationshipRequest(BaseModel):
    """Request to create relationship"""
    model_config = ConfigDict(strict=True)

    from_id: str = Field(description="Source entity IRI")
    relationship: str = Field(description="Relationship field name")
    to_id: str = Field(description="Target entity IRI")


class TraverseGraphRequest(BaseModel):
    """Request to traverse graph"""
    model_config = ConfigDict(strict=True)

    start_id: str = Field(description="Starting entity IRI")
    relationship: str = Field(description="Relationship to follow")
    max_depth: int = Field(default=2, ge=1, le=5, description="Maximum traversal depth")


class Entity(BaseModel):
    """Generic entity response"""
    model_config = ConfigDict(populate_by_name=True)

    id: str = Field(alias="@id", description="Entity IRI")
    type: str = Field(alias="@type", description="Entity type")
    data: dict[str, Any] = Field(description="Entity fields")


class CreateEntityResponse(BaseModel):
    """Response from create_entity"""
    model_config = ConfigDict(strict=True)

    success: bool
    entity_id: str


class QueryEntitiesResponse(BaseModel):
    """Response from query_entities"""
    model_config = ConfigDict(strict=True)

    success: bool
    results: list[dict[str, Any]]
    count: int
    offset: int
    limit: int


# --- Schema CRUD models ---

class FieldSpec(BaseModel):
    """Specification for a single field in a schema type."""
    model_config = ConfigDict(strict=True, validate_assignment=True)

    type: str = Field(description="string | integer | boolean | datetime | enum | link")
    required: bool = False
    values: list[str] | None = None   # for enum — must have >= 1 item
    link_type: str | None = None      # for link fields — must match ^[A-Za-z][A-Za-z0-9_]*$
    description: str | None = None

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        allowed = {"string", "integer", "boolean", "datetime", "enum", "link"}
        if v not in allowed:
            raise ValueError(f"type must be one of {allowed}, got '{v}'")
        return v

    @field_validator("values")
    @classmethod
    def validate_values(cls, v: list[str] | None, info: Any) -> list[str] | None:
        if info.data.get("type") == "enum" and not v:
            raise ValueError("enum field requires at least one value in 'values'")
        return v

    @field_validator("link_type")
    @classmethod
    def validate_link_type(cls, v: str | None) -> str | None:
        if v is not None and not _TYPE_NAME_RE.match(v):
            raise ValueError(f"link_type must match [A-Za-z][A-Za-z0-9_]*, got '{v}'")
        return v


class CreateSchemaTypeRequest(BaseModel):
    """Request to create a new schema type (TerminusDB Class)."""
    model_config = ConfigDict(strict=True)

    name: str = Field(description="PascalCase type name, e.g. 'Project'")
    fields: dict[str, FieldSpec]
    key_strategy: str = "Random"
    description: str | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if not _TYPE_NAME_RE.match(v):
            raise ValueError(f"Type name must match ^[A-Za-z][A-Za-z0-9_]*$, got '{v}'")
        if v in _RESERVED:
            raise ValueError(f"'{v}' is a reserved TerminusDB name")
        return v

    @field_validator("fields")
    @classmethod
    def validate_field_names(cls, v: dict) -> dict:
        for name in v:
            if not _FIELD_NAME_RE.match(name):
                raise ValueError(
                    f"Field name '{name}' must match ^[a-z][a-z0-9_]*$"
                )
        return v


class UpdateSchemaTypeRequest(BaseModel):
    """Request to update an existing schema type (full field replacement)."""
    model_config = ConfigDict(strict=True)

    fields: dict[str, FieldSpec]

    @field_validator("fields")
    @classmethod
    def validate_field_names(cls, v: dict) -> dict:
        for name in v:
            if not _FIELD_NAME_RE.match(name):
                raise ValueError(f"Field name '{name}' must match ^[a-z][a-z0-9_]*$")
        return v


class SchemaTypeResponse(BaseModel):
    """Response shape for a single schema type."""
    name: str
    description: str | None
    key_strategy: str | None
    fields: list[dict[str, Any]]
    entity_count: int


# --- Saved query models ---

class SavedQueryModel(BaseModel):
    """A saved filter query. Stored via backend API (NOT Flutter direct file I/O)."""
    id: str = ""
    name: str
    entity_type: str
    filters: list[dict[str, Any]]


class SavedQueryListResponse(BaseModel):
    """List of saved queries."""
    queries: list[SavedQueryModel]
