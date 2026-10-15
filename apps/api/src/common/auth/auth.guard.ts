import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Model, Types } from 'mongoose';
import { DatabaseService } from '../../database/database.service';
import { InjectModel } from '../../database/model';
import { PermissionsService } from '../authz/permissions.service';
import { ApiError } from '../errors/api-error';
import { ALLOW_NO_DB, ALLOW_STATUSES, AuthedRequest, AuthUser, Ctx, FEATURE, IS_PUBLIC, PERMISSION, REAUTH } from './context';

export interface AccessTokenPayload {
  sub: string;
  org: string;
  sid: string;
  typ: 'access';
}

/** Statuses that block access even with valid credentials, and the screen the client shows. */
const STATUS_ERRORS: Record<string, [string, string]> = {
  suspended: ['ACCOUNT_SUSPENDED', 'Your account is suspended. Contact your administrator.'],
  blocked: ['ACCOUNT_SUSPENDED', 'Your account is blocked. Contact your administrator.'],
  inactive: ['ACCOUNT_INACTIVE', 'Your account is no longer active.'],
  pending: ['ACCOUNT_PENDING', 'Your account is waiting for activation by an administrator.'],
  invited: ['ACCOUNT_PENDING', 'Accept your invitation to activate your account.'],
};

/**
 * Global guard, in order: database ready -> public route? -> valid access token -> live session ->
 * active account and organization -> permission set -> @Can / @Feature / @RequireReauth.
 * Hidden buttons are never security: this runs for every request.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly db: DatabaseService,
    private readonly perms: PermissionsService,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Session') private readonly sessions: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
  ) {}

  private meta<T>(key: string, ec: ExecutionContext): T | undefined {
    return this.reflector.getAllAndOverride<T>(key, [ec.getHandler(), ec.getClass()]);
  }

  async canActivate(ec: ExecutionContext): Promise<boolean> {
    if (ec.getType() !== 'http') return true; // websockets authenticate in the gateway
    const req = ec.switchToHttp().getRequest<AuthedRequest>();

    if (!this.meta<boolean>(ALLOW_NO_DB, ec) && !this.db.ready) {
      throw new ApiError(HttpStatus.SERVICE_UNAVAILABLE, 'DATABASE_UNAVAILABLE', 'The database is not reachable right now. Try again shortly.');
    }
    if (this.meta<boolean>(IS_PUBLIC, ec)) return true;

    const header = req.header('authorization') ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!token) throw new ApiError(HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Sign in to continue.');

    let payload: AccessTokenPayload;
    try {
      payload = await this.jwt.verifyAsync<AccessTokenPayload>(token);
    } catch {
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'TOKEN_EXPIRED', 'Your session expired. Sign in again.');
    }
    if (payload.typ !== 'access') throw new ApiError(HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Sign in to continue.');

    const [session, user, org] = await Promise.all([
      this.sessions.findOne({ _id: payload.sid, userId: payload.sub }).lean<any>(),
      this.users.findOne({ _id: payload.sub, organizationId: payload.org }).lean<any>(),
      this.orgs.findById(payload.org).lean<any>(),
    ]);
    if (!session || session.revokedAt || session.expiresAt < new Date()) {
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'SESSION_REVOKED', 'This session was signed out. Sign in again.');
    }
    if (!user || !org) throw new ApiError(HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Sign in to continue.');
    if (org.status !== 'active') throw new ApiError(HttpStatus.FORBIDDEN, 'ORGANIZATION_SUSPENDED', 'This organization is suspended.');

    const allowed = this.meta<string[]>(ALLOW_STATUSES, ec) ?? [];
    if (user.status !== 'active' && !allowed.includes(user.status)) {
      const [code, message] = STATUS_ERRORS[user.status] ?? ['ACCOUNT_INACTIVE', 'Your account is not active.'];
      throw new ApiError(HttpStatus.FORBIDDEN, code, message);
    }
    // A temporary password from an administrator only unlocks the minimal account routes
    // (the same ones a pending account may use) until the person chooses their own password.
    if (user.mustChangePassword && !allowed.includes('pending')) {
      throw new ApiError(HttpStatus.FORBIDDEN, 'PASSWORD_CHANGE_REQUIRED', 'Choose your own password to continue.');
    }

    const authUser: AuthUser = {
      userId: String(user._id),
      orgId: String(user.organizationId),
      role: user.role,
      employeeId: user.employeeId ? String(user.employeeId) : undefined,
      sessionId: String(session._id),
      name: user.displayName || user.fullName,
      email: user.email,
      reauthAt: session.reauthAt,
    };
    const grants = await this.perms.grantsFor(authUser, user.permissionsVersion ?? 1);
    const authz = PermissionsService.build(grants, user.role, user.email);
    const ctx: Ctx = {
      user: authUser,
      authz,
      orgOid: new Types.ObjectId(authUser.orgId),
      userOid: new Types.ObjectId(authUser.userId),
      employeeOid: authUser.employeeId ? new Types.ObjectId(authUser.employeeId) : undefined,
      correlationId: req.correlationId ?? 'unknown',
      ip: req.ip,
      userAgent: req.header('user-agent') ?? undefined,
      deviceId: req.header('x-device-id') ?? undefined,
      idempotencyKey: req.header('idempotency-key') ?? undefined,
      cache: new Map(),
    };
    req.user = authUser;
    req.ctx = ctx;

    const feature = this.meta<string>(FEATURE, ec);
    if (feature) {
      const features = org.features instanceof Map ? Object.fromEntries(org.features) : (org.features ?? {});
      if (features[feature] === false) {
        throw new ApiError(HttpStatus.FORBIDDEN, 'FEATURE_DISABLED', 'This module is not enabled for your organization.');
      }
    }

    const perm = this.meta<{ resource: any; action: any; atLeast?: any }>(PERMISSION, ec);
    if (perm) PermissionsService.require(ctx, perm.resource, perm.action, perm.atLeast);

    if (this.meta<boolean>(REAUTH, ec)) {
      const windowMs = (org.settings?.security?.reauthMinutes ?? 10) * 60_000;
      if (!session.reauthAt || Date.now() - new Date(session.reauthAt).getTime() > windowMs) {
        throw new ApiError(HttpStatus.FORBIDDEN, 'REAUTH_REQUIRED', 'Confirm it is you to continue.');
      }
    }
    // Touch the session at most once a minute.
    if (!session.lastUsedAt || Date.now() - new Date(session.lastUsedAt).getTime() > 60_000) {
      void this.sessions.updateOne({ _id: session._id }, { $set: { lastUsedAt: new Date(), ip: req.ip } }).exec().catch(() => undefined);
    }
    return true;
  }
}
