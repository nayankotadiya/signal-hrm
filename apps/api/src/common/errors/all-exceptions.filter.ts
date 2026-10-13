import { ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger, Optional } from '@nestjs/common';
import type { Model } from 'mongoose';
import { InjectModel } from '../../database/model';
import type { Response } from 'express';
import { ZodError } from 'zod';
import type { RequestWithCorrelation } from '../correlation/correlation-id.middleware';
import { ApiError, ApiErrorBody, ApiFieldError } from './api-error';

const STATUS_CODES: Record<number, string> = {
  400: 'BAD_REQUEST',
  401: 'UNAUTHENTICATED',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  413: 'PAYLOAD_TOO_LARGE',
  422: 'VALIDATION_FAILED',
  429: 'RATE_LIMITED',
  503: 'SERVICE_UNAVAILABLE',
};

/**
 * Converts every thrown error into ApiErrorBody. Internal errors never leak stack traces,
 * driver messages or connection strings to the client; they are logged with the correlation ID.
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Errors');

  constructor(@Optional() @InjectModel('ErrorLog') private readonly errorLogs?: Model<any>) {}

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest<RequestWithCorrelation>();
    const res = ctx.getResponse<Response>();
    const body = this.toBody(exception, req?.correlationId ?? 'unknown');

    if (body.error.status >= 500) {
      // Stored without stack traces or internals; the full error stays in the server log.
      void this.errorLogs
        ?.create({ organizationId: (req as any)?.user?.orgId, correlationId: body.error.correlationId, method: req?.method, path: (req as any)?.route?.path ?? req?.path, status: body.error.status, code: body.error.code, message: body.error.message.slice(0, 200), at: new Date() })
        .catch(() => undefined);
      this.logger.error(
        `[${body.error.correlationId}] ${req?.method} ${req?.originalUrl ?? req?.url} -> ${body.error.status}`,
        exception instanceof Error ? exception.stack : String(exception),
      );
    }
    res.status(body.error.status).json(body);
  }

  toBody(exception: unknown, correlationId: string): ApiErrorBody {
    if (exception instanceof ApiError) {
      const body = this.wrap(exception.getStatus(), exception.code, exception.message, correlationId, exception.details);
      if (exception.meta) body.error.meta = exception.meta;
      return body;
    }
    if (exception instanceof ZodError) {
      const details: ApiFieldError[] = exception.issues.map((i) => ({
        field: i.path.join('.'),
        message: i.message,
        code: i.code,
      }));
      return this.wrap(422, 'VALIDATION_FAILED', 'Some fields need attention.', correlationId, details);
    }
    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const response = exception.getResponse();
      const message =
        typeof response === 'string'
          ? response
          : typeof (response as { message?: unknown }).message === 'string'
            ? ((response as { message: string }).message)
            : exception.message;
      return this.wrap(status, STATUS_CODES[status] ?? `HTTP_${status}`, message, correlationId);
    }
    return this.wrap(
      HttpStatus.INTERNAL_SERVER_ERROR,
      'INTERNAL_ERROR',
      'The server hit an unexpected problem. Try again; if it keeps happening, share the reference with support.',
      correlationId,
    );
  }

  private wrap(status: number, code: string, message: string, correlationId: string, details?: ApiFieldError[]): ApiErrorBody {
    return { error: { status, code, message, ...(details?.length ? { details } : {}), correlationId } };
  }
}
