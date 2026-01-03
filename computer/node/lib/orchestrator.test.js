/**
 * Orchestrator Tests
 *
 * Run with: node --test lib/orchestrator.test.js
 */

import { test, describe, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert';
import fs from 'fs/promises';
import path from 'path';
import { Orchestrator } from './orchestrator.js';

const TEST_VAULT_PATH = '/tmp/test-vault-orchestrator-' + Date.now();

// Create minimal test vault structure
async function setupTestVault() {
  await fs.mkdir(TEST_VAULT_PATH, { recursive: true });
  await fs.mkdir(path.join(TEST_VAULT_PATH, 'agents'), { recursive: true });
  await fs.mkdir(path.join(TEST_VAULT_PATH, '.queue'), { recursive: true });

  // Create a test agent
  const testAgent = `---
agent:
  name: test-agent
  description: A test agent
  type: chatbot
  tools:
    - Read
    - Write
  permissions:
    read: ['*']
    write: ['*']
    spawn: []
    tools:
      - Read
      - Write
---

You are a test agent for unit testing.
`;
  await fs.writeFile(path.join(TEST_VAULT_PATH, 'agents', 'test-agent.md'), testAgent);

  // Create agent with restricted permissions
  const restrictedAgent = `---
agent:
  name: restricted-agent
  description: An agent with restricted permissions
  type: chatbot
  tools:
    - Read
  permissions:
    read: ['docs/*']
    write: ['notes/*']
    spawn: []
    tools:
      - Read
---

You are a restricted agent.
`;
  await fs.writeFile(path.join(TEST_VAULT_PATH, 'agents', 'restricted-agent.md'), restrictedAgent);
}

async function cleanupTestVault() {
  try {
    await fs.rm(TEST_VAULT_PATH, { recursive: true, force: true });
  } catch (e) {
    // Ignore cleanup errors
  }
}

describe('Orchestrator', () => {
  let orchestrator;

  beforeEach(async () => {
    await setupTestVault();
    orchestrator = new Orchestrator(TEST_VAULT_PATH, {
      maxDepth: 3,
      maxConcurrent: 1,
      persistQueue: false  // Don't persist during tests
    });
    await orchestrator.initialize();
  });

  afterEach(async () => {
    // Clean up all intervals
    if (orchestrator.permissionCleanupInterval) {
      clearInterval(orchestrator.permissionCleanupInterval);
    }
    if (orchestrator.triggerCheckInterval) {
      clearInterval(orchestrator.triggerCheckInterval);
    }
    await cleanupTestVault();
  });

  describe('initialization', () => {
    test('initializes with correct config', () => {
      assert.strictEqual(orchestrator.vaultPath, TEST_VAULT_PATH);
      assert.strictEqual(orchestrator.config.maxDepth, 3);
      assert.strictEqual(orchestrator.config.maxConcurrent, 1);
    });

    test('creates session manager', () => {
      assert.ok(orchestrator.sessionManager);
    });

    test('creates queue', () => {
      assert.ok(orchestrator.queue);
    });
  });

  describe('enqueue', () => {
    test('enqueues an agent for execution', async () => {
      const queueId = await orchestrator.enqueue('agents/test-agent.md', {
        userMessage: 'Hello'
      });

      assert.ok(queueId);
      const state = orchestrator.getQueueState();
      assert.ok(state.pending.length > 0 || state.running.length > 0);
    });

    test('throws when max depth exceeded', async () => {
      await assert.rejects(
        async () => orchestrator.enqueue('agents/test-agent.md', {}, { depth: 5 }),
        /Max spawn depth/
      );
    });

    test('throws for non-existent agent', async () => {
      await assert.rejects(
        async () => orchestrator.enqueue('agents/nonexistent.md', {}),
        /ENOENT/
      );
    });
  });

  describe('getAgents', () => {
    test('returns all defined agents', async () => {
      const agents = await orchestrator.getAgents();
      assert.ok(Array.isArray(agents));
      assert.ok(agents.length >= 2);
      assert.ok(agents.some(a => a.name === 'test-agent'));
      assert.ok(agents.some(a => a.name === 'restricted-agent'));
    });
  });

  describe('createVaultAgent', () => {
    test('creates default vault agent', () => {
      const agent = orchestrator.createVaultAgent();

      assert.strictEqual(agent.name, 'vault-agent');
      assert.ok(Array.isArray(agent.tools));
      assert.ok(agent.tools.includes('Read'));
      assert.ok(agent.tools.includes('Write'));
    });
  });

  describe('permission handling', () => {
    test('createPermissionHandler returns a function', async () => {
      const agent = await orchestrator.getAgents().then(a => a[0]);
      const handler = orchestrator.createPermissionHandler(agent, 'test-session');

      assert.strictEqual(typeof handler, 'function');
    });

    test('permission handler allows reads by default', async () => {
      const agents = await orchestrator.getAgents();
      const agent = agents.find(a => a.name === 'test-agent');
      const handler = orchestrator.createPermissionHandler(agent, 'test-session');

      const result = await handler('Read', { file_path: '/some/file.md' }, {});
      assert.strictEqual(result.behavior, 'allow');
    });

    test('grantPermission returns false for non-existent request', () => {
      const result = orchestrator.grantPermission('nonexistent-id');
      assert.strictEqual(result, false);
    });

    test('denyPermission returns false for non-existent request', () => {
      const result = orchestrator.denyPermission('nonexistent-id');
      assert.strictEqual(result, false);
    });

    test('getPendingPermissions returns empty array initially', () => {
      const pending = orchestrator.getPendingPermissions();
      assert.ok(Array.isArray(pending));
      assert.strictEqual(pending.length, 0);
    });

    test('cleanupStalePermissions removes old requests', () => {
      // Add a fake old permission request
      const oldRequest = {
        id: 'old-request',
        timestamp: Date.now() - 10 * 60 * 1000, // 10 minutes ago
        status: 'pending'
      };
      orchestrator.pendingPermissions.set('old-request', oldRequest);

      const cleaned = orchestrator.cleanupStalePermissions(5 * 60 * 1000); // 5 minute max age
      assert.strictEqual(cleaned, 1);
      assert.strictEqual(orchestrator.pendingPermissions.size, 0);
    });
  });

  describe('session management', () => {
    test('listChatSessions returns sessions', () => {
      const sessions = orchestrator.listChatSessions();
      assert.ok(Array.isArray(sessions));
    });

    test('getChatHistory returns messages', () => {
      const history = orchestrator.getChatHistory('agents/test-agent.md');
      assert.ok(Array.isArray(history));
    });

    test('getSessionStats returns stats object', () => {
      const stats = orchestrator.getSessionStats();
      assert.ok(typeof stats === 'object');
    });
  });

  describe('queue management', () => {
    test('getQueueState returns state object', () => {
      const state = orchestrator.getQueueState();
      assert.ok(state);
      assert.ok(Array.isArray(state.pending));
      assert.ok(Array.isArray(state.running));
      assert.ok(Array.isArray(state.completed));
    });

    test('getQueueStream creates event emitter', () => {
      const stream = orchestrator.getQueueStream('test-id');
      assert.ok(stream);
      assert.strictEqual(typeof stream.on, 'function');
      assert.strictEqual(typeof stream.emit, 'function');
    });

    test('cleanupQueueStream removes stream', () => {
      orchestrator.getQueueStream('test-id');
      assert.ok(orchestrator.queueStreams.has('test-id'));

      orchestrator.cleanupQueueStream('test-id');
      assert.ok(!orchestrator.queueStreams.has('test-id'));
    });
  });

  describe('parseSpawnRequests', () => {
    test('parses valid spawn block', () => {
      const response = `
Here is some text.

\`\`\`spawn
{"agent": "agents/test-agent.md", "message": "Do something"}
\`\`\`

More text.
`;
      const agent = {
        permissions: { spawn: ['agents/*'] }
      };

      const requests = orchestrator.parseSpawnRequests(response, agent, 0);
      assert.strictEqual(requests.length, 1);
      assert.strictEqual(requests[0].agent, 'agents/test-agent.md');
      assert.strictEqual(requests[0].message, 'Do something');
    });

    test('ignores spawn requests without permission', () => {
      const response = `
\`\`\`spawn
{"agent": "agents/test-agent.md", "message": "Do something"}
\`\`\`
`;
      const agent = {
        permissions: { spawn: [] }  // No spawn permissions
      };

      const requests = orchestrator.parseSpawnRequests(response, agent, 0);
      assert.strictEqual(requests.length, 0);
    });

    test('handles invalid JSON gracefully', () => {
      const response = `
\`\`\`spawn
{invalid json}
\`\`\`
`;
      const agent = {
        permissions: { spawn: ['agents/*'] }
      };

      const requests = orchestrator.parseSpawnRequests(response, agent, 0);
      assert.strictEqual(requests.length, 0);
    });

    test('parses multiple spawn blocks', () => {
      const response = `
\`\`\`spawn
{"agent": "agents/agent1.md", "message": "Task 1"}
\`\`\`

\`\`\`spawn
{"agent": "agents/agent2.md", "message": "Task 2"}
\`\`\`
`;
      const agent = {
        permissions: { spawn: ['agents/*'] }
      };

      const requests = orchestrator.parseSpawnRequests(response, agent, 0);
      assert.strictEqual(requests.length, 2);
    });
  });

  describe('MCP server management', () => {
    test('listMcpServers returns array or object', async () => {
      const servers = await orchestrator.listMcpServers();
      assert.ok(servers !== undefined);
    });
  });

  describe('document operations', () => {
    test('listVaultFiles returns markdown files', async () => {
      // Add a test markdown file
      await fs.writeFile(path.join(TEST_VAULT_PATH, 'test-doc.md'), '# Test');

      const files = await orchestrator.listVaultFiles();
      assert.ok(Array.isArray(files));
      assert.ok(files.some(f => f.endsWith('.md')));
    });

    test('readDocument returns document content', async () => {
      await fs.writeFile(
        path.join(TEST_VAULT_PATH, 'test-doc.md'),
        '---\ntitle: Test\n---\n\n# Test Document\n\nContent here.'
      );

      const doc = await orchestrator.readDocument('test-doc.md');
      assert.ok(doc);
      assert.ok(doc.body.includes('Test Document'));
    });

    test('readDocument returns null for missing file', async () => {
      const doc = await orchestrator.readDocument('nonexistent.md');
      assert.strictEqual(doc, null);
    });
  });
});

describe('Orchestrator Events', () => {
  let orchestrator;

  beforeEach(async () => {
    await setupTestVault();
    orchestrator = new Orchestrator(TEST_VAULT_PATH, {
      persistQueue: false
    });
    await orchestrator.initialize();
  });

  afterEach(async () => {
    if (orchestrator.permissionCleanupInterval) {
      clearInterval(orchestrator.permissionCleanupInterval);
    }
    if (orchestrator.triggerCheckInterval) {
      clearInterval(orchestrator.triggerCheckInterval);
    }
    await cleanupTestVault();
  });

  test('emits permissionRequest event', async () => {
    let eventReceived = false;
    orchestrator.on('permissionRequest', () => {
      eventReceived = true;
    });

    // Simulate a permission request
    orchestrator.emit('permissionRequest', { id: 'test' });
    assert.ok(eventReceived);
  });

  test('emits permissionGranted event', async () => {
    let eventReceived = false;
    orchestrator.on('permissionGranted', () => {
      eventReceived = true;
    });

    // Add a pending permission
    orchestrator.pendingPermissions.set('test-id', {
      id: 'test-id',
      status: 'pending',
      resolve: () => {}
    });

    orchestrator.grantPermission('test-id');
    assert.ok(eventReceived);
  });

  test('emits permissionDenied event', async () => {
    let eventReceived = false;
    orchestrator.on('permissionDenied', () => {
      eventReceived = true;
    });

    // Add a pending permission
    orchestrator.pendingPermissions.set('test-id', {
      id: 'test-id',
      status: 'pending',
      resolve: () => {}
    });

    orchestrator.denyPermission('test-id');
    assert.ok(eventReceived);
  });
});
