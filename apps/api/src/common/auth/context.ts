import { createParamDecorator, ExecutionContext, SetMetadata } from '@nestjs/common';
import type { Request } from 'express';
import type { Types } from 'mongoose';
import type { Action, Grant, Resource, RoleKey, Scope } from '../authz/catalog';

export interface AuthUser {
  userId: string;
  orgId: string;
  role: RoleKey | string;
  employeeId?: string;
  sessionId: string;
  name: string;
  email?: string;
  reauthAt?: Date;
}

/** Resolved permission set for the request. */
export interface Authz {
  grants: Grant[];
  /** Broadest scope held for resource+action, or null. */
  scope(resource: Resource, action: Action): Scope | null;
  can(resource: Resource, action: Action, atLeast?: Scope): boolean;
  isSuperAdmin: boolean;
  recordIds(resource: Resource, action: Action): string[];
}

/** Everything a service needs to act on behalf of a caller. Passed explicitly, never global. */
export interface Ctx {
  user: AuthUser;
  authz: Authz;
  orgOid: Types.ObjectId;
  userOid: Types.ObjectId;
  employeeOid?: Types.ObjectId;
  correlationId: string;
  ip?: string;
  userAgent?: string;
  deviceId?: string;
  idempotencyKey?: string;
  /** Per-request cache (team member ids, etc.). */
  cache: Map<string, unknown>;
}

export type AuthedRequest = Request & { user?: AuthUser; ctx?: Ctx; correlationId?: string };

export const IS_PUBLIC = 'isPublic';
/** No sign-in required (login, OTP, invitation acceptance, webhooks with their own verification). */
export const Public = (): MethodDecorator & ClassDecorator => SetMetadata(IS_PUBLIC, true);

export const ALLOW_NO_DB = 'allowNoDb';
/** Route works without a database (health). */
export const AllowWithoutDatabase = (): MethodDecorator & ClassDecorator => SetMetadata(ALLOW_NO_DB, true);

export const ALLOW_STATUSES = 'allowStatuses';
/** Lets signed-in users with these non-active statuses through (e.g. complete-profile while `pending`). */
export const AllowStatuses = (...statuses: string[]): MethodDecorator => SetMetadata(ALLOW_STATUSES, statuses);

export const PERMISSION = 'permission';
/** Requires the caller to hold resource:action at any scope (services apply the scope to data). */
export const Can = (resource: Resource, action: Action, atLeast?: Scope): MethodDecorator & ClassDecorator =>
  SetMetadata(PERMISSION, { resource, action, atLeast });

export const FEATURE = 'feature';
/** Requires an organization module to be enabled. */
export const Feature = (key: string): MethodDecorator & ClassDecorator => SetMetadata(FEATURE, key);

export const REAUTH = 'reauth';
/** Requires a recent re-authentication (sensitive security changes, restore, Super Admin creation). */
export const RequireReauth = (): MethodDecorator => SetMetadata(REAUTH, true);

export const IDEMPOTENT = 'idempotent';
/** Mutation must carry an Idempotency-Key header; retries replay the first response. */
export const Idempotent = (): MethodDecorator => SetMetadata(IDEMPOTENT, true);

/** Injects the request Ctx (signed-in routes only). */
export const C = createParamDecorator((_: unknown, ec: ExecutionContext): Ctx => {
  const req = ec.switchToHttp().getRequest<AuthedRequest>();
  if (!req.ctx) throw new Error('Ctx requested on a public route');
  return req.ctx;
});
