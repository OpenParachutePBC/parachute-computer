#!/usr/bin/env node
/**
 * Vault Migration Utility
 *
 * Migrates existing Parachute vaults from legacy structure:
 *
 * Legacy folders (migrated):
 *   - agent-sessions/  → Chat/sessions/
 *   - agent-chats/     → Chat/sessions/legacy/
 *   - agent-logs/      → Chat/sessions/legacy/
 *   - captures/        → assets/
 *
 * Current structure (created if missing):
 *   ~/Parachute/
 *   ├── Daily/
 *   │   └── journals/        # Daily journal entries
 *   ├── Chat/
 *   │   └── sessions/        # Chat sessions (markdown)
 *   ├── assets/              # All media (audio, images)
 *   ├── contexts/            # User context files for AI
 *   ├── .agents/             # Agent definitions
 *   └── AGENTS.md            # System prompt
 *
 * Usage:
 *   node scripts/migrate-vault.js ~/Parachute
 *   node scripts/migrate-vault.js ~/Parachute --dry-run
 */

import fs from 'fs/promises';
import path from 'path';

const MIGRATIONS = [
  {
    name: 'Chat sessions',
    from: 'agent-sessions',
    to: 'Chat/sessions',
    description: 'Move chat sessions to Chat module'
  },
  {
    name: 'Legacy chat logs',
    from: 'agent-chats',
    to: 'Chat/sessions/legacy',
    description: 'Move legacy chat files to Chat module'
  },
  {
    name: 'Legacy agent logs',
    from: 'agent-logs',
    to: 'Chat/sessions/legacy',
    description: 'Move legacy agent logs to Chat module'
  },
  {
    name: 'Voice captures',
    from: 'captures',
    to: 'assets',
    description: 'Move voice captures to assets folder'
  }
];

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function copyDir(src, dest) {
  await fs.mkdir(dest, { recursive: true });
  const entries = await fs.readdir(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      await copyDir(srcPath, destPath);
    } else {
      await fs.copyFile(srcPath, destPath);
    }
  }
}

async function migrate(vaultPath, dryRun = false) {
  console.log(`\n🪂 Parachute Vault Migration\n`);
  console.log(`Vault: ${vaultPath}`);
  console.log(`Mode: ${dryRun ? 'DRY RUN (no changes)' : 'LIVE'}\n`);

  // Verify vault exists
  if (!await fileExists(vaultPath)) {
    console.error(`❌ Vault not found: ${vaultPath}`);
    process.exit(1);
  }

  // Create module directories
  const moduleDirs = ['Daily', 'Daily/journals', 'Chat', 'Chat/sessions', 'assets', 'contexts'];

  console.log('📁 Creating module directories...\n');
  for (const dir of moduleDirs) {
    const fullPath = path.join(vaultPath, dir);
    if (!await fileExists(fullPath)) {
      console.log(`  Creating ${dir}/`);
      if (!dryRun) {
        await fs.mkdir(fullPath, { recursive: true });
      }
    } else {
      console.log(`  ${dir}/ already exists`);
    }
  }

  console.log('\n📦 Migrating data...\n');

  let migratedCount = 0;
  let skippedCount = 0;

  for (const migration of MIGRATIONS) {
    const srcPath = path.join(vaultPath, migration.from);
    const destPath = path.join(vaultPath, migration.to);

    if (!await fileExists(srcPath)) {
      console.log(`  ⏭️  ${migration.name}: Source not found (${migration.from}/)`);
      skippedCount++;
      continue;
    }

    if (await fileExists(destPath)) {
      // Check if destination has files
      const destEntries = await fs.readdir(destPath);
      if (destEntries.length > 0) {
        console.log(`  ⚠️  ${migration.name}: Destination not empty (${migration.to}/)`);
        console.log(`      Merge manually if needed`);
        skippedCount++;
        continue;
      }
    }

    console.log(`  ✓ ${migration.name}`);
    console.log(`      ${migration.from}/ → ${migration.to}/`);

    if (!dryRun) {
      await copyDir(srcPath, destPath);
    }

    migratedCount++;
  }

  console.log(`\n📊 Summary:`);
  console.log(`   Migrated: ${migratedCount}`);
  console.log(`   Skipped: ${skippedCount}`);

  if (dryRun) {
    console.log(`\n💡 This was a dry run. Run without --dry-run to apply changes.`);
  } else {
    console.log(`\n✅ Migration complete!`);
    console.log(`\n⚠️  Note: Original files were COPIED, not moved.`);
    console.log(`   Review the migration, then delete old directories manually:`);
    for (const migration of MIGRATIONS) {
      const srcPath = path.join(vaultPath, migration.from);
      if (await fileExists(srcPath)) {
        console.log(`   rm -rf "${srcPath}"`);
      }
    }
  }
}

// CLI
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const vaultPath = args.find(arg => !arg.startsWith('--'));

if (!vaultPath) {
  console.log(`
Usage: node scripts/migrate-vault.js <vault-path> [--dry-run]

Examples:
  node scripts/migrate-vault.js ~/Parachute
  node scripts/migrate-vault.js ~/Parachute --dry-run

Options:
  --dry-run    Show what would be done without making changes
`);
  process.exit(1);
}

migrate(path.resolve(vaultPath), dryRun).catch(err => {
  console.error('Migration failed:', err);
  process.exit(1);
});
