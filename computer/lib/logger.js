/**
 * Structured Logger
 *
 * Provides structured logging with levels, timestamps, and in-memory buffer
 * for recent logs retrieval via API.
 */

/**
 * Log levels in order of severity
 */
export const LogLevel = {
  DEBUG: 0,
  INFO: 1,
  WARN: 2,
  ERROR: 3
};

const LEVEL_NAMES = ['DEBUG', 'INFO', 'WARN', 'ERROR'];

/**
 * In-memory circular buffer for recent logs
 */
class LogBuffer {
  constructor(maxSize = 1000) {
    this.maxSize = maxSize;
    this.logs = [];
  }

  add(entry) {
    this.logs.push(entry);
    if (this.logs.length > this.maxSize) {
      this.logs.shift();
    }
  }

  getAll() {
    return [...this.logs];
  }

  getLast(n = 100) {
    return this.logs.slice(-n);
  }

  getByLevel(level, limit = 100) {
    const levelNum = typeof level === 'string' ? LogLevel[level.toUpperCase()] : level;
    return this.logs
      .filter(log => log.level >= levelNum)
      .slice(-limit);
  }

  getByComponent(component, limit = 100) {
    return this.logs
      .filter(log => log.component === component)
      .slice(-limit);
  }

  getSince(timestamp, limit = 500) {
    const ts = typeof timestamp === 'string' ? new Date(timestamp).getTime() : timestamp;
    return this.logs
      .filter(log => log.timestamp >= ts)
      .slice(-limit);
  }

  clear() {
    this.logs = [];
  }
}

// Global log buffer
const logBuffer = new LogBuffer(1000);

/**
 * Logger class for structured logging
 */
class Logger {
  constructor(component = 'App') {
    this.component = component;
    this.minLevel = LogLevel[process.env.LOG_LEVEL?.toUpperCase()] || LogLevel.INFO;
  }

  /**
   * Create a structured log entry
   */
  _createEntry(level, message, data = null) {
    return {
      timestamp: Date.now(),
      iso: new Date().toISOString(),
      level,
      levelName: LEVEL_NAMES[level],
      component: this.component,
      message,
      ...(data && { data })
    };
  }

  /**
   * Output a log entry
   */
  _output(entry) {
    // Add to buffer
    logBuffer.add(entry);

    // Skip console output if below minimum level
    if (entry.level < this.minLevel) return;

    // Format for console
    const prefix = `[${entry.iso.slice(11, 23)}] [${entry.levelName}] [${entry.component}]`;
    const msg = entry.data
      ? `${prefix} ${entry.message} ${JSON.stringify(entry.data)}`
      : `${prefix} ${entry.message}`;

    switch (entry.level) {
      case LogLevel.ERROR:
        console.error(msg);
        break;
      case LogLevel.WARN:
        console.warn(msg);
        break;
      case LogLevel.DEBUG:
        console.debug(msg);
        break;
      default:
        console.log(msg);
    }
  }

  debug(message, data = null) {
    this._output(this._createEntry(LogLevel.DEBUG, message, data));
  }

  info(message, data = null) {
    this._output(this._createEntry(LogLevel.INFO, message, data));
  }

  warn(message, data = null) {
    this._output(this._createEntry(LogLevel.WARN, message, data));
  }

  error(message, data = null) {
    // Handle Error objects
    if (data instanceof Error) {
      data = {
        message: data.message,
        stack: data.stack,
        ...(data.code && { code: data.code })
      };
    }
    this._output(this._createEntry(LogLevel.ERROR, message, data));
  }

  /**
   * Create a child logger with a sub-component name
   */
  child(subComponent) {
    return new Logger(`${this.component}:${subComponent}`);
  }
}

/**
 * Create a logger for a component
 */
export function createLogger(component) {
  return new Logger(component);
}

/**
 * Get the log buffer for API access
 */
export function getLogBuffer() {
  return logBuffer;
}

/**
 * Query logs with filters
 */
export function queryLogs(options = {}) {
  const { level, component, since, limit = 100 } = options;

  let logs = logBuffer.getAll();

  if (level) {
    const levelNum = typeof level === 'string' ? LogLevel[level.toUpperCase()] : level;
    logs = logs.filter(log => log.level >= levelNum);
  }

  if (component) {
    logs = logs.filter(log => log.component.startsWith(component));
  }

  if (since) {
    const ts = typeof since === 'string' ? new Date(since).getTime() : since;
    logs = logs.filter(log => log.timestamp >= ts);
  }

  return logs.slice(-limit);
}

/**
 * Get log statistics
 */
export function getLogStats() {
  const logs = logBuffer.getAll();
  const stats = {
    total: logs.length,
    byLevel: {
      DEBUG: 0,
      INFO: 0,
      WARN: 0,
      ERROR: 0
    },
    byComponent: {},
    oldest: logs[0]?.timestamp || null,
    newest: logs[logs.length - 1]?.timestamp || null
  };

  for (const log of logs) {
    stats.byLevel[log.levelName]++;
    stats.byComponent[log.component] = (stats.byComponent[log.component] || 0) + 1;
  }

  return stats;
}

// Default loggers for common components
export const serverLogger = createLogger('Server');
export const orchestratorLogger = createLogger('Orchestrator');
export const sessionLogger = createLogger('SessionManager');
export const agentLogger = createLogger('AgentLoader');

export default {
  createLogger,
  getLogBuffer,
  queryLogs,
  getLogStats,
  LogLevel,
  serverLogger,
  orchestratorLogger,
  sessionLogger,
  agentLogger
};
