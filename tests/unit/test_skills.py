"""
Comprehensive tests for the skills discovery and runtime plugin system.

Tests cover:
- Skill discovery from .skills/ directory
- Frontmatter parsing (YAML metadata)
- Single-file skills (.md files)
- Directory-based skills (with SKILL.md)
- Runtime plugin generation
- System prompt section generation
- Edge cases and error handling
"""

import json
import pytest
import tempfile
import shutil
from pathlib import Path

from parachute.core.skills import (
    SkillInfo,
    parse_skill_frontmatter,
    discover_skills,
    generate_runtime_plugin,
    get_skills_for_system_prompt,
    cleanup_runtime_plugin,
)


class TestParseFrontmatter:
    """Tests for YAML frontmatter parsing."""

    def test_basic_frontmatter(self):
        """Test parsing basic frontmatter."""
        content = """---
name: My Skill
description: Does something cool
version: 2.0.0
---

# Skill Content
"""
        metadata = parse_skill_frontmatter(content)

        assert metadata["name"] == "My Skill"
        assert metadata["description"] == "Does something cool"
        assert metadata["version"] == "2.0.0"

    def test_frontmatter_with_tools_array(self):
        """Test parsing tools array in frontmatter."""
        content = """---
name: Tool Skill
allowed-tools: [Read, Write, Bash]
---

Content here.
"""
        metadata = parse_skill_frontmatter(content)

        assert metadata["name"] == "Tool Skill"
        assert metadata["allowed_tools"] == ["Read", "Write", "Bash"]

    def test_frontmatter_with_quoted_values(self):
        """Test parsing quoted values."""
        content = """---
name: "Quoted Name"
description: 'Single quoted description'
---

Content.
"""
        metadata = parse_skill_frontmatter(content)

        assert metadata["name"] == "Quoted Name"
        assert metadata["description"] == "Single quoted description"

    def test_no_frontmatter(self):
        """Test content without frontmatter."""
        content = "# Just Markdown\n\nNo frontmatter here."
        metadata = parse_skill_frontmatter(content)

        assert metadata == {}

    def test_incomplete_frontmatter(self):
        """Test incomplete frontmatter (only one ---)."""
        content = """---
name: Broken
This never closes
"""
        metadata = parse_skill_frontmatter(content)

        assert metadata == {}

    def test_empty_frontmatter(self):
        """Test empty frontmatter."""
        content = """---
---

Content after empty frontmatter.
"""
        metadata = parse_skill_frontmatter(content)

        assert metadata == {}

    def test_hyphenated_keys_converted_to_underscores(self):
        """Test that hyphenated keys are converted to underscores."""
        content = """---
allowed-tools: [Read]
max-tokens: 1000
---

Content.
"""
        metadata = parse_skill_frontmatter(content)

        assert "allowed_tools" in metadata
        assert "max_tokens" in metadata
        assert metadata["allowed_tools"] == ["Read"]


class TestDiscoverSkills:
    """Tests for skill discovery from filesystem."""

    @pytest.fixture
    def skills_vault(self, tmp_path):
        """Create a vault with various skill structures."""
        skills_dir = tmp_path / ".skills"
        skills_dir.mkdir()
        return tmp_path

    def test_discover_single_file_skill(self, skills_vault):
        """Test discovering a single .md file skill."""
        skill_file = skills_vault / ".skills" / "simple-skill.md"
        skill_file.write_text("""---
name: Simple Skill
description: A simple skill
---

# Instructions

Do the thing.
""")

        skills = discover_skills(skills_vault)

        assert len(skills) == 1
        assert skills[0].name == "Simple Skill"
        assert skills[0].description == "A simple skill"
        assert skills[0].path == skill_file

    def test_discover_directory_skill(self, skills_vault):
        """Test discovering a directory-based skill with SKILL.md."""
        skill_dir = skills_vault / ".skills" / "complex-skill"
        skill_dir.mkdir()

        skill_file = skill_dir / "SKILL.md"
        skill_file.write_text("""---
name: Complex Skill
description: A skill with resources
allowed-tools: [Read, Write]
---

# Complex Skill Instructions
""")

        # Add extra files
        (skill_dir / "resources.md").write_text("# Extra resources")

        skills = discover_skills(skills_vault)

        assert len(skills) == 1
        assert skills[0].name == "Complex Skill"
        assert skills[0].allowed_tools == ["Read", "Write"]

    def test_discover_lowercase_skill_md(self, skills_vault):
        """Test discovering skill.md (lowercase)."""
        skill_dir = skills_vault / ".skills" / "lowercase-skill"
        skill_dir.mkdir()

        skill_file = skill_dir / "skill.md"
        skill_file.write_text("""---
name: Lowercase
description: Uses lowercase skill.md
---

Content.
""")

        skills = discover_skills(skills_vault)

        assert len(skills) == 1
        assert skills[0].name == "Lowercase"

    def test_discover_index_md_skill(self, skills_vault):
        """Test discovering skill via index.md."""
        skill_dir = skills_vault / ".skills" / "indexed-skill"
        skill_dir.mkdir()

        skill_file = skill_dir / "index.md"
        skill_file.write_text("""---
name: Indexed
description: Uses index.md
---

Content.
""")

        skills = discover_skills(skills_vault)

        assert len(skills) == 1
        assert skills[0].name == "Indexed"

    def test_discover_multiple_skills(self, skills_vault):
        """Test discovering multiple skills."""
        # Single file skill
        (skills_vault / ".skills" / "skill-one.md").write_text("""---
name: Alpha Skill
description: First skill
---
Content.
""")

        # Directory skill
        skill_dir = skills_vault / ".skills" / "skill-two"
        skill_dir.mkdir()
        (skill_dir / "SKILL.md").write_text("""---
name: Beta Skill
description: Second skill
---
Content.
""")

        skills = discover_skills(skills_vault)

        # Should be sorted alphabetically
        assert len(skills) == 2
        assert skills[0].name == "Alpha Skill"
        assert skills[1].name == "Beta Skill"

    def test_discover_skill_without_frontmatter(self, skills_vault):
        """Test discovering skill without frontmatter uses defaults."""
        skill_file = skills_vault / ".skills" / "no-frontmatter.md"
        skill_file.write_text("# Just Content\n\nNo frontmatter here.")

        skills = discover_skills(skills_vault)

        assert len(skills) == 1
        assert skills[0].name == "no-frontmatter"  # Uses filename as name
        assert skills[0].description == ""

    def test_no_skills_directory(self, tmp_path):
        """Test behavior when .skills/ doesn't exist."""
        skills = discover_skills(tmp_path)

        assert skills == []

    def test_empty_skills_directory(self, skills_vault):
        """Test behavior when .skills/ is empty."""
        skills = discover_skills(skills_vault)

        assert skills == []

    def test_ignores_non_md_files(self, skills_vault):
        """Test that non-.md files are ignored."""
        (skills_vault / ".skills" / "readme.txt").write_text("Not a skill")
        (skills_vault / ".skills" / "config.json").write_text("{}")

        skills = discover_skills(skills_vault)

        assert skills == []

    def test_ignores_empty_directories(self, skills_vault):
        """Test that empty directories are ignored."""
        (skills_vault / ".skills" / "empty-dir").mkdir()

        skills = discover_skills(skills_vault)

        assert skills == []


class TestGenerateRuntimePlugin:
    """Tests for runtime plugin generation."""

    @pytest.fixture
    def vault_with_skills(self, tmp_path):
        """Create a vault with skills for plugin generation testing."""
        skills_dir = tmp_path / ".skills"
        skills_dir.mkdir()

        # Single file skill
        (skills_dir / "single-skill.md").write_text("""---
name: Single
description: A single file skill
---
Instructions.
""")

        # Directory skill
        complex_dir = skills_dir / "complex-skill"
        complex_dir.mkdir()
        (complex_dir / "SKILL.md").write_text("""---
name: Complex
description: A complex skill
---
Instructions.
""")
        (complex_dir / "extra.md").write_text("Extra content")

        return tmp_path

    def test_generates_plugin_structure(self, vault_with_skills):
        """Test that plugin structure is generated correctly."""
        plugin_dir = generate_runtime_plugin(vault_with_skills)

        assert plugin_dir is not None
        assert plugin_dir.exists()
        assert (plugin_dir / ".claude-plugin" / "plugin.json").exists()
        assert (plugin_dir / "skills").exists()

    def test_plugin_manifest_content(self, vault_with_skills):
        """Test plugin.json manifest content."""
        plugin_dir = generate_runtime_plugin(vault_with_skills)

        manifest_path = plugin_dir / ".claude-plugin" / "plugin.json"
        manifest = json.loads(manifest_path.read_text())

        assert manifest["name"] == "parachute-skills"
        assert manifest["version"] == "1.0.0"
        assert "generated" in manifest

    def test_skills_copied_to_plugin(self, vault_with_skills):
        """Test that skills are copied to plugin directory."""
        plugin_dir = generate_runtime_plugin(vault_with_skills)

        skills_dir = plugin_dir / "skills"

        # Check single file skill
        assert (skills_dir / "Single" / "SKILL.md").exists()

        # Check complex skill
        assert (skills_dir / "Complex" / "SKILL.md").exists()
        assert (skills_dir / "Complex" / "extra.md").exists()

    def test_regenerates_clean_plugin(self, vault_with_skills):
        """Test that regenerating cleans up old plugin."""
        # Generate first
        plugin_dir = generate_runtime_plugin(vault_with_skills)

        # Add extra file that shouldn't be there
        stale_file = plugin_dir / "stale.txt"
        stale_file.write_text("stale")

        # Regenerate
        plugin_dir2 = generate_runtime_plugin(vault_with_skills)

        assert plugin_dir == plugin_dir2
        assert not stale_file.exists()

    def test_returns_none_when_no_skills(self, tmp_path):
        """Test returns None when no skills exist."""
        plugin_dir = generate_runtime_plugin(tmp_path)

        assert plugin_dir is None

    def test_plugin_path_location(self, vault_with_skills):
        """Test plugin is created in correct location."""
        plugin_dir = generate_runtime_plugin(vault_with_skills)

        expected_path = vault_with_skills / ".parachute" / "runtime" / "skills-plugin"
        assert plugin_dir == expected_path


class TestCleanupRuntimePlugin:
    """Tests for runtime plugin cleanup."""

    def test_cleanup_removes_plugin(self, tmp_path):
        """Test cleanup removes the plugin directory."""
        # Create plugin structure
        plugin_dir = tmp_path / ".parachute" / "runtime" / "skills-plugin"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "test.txt").write_text("test")

        cleanup_runtime_plugin(tmp_path)

        assert not plugin_dir.exists()

    def test_cleanup_noop_when_missing(self, tmp_path):
        """Test cleanup doesn't error when plugin doesn't exist."""
        # Should not raise
        cleanup_runtime_plugin(tmp_path)


class TestGetSkillsForSystemPrompt:
    """Tests for system prompt generation."""

    def test_generates_skills_section(self, tmp_path):
        """Test generates skills section for system prompt."""
        skills_dir = tmp_path / ".skills"
        skills_dir.mkdir()

        (skills_dir / "skill-a.md").write_text("""---
name: Alpha
description: Does alpha things
---
Content.
""")
        (skills_dir / "skill-b.md").write_text("""---
name: Beta
description: Does beta things
---
Content.
""")

        prompt_section = get_skills_for_system_prompt(tmp_path)

        assert "## Available Skills" in prompt_section
        assert "**Alpha**: Does alpha things" in prompt_section
        assert "**Beta**: Does beta things" in prompt_section

    def test_returns_empty_when_no_skills(self, tmp_path):
        """Test returns empty string when no skills."""
        prompt_section = get_skills_for_system_prompt(tmp_path)

        assert prompt_section == ""


class TestSkillInfo:
    """Tests for SkillInfo dataclass."""

    def test_to_dict(self):
        """Test SkillInfo serialization."""
        skill = SkillInfo(
            name="Test Skill",
            description="Test description",
            path=Path("/test/path.md"),
            version="1.2.3",
            allowed_tools=["Read", "Write"],
        )

        data = skill.to_dict()

        assert data["name"] == "Test Skill"
        assert data["description"] == "Test description"
        assert data["path"] == "/test/path.md"
        assert data["version"] == "1.2.3"
        assert data["allowed_tools"] == ["Read", "Write"]

    def test_default_values(self):
        """Test SkillInfo default values."""
        skill = SkillInfo(
            name="Minimal",
            description="",
            path=Path("/test.md"),
        )

        assert skill.version == "1.0.0"
        assert skill.allowed_tools is None


class TestIntegrationWithTestVault:
    """Integration tests using the test vault at /tmp/parachute-skills-test."""

    @pytest.fixture
    def test_vault(self):
        """Reference the pre-created test vault."""
        vault = Path("/tmp/parachute-skills-test")
        if not vault.exists():
            pytest.skip("Test vault not created")
        return vault

    def test_discovers_all_test_skills(self, test_vault):
        """Test discovering all skills in test vault."""
        skills = discover_skills(test_vault)

        # Should find: summarizer, code-explainer, brainstorm
        assert len(skills) == 3

        skill_names = {s.name for s in skills}
        assert "Summarizer" in skill_names
        assert "Code Explainer" in skill_names
        assert "Brainstorm" in skill_names

    def test_skill_tools_parsed(self, test_vault):
        """Test that allowed-tools are parsed correctly."""
        skills = discover_skills(test_vault)

        summarizer = next(s for s in skills if s.name == "Summarizer")
        assert summarizer.allowed_tools == ["Read", "WebFetch"]

    def test_generates_plugin_for_test_vault(self, test_vault):
        """Test plugin generation for test vault."""
        plugin_dir = generate_runtime_plugin(test_vault)

        assert plugin_dir is not None
        assert (plugin_dir / "skills" / "Summarizer" / "SKILL.md").exists()
        assert (plugin_dir / "skills" / "Code Explainer" / "SKILL.md").exists()
        assert (plugin_dir / "skills" / "Brainstorm" / "SKILL.md").exists()

    def test_system_prompt_includes_all_skills(self, test_vault):
        """Test system prompt generation includes all skills."""
        prompt_section = get_skills_for_system_prompt(test_vault)

        assert "Summarizer" in prompt_section
        assert "Code Explainer" in prompt_section
        assert "Brainstorm" in prompt_section
