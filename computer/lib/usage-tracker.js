/**
 * Token Usage Tracker
 *
 * Tracks API token usage per session, agent, and globally.
 * Stores usage data in memory with periodic persistence to disk.
 */

import fs from 'fs/promises';
import path from 'path';

/**
 * Usage data structure
 */
const DEFAULT_USAGE = {
  inputTokens: 0,
  outputTokens: 0,
  totalTokens: 0,
  requestCount: 0,
  cacheCreationInputTokens: 0,
  cacheReadInputTokens: 0
};

/**
 * Usage Tracker class
 */
export class UsageTracker {
  constructor(vaultPath, options = {}) {
    this.vaultPath = vaultPath;
    this.usageFilePath = path.join(vaultPath, '.usage', 'usage.json');

    // In-memory usage data
    this.global = { ...DEFAULT_USAGE };
    this.bySession = new Map();  // sessionId -> usage
    this.byAgent = new Map();    // agentPath -> usage
    this.byDay = new Map();      // YYYY-MM-DD -> usage

    // Track hourly for rate limiting
    this.hourlyUsage = new Map(); // hour timestamp -> usage

    // Persistence interval (default 5 minutes)
    this.persistIntervalMs = options.persistIntervalMs || 5 * 60 * 1000;
    this.persistInterval = null;

    // Cost estimation (default Claude pricing)
    this.costPerInputToken = options.costPerInputToken || 0.000003;  // $3/M input
    this.costPerOutputToken = options.costPerOutputToken || 0.000015; // $15/M output
  }

  /**
   * Initialize tracker and load persisted data
   */
  async initialize() {
    await this.load();
    this.startPersistLoop();
  }

  /**
   * Load usage data from disk
   */
  async load() {
    try {
      const data = await fs.readFile(this.usageFilePath, 'utf-8');
      const parsed = JSON.parse(data);

      this.global = { ...DEFAULT_USAGE, ...parsed.global };

      // Restore maps
      if (parsed.bySession) {
        for (const [key, value] of Object.entries(parsed.bySession)) {
          this.bySession.set(key, { ...DEFAULT_USAGE, ...value });
        }
      }
      if (parsed.byAgent) {
        for (const [key, value] of Object.entries(parsed.byAgent)) {
          this.byAgent.set(key, { ...DEFAULT_USAGE, ...value });
        }
      }
      if (parsed.byDay) {
        for (const [key, value] of Object.entries(parsed.byDay)) {
          this.byDay.set(key, { ...DEFAULT_USAGE, ...value });
        }
      }

      console.log(`[UsageTracker] Loaded usage data: ${this.global.totalTokens} total tokens`);
    } catch (e) {
      // No existing data or parse error
      console.log('[UsageTracker] Starting with fresh usage data');
    }
  }

  /**
   * Save usage data to disk
   */
  async save() {
    try {
      await fs.mkdir(path.dirname(this.usageFilePath), { recursive: true });

      const data = {
        global: this.global,
        bySession: Object.fromEntries(this.bySession),
        byAgent: Object.fromEntries(this.byAgent),
        byDay: Object.fromEntries(this.byDay),
        lastSaved: new Date().toISOString()
      };

      await fs.writeFile(this.usageFilePath, JSON.stringify(data, null, 2));
    } catch (e) {
      console.error('[UsageTracker] Failed to save usage data:', e.message);
    }
  }

  /**
   * Start periodic persistence loop
   */
  startPersistLoop() {
    this.persistInterval = setInterval(() => this.save(), this.persistIntervalMs);
  }

  /**
   * Stop persistence loop
   */
  stopPersistLoop() {
    if (this.persistInterval) {
      clearInterval(this.persistInterval);
      this.persistInterval = null;
    }
  }

  /**
   * Record token usage from an API response
   *
   * @param {object} usage - Usage object from API response
   * @param {string} sessionId - Session ID
   * @param {string} agentPath - Agent path
   */
  recordUsage(usage, sessionId = null, agentPath = null) {
    if (!usage) return;

    const inputTokens = usage.input_tokens || 0;
    const outputTokens = usage.output_tokens || 0;
    const cacheCreation = usage.cache_creation_input_tokens || 0;
    const cacheRead = usage.cache_read_input_tokens || 0;

    const record = {
      inputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      requestCount: 1,
      cacheCreationInputTokens: cacheCreation,
      cacheReadInputTokens: cacheRead
    };

    // Update global
    this.addToUsage(this.global, record);

    // Update session
    if (sessionId) {
      if (!this.bySession.has(sessionId)) {
        this.bySession.set(sessionId, { ...DEFAULT_USAGE });
      }
      this.addToUsage(this.bySession.get(sessionId), record);
    }

    // Update agent
    if (agentPath) {
      if (!this.byAgent.has(agentPath)) {
        this.byAgent.set(agentPath, { ...DEFAULT_USAGE });
      }
      this.addToUsage(this.byAgent.get(agentPath), record);
    }

    // Update daily
    const today = new Date().toISOString().split('T')[0];
    if (!this.byDay.has(today)) {
      this.byDay.set(today, { ...DEFAULT_USAGE });
    }
    this.addToUsage(this.byDay.get(today), record);

    // Update hourly (for rate limiting)
    const hourKey = Math.floor(Date.now() / 3600000);
    if (!this.hourlyUsage.has(hourKey)) {
      this.hourlyUsage.set(hourKey, { ...DEFAULT_USAGE });
      // Clean up old hourly data (keep last 24 hours)
      this.cleanupHourlyData();
    }
    this.addToUsage(this.hourlyUsage.get(hourKey), record);
  }

  /**
   * Add usage record to existing usage object
   */
  addToUsage(target, record) {
    target.inputTokens += record.inputTokens;
    target.outputTokens += record.outputTokens;
    target.totalTokens += record.totalTokens;
    target.requestCount += record.requestCount;
    target.cacheCreationInputTokens += record.cacheCreationInputTokens;
    target.cacheReadInputTokens += record.cacheReadInputTokens;
  }

  /**
   * Clean up hourly data older than 24 hours
   */
  cleanupHourlyData() {
    const cutoff = Math.floor(Date.now() / 3600000) - 24;
    for (const [key] of this.hourlyUsage) {
      if (key < cutoff) {
        this.hourlyUsage.delete(key);
      }
    }
  }

  /**
   * Get global usage statistics
   */
  getGlobalStats() {
    return {
      ...this.global,
      estimatedCost: this.estimateCost(this.global)
    };
  }

  /**
   * Get usage for a specific session
   */
  getSessionUsage(sessionId) {
    const usage = this.bySession.get(sessionId) || { ...DEFAULT_USAGE };
    return {
      ...usage,
      estimatedCost: this.estimateCost(usage)
    };
  }

  /**
   * Get usage for a specific agent
   */
  getAgentUsage(agentPath) {
    const usage = this.byAgent.get(agentPath) || { ...DEFAULT_USAGE };
    return {
      ...usage,
      estimatedCost: this.estimateCost(usage)
    };
  }

  /**
   * Get usage for today
   */
  getTodayUsage() {
    const today = new Date().toISOString().split('T')[0];
    const usage = this.byDay.get(today) || { ...DEFAULT_USAGE };
    return {
      ...usage,
      date: today,
      estimatedCost: this.estimateCost(usage)
    };
  }

  /**
   * Get usage by day for the last N days
   */
  getDailyUsage(days = 30) {
    const result = [];
    const now = new Date();

    for (let i = 0; i < days; i++) {
      const date = new Date(now);
      date.setDate(date.getDate() - i);
      const dateStr = date.toISOString().split('T')[0];
      const usage = this.byDay.get(dateStr) || { ...DEFAULT_USAGE };
      result.push({
        date: dateStr,
        ...usage,
        estimatedCost: this.estimateCost(usage)
      });
    }

    return result;
  }

  /**
   * Get hourly usage for the last N hours
   */
  getHourlyUsage(hours = 24) {
    const result = [];
    const currentHour = Math.floor(Date.now() / 3600000);

    for (let i = 0; i < hours; i++) {
      const hourKey = currentHour - i;
      const usage = this.hourlyUsage.get(hourKey) || { ...DEFAULT_USAGE };
      result.push({
        hour: hourKey,
        timestamp: hourKey * 3600000,
        ...usage
      });
    }

    return result;
  }

  /**
   * Get top agents by usage
   */
  getTopAgents(limit = 10) {
    const agents = Array.from(this.byAgent.entries())
      .map(([path, usage]) => ({
        agentPath: path,
        ...usage,
        estimatedCost: this.estimateCost(usage)
      }))
      .sort((a, b) => b.totalTokens - a.totalTokens)
      .slice(0, limit);

    return agents;
  }

  /**
   * Get usage summary
   */
  getSummary() {
    const today = this.getTodayUsage();
    const currentHour = Math.floor(Date.now() / 3600000);
    const hourUsage = this.hourlyUsage.get(currentHour) || { ...DEFAULT_USAGE };

    return {
      total: this.getGlobalStats(),
      today,
      thisHour: {
        ...hourUsage,
        estimatedCost: this.estimateCost(hourUsage)
      },
      activeSessions: this.bySession.size,
      activeAgents: this.byAgent.size,
      topAgents: this.getTopAgents(5)
    };
  }

  /**
   * Estimate cost for usage
   */
  estimateCost(usage) {
    const inputCost = usage.inputTokens * this.costPerInputToken;
    const outputCost = usage.outputTokens * this.costPerOutputToken;
    return Math.round((inputCost + outputCost) * 10000) / 10000; // Round to 4 decimal places
  }

  /**
   * Reset all usage data
   */
  async reset() {
    this.global = { ...DEFAULT_USAGE };
    this.bySession.clear();
    this.byAgent.clear();
    this.byDay.clear();
    this.hourlyUsage.clear();
    await this.save();
  }

  /**
   * Cleanup and save on shutdown
   */
  async shutdown() {
    this.stopPersistLoop();
    await this.save();
  }
}

// Singleton instance
let instance = null;

/**
 * Get or create the usage tracker instance
 */
export function getUsageTracker(vaultPath) {
  if (!instance && vaultPath) {
    instance = new UsageTracker(vaultPath);
  }
  return instance;
}

/**
 * Initialize the usage tracker (called from server startup)
 */
export async function initializeUsageTracker(vaultPath) {
  instance = new UsageTracker(vaultPath);
  await instance.initialize();
  return instance;
}

export default UsageTracker;
