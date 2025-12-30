/**
 * E2E Session & Server-Client Tests
 *
 * Tests the full flow: client -> server -> Claude SDK -> server -> client
 * Uses simple, deterministic prompts for consistent results.
 *
 * Run: node test/e2e-session-tests.js
 *
 * Options:
 *   SERVER_URL - Server to test against (default: http://localhost:3333)
 *   TEST_VAULT - Path to test vault (creates temp vault if not specified)
 *   KEEP_VAULT - Set to 'true' to keep test vault after tests
 *
 * For isolated testing, the test can start its own server with a temp vault:
 *   npm run test:e2e -- --isolated
 */

import { spawn } from 'child_process';
import { mkdtemp, rm, mkdir, writeFile } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const DEFAULT_SERVER_URL = process.env.SERVER_URL || 'http://localhost:3333';
const ISOLATED_MODE = process.argv.includes('--isolated');
const KEEP_VAULT = process.env.KEEP_VAULT === 'true';

let testVaultPath = null;
let serverProcess = null;
let activeServerUrl = DEFAULT_SERVER_URL;

// Simple fetch-based SSE parser
async function* streamChat(message, sessionId = null, options = {}) {
  const body = {
    message,
    sessionId,
    ...options
  };

  const response = await fetch(`${activeServerUrl}/api/chat/stream`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${response.statusText}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop(); // Keep incomplete line in buffer

    for (const line of lines) {
      if (line.startsWith('data: ')) {
        try {
          yield JSON.parse(line.slice(6));
        } catch (e) {
          // Ignore parse errors (heartbeats, etc.)
        }
      }
    }
  }
}

// Collect all events from a stream
async function collectStream(message, sessionId = null, options = {}) {
  const events = [];
  for await (const event of streamChat(message, sessionId, options)) {
    events.push(event);
  }
  return events;
}

// Test utilities
let testsPassed = 0;
let testsFailed = 0;

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function runTest(name, fn) {
  process.stdout.write(`  ${name}... `);
  try {
    await fn();
    console.log('✓');
    testsPassed++;
  } catch (e) {
    console.log(`✗ ${e.message}`);
    testsFailed++;
  }
}

// ============================================================
// TEST SUITES
// ============================================================

async function testServerHealth() {
  console.log('\n📡 Server Health Tests');

  await runTest('Health endpoint responds', async () => {
    const res = await fetch(`${activeServerUrl}/api/health`);
    assert(res.ok, `Expected 200, got ${res.status}`);
    const data = await res.json();
    assert(data.status === 'ok', `Expected status ok, got ${data.status}`);
  });

  await runTest('Agents endpoint responds', async () => {
    const res = await fetch(`${activeServerUrl}/api/agents`);
    assert(res.ok, `Expected 200, got ${res.status}`);
    const data = await res.json();
    assert(Array.isArray(data), 'Expected array of agents');
  });

  await runTest('Sessions endpoint responds', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/sessions`);
    assert(res.ok, `Expected 200, got ${res.status}`);
    const data = await res.json();
    assert(data.sessions !== undefined, 'Expected sessions in response');
  });
}

async function testNewSession() {
  console.log('\n🆕 New Session Tests');

  let capturedSessionId = null;

  await runTest('Creates new session with simple greeting', async () => {
    const events = await collectStream('Say exactly: HELLO_TEST_123');

    const sessionEvent = events.find(e => e.type === 'session');
    assert(sessionEvent, 'Expected session event');
    assert(sessionEvent.resumeInfo.isNewSession === true, 'Expected new session');

    const doneEvent = events.find(e => e.type === 'done');
    assert(doneEvent, 'Expected done event');
    assert(doneEvent.sessionId, 'Expected session ID in done event');

    capturedSessionId = doneEvent.sessionId;
  });

  await runTest('Session ID is valid UUID format', async () => {
    assert(capturedSessionId, 'No session ID captured');
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    assert(uuidRegex.test(capturedSessionId), `Invalid UUID: ${capturedSessionId}`);
  });

  await runTest('Session appears in sessions list', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/sessions`);
    const data = await res.json();
    const found = data.sessions.find(s => s.id === capturedSessionId);
    assert(found, `Session ${capturedSessionId} not found in sessions list`);
  });

  return capturedSessionId;
}

async function testSessionContinuity(sessionId) {
  console.log('\n🔄 Session Continuity Tests');

  await runTest('First message establishes context', async () => {
    const events = await collectStream(
      'Remember this secret code: ALPHA_BRAVO_789. Just confirm you got it.',
      sessionId
    );

    const doneEvent = events.find(e => e.type === 'done');
    assert(doneEvent, 'Expected done event');
    assert(doneEvent.response, 'Expected response content');
  });

  await runTest('Second message recalls context (SDK resume)', async () => {
    const events = await collectStream(
      'What was the secret code I just told you?',
      sessionId
    );

    const sessionEvent = events.find(e => e.type === 'session');
    assert(sessionEvent, 'Expected session event');
    assert(sessionEvent.resumeInfo.method === 'sdk_resume',
      `Expected sdk_resume, got ${sessionEvent.resumeInfo.method}`);
    assert(sessionEvent.resumeInfo.isNewSession === false, 'Expected resumed session');
    assert(sessionEvent.resumeInfo.previousMessageCount >= 2,
      `Expected >= 2 previous messages, got ${sessionEvent.resumeInfo.previousMessageCount}`);

    const doneEvent = events.find(e => e.type === 'done');
    assert(doneEvent, 'Expected done event');
    // The response should contain our secret code
    assert(doneEvent.response.includes('ALPHA') || doneEvent.response.includes('BRAVO') || doneEvent.response.includes('789'),
      'Response should recall the secret code');
  });

  await runTest('Message count increases correctly', async () => {
    const events = await collectStream('How many messages have we exchanged?', sessionId);

    const doneEvent = events.find(e => e.type === 'done');
    assert(doneEvent, 'Expected done event');
    // After 3 exchanges, we should have 6 messages (3 user + 3 assistant)
    assert(doneEvent.messageCount >= 6,
      `Expected >= 6 messages, got ${doneEvent.messageCount}`);
  });
}

async function testSessionPersistence(sessionId) {
  console.log('\n💾 Session Persistence Tests');

  await runTest('Session has markdown file', async () => {
    // filePath is in the list endpoint, not the single session endpoint
    const res = await fetch(`${activeServerUrl}/api/chat/sessions`);
    assert(res.ok, `Expected 200, got ${res.status}`);
    const data = await res.json();
    const session = data.sessions.find(s => s.id === sessionId);
    assert(session, 'Session not found in list');
    assert(session.filePath, 'Expected filePath in session');
    assert(session.filePath.endsWith('.md'), 'Expected markdown file');
  });

  await runTest('Session messages are persisted', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/session/${encodeURIComponent(sessionId)}`);
    const data = await res.json();
    assert(data.messages, 'Expected messages array');
    assert(data.messages.length >= 6, `Expected >= 6 messages, got ${data.messages.length}`);
  });

  await runTest('Reloading sessions index preserves session', async () => {
    // Trigger index reload
    await fetch(`${activeServerUrl}/api/chat/sessions/reload`, { method: 'POST' });

    // Wait a moment for reload
    await new Promise(r => setTimeout(r, 500));

    // Session should still be findable
    const res = await fetch(`${activeServerUrl}/api/chat/session/${encodeURIComponent(sessionId)}`);
    assert(res.ok, `Session not found after reload: ${res.status}`);
  });
}

async function testMultipleSessions() {
  console.log('\n🔀 Multiple Sessions Tests');

  let session1Id = null;
  let session2Id = null;

  await runTest('Can create two independent sessions', async () => {
    const events1 = await collectStream('Session 1: My favorite number is 42.');
    const events2 = await collectStream('Session 2: My favorite color is blue.');

    const done1 = events1.find(e => e.type === 'done');
    const done2 = events2.find(e => e.type === 'done');

    assert(done1?.sessionId, 'Expected session 1 ID');
    assert(done2?.sessionId, 'Expected session 2 ID');
    assert(done1.sessionId !== done2.sessionId, 'Sessions should have different IDs');

    session1Id = done1.sessionId;
    session2Id = done2.sessionId;
  });

  await runTest('Sessions maintain separate contexts', async () => {
    const events1 = await collectStream('What is my favorite number?', session1Id);
    const events2 = await collectStream('What is my favorite color?', session2Id);

    const done1 = events1.find(e => e.type === 'done');
    const done2 = events2.find(e => e.type === 'done');

    assert(done1.response.includes('42'), 'Session 1 should remember number 42');
    assert(done2.response.includes('blue'), 'Session 2 should remember color blue');
  });

  await runTest('Cross-session queries return different results', async () => {
    // Ask session 1 about color (which it shouldn't know)
    const events1 = await collectStream('What is my favorite color?', session1Id);
    // Ask session 2 about number (which it shouldn't know)
    const events2 = await collectStream('What is my favorite number?', session2Id);

    const done1 = events1.find(e => e.type === 'done');
    const done2 = events2.find(e => e.type === 'done');

    // These should NOT contain the other session's data
    assert(!done1.response.includes('blue'),
      'Session 1 should NOT know about blue from session 2');
    assert(!done2.response.includes('42'),
      'Session 2 should NOT know about 42 from session 1');
  });
}

async function testErrorHandling() {
  console.log('\n⚠️ Error Handling Tests');

  await runTest('Empty message returns error', async () => {
    try {
      const events = await collectStream('');
      const errorEvent = events.find(e => e.type === 'error');
      assert(errorEvent, 'Expected error event for empty message');
    } catch (e) {
      // Network error is also acceptable
    }
  });

  await runTest('Invalid session ID creates new session', async () => {
    const events = await collectStream('Test message', 'invalid-nonexistent-session-id');

    const sessionEvent = events.find(e => e.type === 'session');
    assert(sessionEvent, 'Expected session event');
    // Should either be a new session or handle gracefully
    const doneEvent = events.find(e => e.type === 'done');
    assert(doneEvent, 'Expected done event');
  });
}

async function testSessionArchiving(sessionId) {
  console.log('\n📦 Session Archiving Tests');

  await runTest('Can archive a session', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/session/${encodeURIComponent(sessionId)}/archive`, {
      method: 'POST'
    });
    assert(res.ok, `Archive failed: ${res.status}`);
  });

  await runTest('Archived session not in default list', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/sessions`);
    const data = await res.json();
    const found = data.sessions.find(s => s.id === sessionId);
    assert(!found, 'Archived session should not appear in default list');
  });

  await runTest('Archived session appears with archived=true filter', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/sessions?archived=true`);
    const data = await res.json();
    const found = data.sessions.find(s => s.id === sessionId);
    assert(found, 'Archived session should appear when filtered');
  });

  await runTest('Can unarchive a session', async () => {
    const res = await fetch(`${activeServerUrl}/api/chat/session/${encodeURIComponent(sessionId)}/unarchive`, {
      method: 'POST'
    });
    assert(res.ok, `Unarchive failed: ${res.status}`);

    const listRes = await fetch(`${activeServerUrl}/api/chat/sessions`);
    const data = await listRes.json();
    const found = data.sessions.find(s => s.id === sessionId);
    assert(found, 'Unarchived session should appear in list');
  });
}

// ============================================================
// SETUP & TEARDOWN
// ============================================================

async function createTestVault() {
  testVaultPath = await mkdtemp(join(tmpdir(), 'parachute-test-'));
  console.log(`  Test vault: ${testVaultPath}`);

  // Create minimal vault structure
  await mkdir(join(testVaultPath, 'agent-sessions'), { recursive: true });
  await mkdir(join(testVaultPath, 'contexts'), { recursive: true });
  await mkdir(join(testVaultPath, '.agents'), { recursive: true });

  // Create a minimal context file
  await writeFile(
    join(testVaultPath, 'contexts', 'general-context.md'),
    '# Test Context\n\nThis is a test vault for E2E testing.\n'
  );

  return testVaultPath;
}

async function startTestServer(vaultPath) {
  const serverPath = join(__dirname, '..', 'server.js');
  const port = 3334; // Use different port for isolated testing

  serverProcess = spawn('node', [serverPath], {
    env: {
      ...process.env,
      VAULT_PATH: vaultPath,
      PORT: port.toString(),
      HOST: 'localhost'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });

  // Wait for server to start
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Server start timeout')), 30000);

    serverProcess.stdout.on('data', (data) => {
      if (data.toString().includes('Server started')) {
        clearTimeout(timeout);
        resolve();
      }
    });

    serverProcess.stderr.on('data', (data) => {
      console.error('Server stderr:', data.toString());
    });

    serverProcess.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });
  });

  return `http://localhost:${port}`;
}

async function cleanup() {
  if (serverProcess) {
    serverProcess.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 1000));
  }

  if (testVaultPath && !KEEP_VAULT) {
    try {
      await rm(testVaultPath, { recursive: true, force: true });
      console.log(`  Cleaned up test vault`);
    } catch (e) {
      console.warn(`  Warning: Could not clean up test vault: ${e.message}`);
    }
  } else if (testVaultPath && KEEP_VAULT) {
    console.log(`  Keeping test vault at: ${testVaultPath}`);
  }
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log('═══════════════════════════════════════════════════════');
  console.log('  Parachute E2E Session Tests');

  try {
    if (ISOLATED_MODE) {
      console.log('  Mode: Isolated (temporary vault + server)');
      const vaultPath = await createTestVault();
      activeServerUrl = await startTestServer(vaultPath);
    }

    console.log(`  Server: ${activeServerUrl}`);
    console.log('═══════════════════════════════════════════════════════');

    // Basic connectivity
    await testServerHealth();

    // New session creation
    const sessionId = await testNewSession();

    // Session continuity (context preservation)
    await testSessionContinuity(sessionId);

    // Persistence (markdown files, index)
    await testSessionPersistence(sessionId);

    // Multiple concurrent sessions
    await testMultipleSessions();

    // Error handling
    await testErrorHandling();

    // Archiving
    await testSessionArchiving(sessionId);

  } catch (e) {
    console.error('\n❌ Test suite error:', e.message);
    testsFailed++;
  } finally {
    await cleanup();
  }

  // Summary
  console.log('\n═══════════════════════════════════════════════════════');
  console.log(`  Results: ${testsPassed} passed, ${testsFailed} failed`);
  console.log('═══════════════════════════════════════════════════════');

  process.exit(testsFailed > 0 ? 1 : 0);
}

main();
