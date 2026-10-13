import { CallHandler, ExecutionContext, HttpStatus, Injectable, NestInterceptor } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { HTTP_CODE_METADATA } from '@nestjs/common/constants';
import type { Response } from 'express';
import { Model } from 'mongoose';
import { from, Observable, of, concatMap, switchMap, catchError, throwError } from 'rxjs';
import { InjectModel } from '../../database/model';
import { AuthedRequest, IDEMPOTENT } from '../auth/context';
import { ApiError } from '../errors/api-error';

const KEY_RE = /^[A-Za-z0-9_-]{8,100}$/;
const MUTATING = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

/**
 * Idempotency-Key support for every mutation. The first request with a key runs and its response is
 * stored for 24 hours; retries with the same key replay that response instead of running again, so a
 * retried check-in, approval or leave request never duplicates. A concurrent duplicate gets 409.
 * Handlers marked @Idempotent() reject requests without a key.
 */
@Injectable()
export class IdempotencyInterceptor implements NestInterceptor {
  constructor(
    private readonly reflector: Reflector,
    @InjectModel('IdempotencyKey') private readonly keys: Model<any>,
  ) {}

  intercept(ec: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (ec.getType() !== 'http') return next.handle();
    const req = ec.switchToHttp().getRequest<AuthedRequest>();
    const res = ec.switchToHttp().getResponse<Response>();
    if (!MUTATING.has(req.method)) return next.handle();

    const key = req.header('idempotency-key');
    const required = this.reflector.getAllAndOverride<boolean>(IDEMPOTENT, [ec.getHandler(), ec.getClass()]);
    if (!key) {
      if (required) throw new ApiError(HttpStatus.BAD_REQUEST, 'IDEMPOTENCY_KEY_REQUIRED', 'This action needs an Idempotency-Key header.');
      return next.handle();
    }
    if (!KEY_RE.test(key)) throw new ApiError(HttpStatus.BAD_REQUEST, 'IDEMPOTENCY_KEY_INVALID', 'The Idempotency-Key header is not valid.');

    // Public routes (OTP) scope keys by client IP; signed-in routes by organization and user.
    const scope = req.user ? `${req.user.orgId}:${req.user.userId}` : `ip:${req.ip}`;
    const path = req.route?.path ?? req.path;

    return from(this.claim(scope, key, req.method, path)).pipe(
      switchMap((existing) => {
        if (existing) {
          if (existing.method !== req.method || existing.path !== path) {
            throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'IDEMPOTENCY_KEY_REUSED', 'This Idempotency-Key was already used for a different action.');
          }
          if (existing.status === 'in_progress') {
            throw new ApiError(HttpStatus.CONFLICT, 'IDEMPOTENCY_IN_PROGRESS', 'The same request is still being processed.');
          }
          res.status(existing.responseStatus ?? 200);
          res.setHeader('idempotent-replayed', 'true');
          return of(existing.responseBody);
        }
        // Nest sets the final status after interceptors run, so derive it the same way it will.
        const declared = this.reflector.get<number>(HTTP_CODE_METADATA, ec.getHandler());
        const status = declared ?? (req.method === 'POST' ? 201 : 200);
        return next.handle().pipe(
          // Store the response BEFORE answering: an immediate retry must replay, not see "in progress".
          concatMap(async (body) => {
            await this.keys.updateOne({ scope, key }, { $set: { status: 'completed', responseStatus: status, responseBody: body ?? null } }).exec();
            return body;
          }),
          catchError((err) => {
            // Failed attempts release the key so the client can retry with the same one.
            return from(this.keys.deleteOne({ scope, key, status: 'in_progress' }).exec()).pipe(switchMap(() => throwError(() => err)));
          }),
        );
      }),
    );
  }

  /** Inserts the key as in_progress; returns the existing record when it already exists. */
  private async claim(scope: string, key: string, method: string, path: string): Promise<any | null> {
    try {
      await this.keys.create({ scope, key, method, path, status: 'in_progress', expiresAt: new Date(Date.now() + 24 * 3600_000) });
      return null;
    } catch (e: any) {
      if (e?.code === 11000) return this.keys.findOne({ scope, key }).lean();
      throw e;
    }
  }
}
