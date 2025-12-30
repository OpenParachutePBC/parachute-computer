/**
 * Agent Queue
 *
 * Manages the queue of pending, running, and completed agent executions.
 * Simple in-memory implementation with optional JSON persistence.
 */

import fs from 'fs/promises';
import path from 'path';
import crypto from 'crypto';

/**
 * Queue item statuses
 */
export const Status = {
  PENDING: 'pending',
  RUNNING: 'running',
  COMPLETED: 'completed',
  FAILED: 'failed'
};

/**
 * Priority levels
 */
export const Priority = {
  HIGH: 'high',
  NORMAL: 'normal',
  LOW: 'low'
};

const PRIORITY_ORDER = {
  [Priority.HIGH]: 0,
  [Priority.NORMAL]: 1,
  [Priority.LOW]: 2
};

/**
 * Agent Queue class
 */
export class AgentQueue {
  constructor(options = {}) {
    this.items = [];
    this.maxSize = options.maxSize || 100;
    this.persistPath = options.persistPath || null;
    this.keepCompleted = options.keepCompleted || 50; // Keep last N completed
  }

  /**
   * Generate a unique ID
   */
  generateId() {
    return crypto.randomUUID();
  }

  /**
   * Add an item to the queue
   *
   * @param {object} params
   * @returns {QueueItem}
   */
  enqueue({
    agentPath,
    agent,
    context = {},
    priority = Priority.NORMAL,
    depth = 0,
    spawnedBy = null,
    scheduledFor = null
  }) {
    if (this.getPending().length >= this.maxSize) {
      throw new Error('Queue is full');
    }

    const item = {
      id: this.generateId(),
      agentPath,
      agent,
      context,
      priority,
      depth,
      spawnedBy,
      status: Status.PENDING,
      scheduledFor: scheduledFor ? new Date(scheduledFor) : new Date(),
      createdAt: new Date(),
      startedAt: null,
      completedAt: null,
      result: null,
      error: null
    };

    this.items.push(item);
    this.sort();
    this.persist();

    return item;
  }

  /**
   * Get the next item ready to run
   *
   * @returns {QueueItem|null}
   */
  getNext() {
    const now = new Date();

    return this.items.find(item =>
      item.status === Status.PENDING &&
      item.scheduledFor <= now
    ) || null;
  }

  /**
   * Mark an item as running
   *
   * @param {string} id
   * @returns {QueueItem}
   */
  markRunning(id) {
    const item = this.get(id);
    if (!item) throw new Error(`Item ${id} not found`);

    item.status = Status.RUNNING;
    item.startedAt = new Date();
    this.persist();

    return item;
  }

  /**
   * Mark an item as completed
   *
   * @param {string} id
   * @param {object} result
   * @returns {QueueItem}
   */
  markCompleted(id, result) {
    const item = this.get(id);
    if (!item) throw new Error(`Item ${id} not found`);

    item.status = Status.COMPLETED;
    item.completedAt = new Date();
    item.result = result;
    this.cleanup();
    this.persist();

    return item;
  }

  /**
   * Mark an item as failed
   *
   * @param {string} id
   * @param {Error|string} error
   * @returns {QueueItem}
   */
  markFailed(id, error) {
    const item = this.get(id);
    if (!item) throw new Error(`Item ${id} not found`);

    item.status = Status.FAILED;
    item.completedAt = new Date();
    item.error = error instanceof Error ? error.message : error;
    this.persist();

    return item;
  }

  /**
   * Get an item by ID
   *
   * @param {string} id
   * @returns {QueueItem|undefined}
   */
  get(id) {
    return this.items.find(item => item.id === id);
  }

  /**
   * Get all pending items
   *
   * @returns {QueueItem[]}
   */
  getPending() {
    return this.items.filter(item => item.status === Status.PENDING);
  }

  /**
   * Get all running items
   *
   * @returns {QueueItem[]}
   */
  getRunning() {
    return this.items.filter(item => item.status === Status.RUNNING);
  }

  /**
   * Get completed items
   *
   * @param {number} limit
   * @returns {QueueItem[]}
   */
  getCompleted(limit = 10) {
    return this.items
      .filter(item => item.status === Status.COMPLETED)
      .slice(-limit);
  }

  /**
   * Get failed items
   *
   * @param {number} limit
   * @returns {QueueItem[]}
   */
  getFailed(limit = 10) {
    return this.items
      .filter(item => item.status === Status.FAILED)
      .slice(-limit);
  }

  /**
   * Get items spawned by a specific parent
   *
   * @param {string} parentId
   * @returns {QueueItem[]}
   */
  getChildren(parentId) {
    return this.items.filter(item => item.spawnedBy === parentId);
  }

  /**
   * Check if there are pending items ready to run
   *
   * @returns {boolean}
   */
  hasPending() {
    const now = new Date();
    return this.items.some(item =>
      item.status === Status.PENDING &&
      item.scheduledFor <= now
    );
  }

  /**
   * Sort the queue by priority and scheduled time
   */
  sort() {
    this.items.sort((a, b) => {
      // Status: pending first, then running
      if (a.status !== b.status) {
        if (a.status === Status.PENDING) return -1;
        if (b.status === Status.PENDING) return 1;
        if (a.status === Status.RUNNING) return -1;
        if (b.status === Status.RUNNING) return 1;
      }

      // Priority
      const priorityDiff = PRIORITY_ORDER[a.priority] - PRIORITY_ORDER[b.priority];
      if (priorityDiff !== 0) return priorityDiff;

      // Scheduled time
      return new Date(a.scheduledFor) - new Date(b.scheduledFor);
    });
  }

  /**
   * Clean up old completed items
   */
  cleanup() {
    const completed = this.items.filter(
      item => item.status === Status.COMPLETED || item.status === Status.FAILED
    );

    if (completed.length > this.keepCompleted) {
      const toRemove = completed.length - this.keepCompleted;
      const idsToRemove = completed.slice(0, toRemove).map(item => item.id);
      this.items = this.items.filter(item => !idsToRemove.includes(item.id));
    }
  }

  /**
   * Get queue statistics
   *
   * @returns {object}
   */
  getStats() {
    const completed = this.getCompleted(100);

    const totalDuration = completed.reduce((sum, item) => {
      if (item.startedAt && item.completedAt) {
        return sum + (new Date(item.completedAt) - new Date(item.startedAt));
      }
      return sum;
    }, 0);

    const totalCost = completed.reduce((sum, item) => {
      return sum + (item.result?.costUsd || 0);
    }, 0);

    return {
      pending: this.getPending().length,
      running: this.getRunning().length,
      completed: completed.length,
      failed: this.getFailed(100).length,
      avgDurationMs: completed.length > 0 ? totalDuration / completed.length : 0,
      totalCostUsd: totalCost
    };
  }

  /**
   * Get full queue state for API
   *
   * @returns {object}
   */
  getState() {
    return {
      pending: this.getPending(),
      running: this.getRunning(),
      completed: this.getCompleted(10),
      failed: this.getFailed(10),
      stats: this.getStats()
    };
  }

  /**
   * Persist queue to JSON file
   */
  async persist() {
    if (!this.persistPath) return;

    try {
      await fs.mkdir(path.dirname(this.persistPath), { recursive: true });
      await fs.writeFile(
        this.persistPath,
        JSON.stringify(this.items, null, 2),
        'utf-8'
      );
    } catch (e) {
      console.warn('Failed to persist queue:', e.message);
    }
  }

  /**
   * Load queue from JSON file
   */
  async load() {
    if (!this.persistPath) return;

    try {
      const content = await fs.readFile(this.persistPath, 'utf-8');
      const items = JSON.parse(content);

      // Restore dates and reset running items to pending
      this.items = items.map(item => ({
        ...item,
        scheduledFor: new Date(item.scheduledFor),
        createdAt: new Date(item.createdAt),
        startedAt: item.startedAt ? new Date(item.startedAt) : null,
        completedAt: item.completedAt ? new Date(item.completedAt) : null,
        // Reset running to pending (server restart)
        status: item.status === Status.RUNNING ? Status.PENDING : item.status
      }));

      this.sort();
    } catch (e) {
      // No existing queue file
      this.items = [];
    }
  }

  /**
   * Clear all items
   */
  clear() {
    this.items = [];
    this.persist();
  }
}

export default AgentQueue;
