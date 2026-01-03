/**
 * Custom Error Classes
 *
 * Provides typed errors with appropriate HTTP status codes
 * for consistent API error handling.
 */

/**
 * Base API error class
 */
export class ApiError extends Error {
  constructor(message, statusCode = 500, code = 'INTERNAL_ERROR') {
    super(message);
    this.name = 'ApiError';
    this.statusCode = statusCode;
    this.code = code;
  }

  toJSON() {
    return {
      error: this.message,
      code: this.code,
      statusCode: this.statusCode
    };
  }
}

/**
 * 400 Bad Request - Invalid input
 */
export class BadRequestError extends ApiError {
  constructor(message, code = 'BAD_REQUEST') {
    super(message, 400, code);
    this.name = 'BadRequestError';
  }
}

/**
 * 401 Unauthorized - Authentication required
 */
export class UnauthorizedError extends ApiError {
  constructor(message = 'Unauthorized', code = 'UNAUTHORIZED') {
    super(message, 401, code);
    this.name = 'UnauthorizedError';
  }
}

/**
 * 403 Forbidden - Permission denied
 */
export class ForbiddenError extends ApiError {
  constructor(message = 'Forbidden', code = 'FORBIDDEN') {
    super(message, 403, code);
    this.name = 'ForbiddenError';
  }
}

/**
 * 404 Not Found
 */
export class NotFoundError extends ApiError {
  constructor(message = 'Not found', code = 'NOT_FOUND') {
    super(message, 404, code);
    this.name = 'NotFoundError';
  }
}

/**
 * 409 Conflict - Resource state conflict
 */
export class ConflictError extends ApiError {
  constructor(message, code = 'CONFLICT') {
    super(message, 409, code);
    this.name = 'ConflictError';
  }
}

/**
 * 413 Payload Too Large
 */
export class PayloadTooLargeError extends ApiError {
  constructor(message = 'Payload too large', code = 'PAYLOAD_TOO_LARGE') {
    super(message, 413, code);
    this.name = 'PayloadTooLargeError';
  }
}

/**
 * 422 Unprocessable Entity - Validation error
 */
export class ValidationError extends ApiError {
  constructor(message, fields = null, code = 'VALIDATION_ERROR') {
    super(message, 422, code);
    this.name = 'ValidationError';
    this.fields = fields;
  }

  toJSON() {
    return {
      ...super.toJSON(),
      ...(this.fields && { fields: this.fields })
    };
  }
}

/**
 * 429 Too Many Requests - Rate limited
 */
export class RateLimitError extends ApiError {
  constructor(message = 'Too many requests', retryAfter = null, code = 'RATE_LIMITED') {
    super(message, 429, code);
    this.name = 'RateLimitError';
    this.retryAfter = retryAfter;
  }

  toJSON() {
    return {
      ...super.toJSON(),
      ...(this.retryAfter && { retryAfter: this.retryAfter })
    };
  }
}

/**
 * 500 Internal Server Error
 */
export class InternalError extends ApiError {
  constructor(message = 'Internal server error', code = 'INTERNAL_ERROR') {
    super(message, 500, code);
    this.name = 'InternalError';
  }
}

/**
 * 503 Service Unavailable
 */
export class ServiceUnavailableError extends ApiError {
  constructor(message = 'Service unavailable', code = 'SERVICE_UNAVAILABLE') {
    super(message, 503, code);
    this.name = 'ServiceUnavailableError';
  }
}

/**
 * Express error handler middleware
 */
export function errorHandler(err, req, res, next) {
  // If it's one of our API errors, use its status and format
  if (err instanceof ApiError) {
    return res.status(err.statusCode).json(err.toJSON());
  }

  // Handle standard errors
  console.error('Unhandled error:', err);

  // Don't expose internal error details in production
  const isDev = process.env.NODE_ENV !== 'production';

  res.status(500).json({
    error: isDev ? err.message : 'Internal server error',
    code: 'INTERNAL_ERROR',
    statusCode: 500,
    ...(isDev && { stack: err.stack })
  });
}

/**
 * Async route wrapper to catch errors
 */
export function asyncHandler(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

export default {
  ApiError,
  BadRequestError,
  UnauthorizedError,
  ForbiddenError,
  NotFoundError,
  ConflictError,
  PayloadTooLargeError,
  ValidationError,
  RateLimitError,
  InternalError,
  ServiceUnavailableError,
  errorHandler,
  asyncHandler
};
