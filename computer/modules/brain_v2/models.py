"""
Pydantic Models for Brain v2

Request/response models with strict validation for type safety.
All models use Pydantic v2 patterns (model_config ConfigDict).
"""

from pydantic import BaseModel, Field, ConfigDict
from typing import Any


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
