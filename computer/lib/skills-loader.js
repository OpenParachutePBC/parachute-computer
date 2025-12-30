/**
 * Skills Loader
 *
 * Discovers and loads Agent Skills from the vault's .claude/skills/ directory.
 * Skills are filesystem-based packages that Claude can invoke autonomously.
 *
 * Skills follow the Claude Agent SDK standard:
 * - Located in .claude/skills/<skill-name>/SKILL.md
 * - SKILL.md has YAML frontmatter with name, description
 * - Full content loaded only when skill is invoked (progressive disclosure)
 */

import fs from 'fs/promises';
import path from 'path';
import yaml from 'js-yaml';

/**
 * Parse YAML frontmatter from a markdown file
 * @param {string} content - Markdown content
 * @returns {object} { frontmatter, body }
 */
function parseFrontmatter(content) {
  const frontmatterRegex = /^---\s*\n([\s\S]*?)\n---\s*\n?([\s\S]*)$/;
  const match = content.match(frontmatterRegex);

  if (match) {
    try {
      const frontmatter = yaml.load(match[1]) || {};
      const body = match[2];
      return { frontmatter, body };
    } catch (e) {
      console.warn('[Skills] Failed to parse YAML frontmatter:', e.message);
      return { frontmatter: {}, body: content };
    }
  }

  return { frontmatter: {}, body: content };
}

/**
 * Discover all skills in the vault
 * Looks in .claude/skills/ directory
 *
 * @param {string} vaultPath - Path to the vault
 * @returns {Promise<Array>} Array of skill metadata
 */
export async function discoverSkills(vaultPath) {
  const skills = [];
  const skillsDir = path.join(vaultPath, '.claude', 'skills');

  try {
    const entries = await fs.readdir(skillsDir, { withFileTypes: true });

    for (const entry of entries) {
      if (entry.isDirectory()) {
        const skillPath = path.join(skillsDir, entry.name, 'SKILL.md');

        try {
          const content = await fs.readFile(skillPath, 'utf-8');
          const { frontmatter, body } = parseFrontmatter(content);

          skills.push({
            name: frontmatter.name || entry.name,
            description: frontmatter.description || '',
            directory: entry.name,
            path: skillPath,
            // Only load metadata, not full content (progressive disclosure)
            hasAllowedTools: !!frontmatter['allowed-tools'],
            allowedTools: frontmatter['allowed-tools'],
            // Include first 200 chars of body as preview
            preview: body.trim().slice(0, 200) + (body.length > 200 ? '...' : '')
          });
        } catch (e) {
          // SKILL.md doesn't exist or is unreadable
          console.warn(`[Skills] Could not load skill ${entry.name}:`, e.message);
        }
      }
    }

    if (skills.length > 0) {
      console.log(`[Skills] Discovered ${skills.length} skill(s): ${skills.map(s => s.name).join(', ')}`);
    }

    return skills;
  } catch (e) {
    if (e.code === 'ENOENT') {
      // Skills directory doesn't exist - that's fine
      return [];
    }
    console.error('[Skills] Error discovering skills:', e.message);
    return [];
  }
}

/**
 * Load full skill content
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} skillName - Name of the skill directory
 * @returns {Promise<object|null>} Full skill content or null
 */
export async function loadSkill(vaultPath, skillName) {
  const skillPath = path.join(vaultPath, '.claude', 'skills', skillName, 'SKILL.md');

  try {
    const content = await fs.readFile(skillPath, 'utf-8');
    const { frontmatter, body } = parseFrontmatter(content);

    // List additional files in the skill directory
    const skillDir = path.join(vaultPath, '.claude', 'skills', skillName);
    const files = await fs.readdir(skillDir);
    const additionalFiles = files.filter(f => f !== 'SKILL.md');

    return {
      name: frontmatter.name || skillName,
      description: frontmatter.description || '',
      directory: skillName,
      path: skillPath,
      frontmatter,
      body,
      fullContent: content,
      additionalFiles
    };
  } catch (e) {
    console.error(`[Skills] Error loading skill ${skillName}:`, e.message);
    return null;
  }
}

/**
 * Create a new skill
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} skillName - Name for the skill directory
 * @param {object} skillData - Skill data { name, description, content }
 * @returns {Promise<object>} Created skill info
 */
export async function createSkill(vaultPath, skillName, skillData) {
  const skillDir = path.join(vaultPath, '.claude', 'skills', skillName);
  const skillPath = path.join(skillDir, 'SKILL.md');

  // Ensure .claude/skills directory exists
  await fs.mkdir(path.join(vaultPath, '.claude', 'skills'), { recursive: true });

  // Create skill directory
  await fs.mkdir(skillDir, { recursive: true });

  // Build SKILL.md content
  const frontmatter = {
    name: skillData.name || skillName,
    description: skillData.description || ''
  };

  if (skillData.allowedTools) {
    frontmatter['allowed-tools'] = skillData.allowedTools;
  }

  const content = `---
${yaml.dump(frontmatter).trim()}
---

${skillData.content || `# ${frontmatter.name}\n\nAdd your skill instructions here.`}
`;

  await fs.writeFile(skillPath, content, 'utf-8');

  console.log(`[Skills] Created skill: ${skillName} at ${skillPath}`);

  return {
    name: frontmatter.name,
    description: frontmatter.description,
    directory: skillName,
    path: skillPath
  };
}

/**
 * Delete a skill
 *
 * @param {string} vaultPath - Path to the vault
 * @param {string} skillName - Name of the skill directory to delete
 * @returns {Promise<boolean>} True if deleted
 */
export async function deleteSkill(vaultPath, skillName) {
  const skillDir = path.join(vaultPath, '.claude', 'skills', skillName);

  try {
    await fs.rm(skillDir, { recursive: true });
    console.log(`[Skills] Deleted skill: ${skillName}`);
    return true;
  } catch (e) {
    console.error(`[Skills] Error deleting skill ${skillName}:`, e.message);
    return false;
  }
}

/**
 * Ensure the skills directory exists
 *
 * @param {string} vaultPath - Path to the vault
 * @returns {Promise<string>} Path to skills directory
 */
export async function ensureSkillsDir(vaultPath) {
  const skillsDir = path.join(vaultPath, '.claude', 'skills');
  await fs.mkdir(skillsDir, { recursive: true });
  return skillsDir;
}

export default {
  discoverSkills,
  loadSkill,
  createSkill,
  deleteSkill,
  ensureSkillsDir
};
