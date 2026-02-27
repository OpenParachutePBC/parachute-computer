"""
Brain Entity Types for Graphiti Extraction

Pydantic models used as entity_types parameter in graphiti.add_episode().
Graphiti's LLM uses these field descriptions as extraction prompts.
"""

from pydantic import BaseModel, Field
from typing import Optional


class Person(BaseModel):
    occupation: Optional[str] = Field(None, description="Current role or job title")
    relationship_to_user: Optional[str] = Field(
        None,
        description="How they relate to Aaron: friend, collaborator, family, mentor, client",
    )
    organization: Optional[str] = Field(
        None, description="Company, community, or group they're part of"
    )
    location: Optional[str] = Field(None, description="Where they're based, if mentioned")


class Project(BaseModel):
    status: Optional[str] = Field(
        None, description="Current status: active, paused, completed, abandoned"
    )
    domain: Optional[str] = Field(
        None,
        description="Domain: software, writing, community, business, research, art",
    )
    deadline: Optional[str] = Field(None, description="Target date or deadline if mentioned")
    collaborators: Optional[str] = Field(
        None, description="People working on this with Aaron"
    )


class Area(BaseModel):
    description: Optional[str] = Field(None, description="What this area encompasses")
    current_focus: Optional[str] = Field(
        None,
        description="What Aaron is actively working on in this area right now",
    )
    cadence: Optional[str] = Field(
        None, description="How often Aaron engages: daily, weekly, seasonal"
    )


class Topic(BaseModel):
    domain: Optional[str] = Field(
        None,
        description="Domain: philosophy, technology, creativity, spirituality, business",
    )
    related_projects: Optional[str] = Field(
        None, description="Projects or areas this topic connects to"
    )
    status: Optional[str] = Field(
        None, description="How developed: emerging, developing, crystallized"
    )


# Passed to graphiti.add_episode(entity_types=ENTITY_TYPES)
ENTITY_TYPES: dict[str, type[BaseModel]] = {
    "Person": Person,
    "Project": Project,
    "Area": Area,
    "Topic": Topic,
}
