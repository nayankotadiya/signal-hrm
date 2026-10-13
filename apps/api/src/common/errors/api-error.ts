import { HttpException, HttpStatus } from '@nestjs/common';

/** Field-level validation detail. `field` uses dot paths (e.g. "dates.end"). */
export interface ApiFieldError {
  field: string;
  message: string;
  code?: string;
}

/**
 * The one error shape every endpoint returns. The Flutter client maps `details` onto form
 * fields and shows `correlationId` in its error sheet for support.
 */
export interface ApiErrorBody {
  error: {
    status: number;
    code: string;
    message: string;
    details?: ApiFieldError[];
    /** Extra machine-readable context (e.g. retriesLeft, distanceMeters) for the client UI. */
    meta?: Record<string, unknown>;
    correlationId: string;
  };
}

/** Throw this from business code for a stable, machine-readable error code. */
export class ApiError extends HttpException {
  constructor(
    status: HttpStatus,
    readonly code: string,
    message: string,
    readonly details?: ApiFieldError[],
    readonly meta?: Record<string, unknown>,
  ) {
    super(message, status);
  }
}
