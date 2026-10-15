import { HttpStatus, Inject, Injectable } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import type { Response } from 'express';
import { Model, Types } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import { ApiError } from '../../common/errors/api-error';
import { randomToken, sha256 } from '../../common/crypto/crypto';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { InjectModel } from '../../database/model';

export const REFRESH_COOKIE = 'shrm_rt';

export interface ClientInfo {
  ip?: string;
  userAgent?: string;
  deviceId?: string;
  deviceName?: string;
}

export interface IssuedSession {
  accessToken: string;
  expiresIn: number;
  refreshToken: string;
  sessionId: string;
}

/**
 * Sessions: short-lived JWT access tokens (memory only in the client) plus a rotating refresh token
 * in an httpOnly cookie. Refresh token = "<sessionId>.<secret>"; only sha256(secret) is stored.
 * Presenting an old (already rotated) refresh token revokes the session and raises a security alert.
 */
@Injectable()
export class SessionService {
  constructor(
    private readonly jwt: JwtService,
    private readonly audit: AuditService,
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    @InjectModel('Session') private readonly sessions: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Device') private readonly devices: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
  ) {}

  async issue(user: any, provider: string, client: ClientInfo): Promise<IssuedSession> {
    const org = await this.orgs.findById(user.organizationId, { settings: 1 }).lean<any>();
    const days = org?.settings?.security?.sessionDays ?? this.env.REFRESH_TOKEN_TTL_DAYS;
    const secret = randomToken(32);
    const session = await this.sessions.create({
      organizationId: user.organizationId,
      userId: user._id,
      refreshHash: sha256(secret),
      family: randomToken(12),
      deviceId: client.deviceId,
      deviceName: client.deviceName,
      userAgent: client.userAgent?.slice(0, 300),
      ip: client.ip,
      provider,
      lastUsedAt: new Date(),
      expiresAt: new Date(Date.now() + days * 86400_000),
      reauthAt: new Date(), // a fresh sign-in counts as recent authentication
    });
    await this.users.updateOne({ _id: user._id }, { $set: { lastLoginAt: new Date(), failedLogins: 0, lockedUntil: null } });
    if (client.deviceId) await this.trackDevice(user, client);
    return { ...(await this.accessFor(user, session._id)), refreshToken: `${session._id}.${secret}`, sessionId: String(session._id) };
  }

  private async accessFor(user: any, sessionId: unknown): Promise<{ accessToken: string; expiresIn: number }> {
    const accessToken = await this.jwt.signAsync({ sub: String(user._id), org: String(user.organizationId), sid: String(sessionId), typ: 'access' });
    return { accessToken, expiresIn: this.env.ACCESS_TOKEN_TTL_SECONDS };
  }

  /** Rotates the refresh token. */
  async refresh(presented: string | undefined, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const [sid, secret] = (presented ?? '').split('.');
    if (!sid || !secret || !Types.ObjectId.isValid(sid)) throw this.unauth();
    const session = await this.sessions.findById(sid).lean<any>();
    if (!session || session.revokedAt || session.expiresAt < new Date()) throw this.unauth();
    const hash = sha256(secret);
    if (session.refreshHash !== hash) {
      // Grace period (90 seconds): If the client presents the previous token that was just rotated
      // (e.g. app reload, fast retries, cross-tab, network hiccup), don't revoke! Return current access.
      const lastUsed = session.lastUsedAt ? new Date(session.lastUsedAt).getTime() : 0;
      if (session.previousRefreshHash === hash && Date.now() - lastUsed < 90_000) {
        const user = await this.users.findById(session.userId).lean<any>();
        if (!user) throw this.unauth();
        return { ...(await this.accessFor(user, sid)), refreshToken: presented!, sessionId: sid, user };
      }

      // Reuse of a rotated token: someone else may hold it. Revoke and alert.
      await this.sessions.updateOne({ _id: sid }, { $set: { revokedAt: new Date(), revokedReason: 'refresh_reuse' } });
      await this.alerts.create({
        organizationId: session.organizationId,
        type: 'refresh_reuse',
        severity: 'high',
        userId: session.userId,
        message: 'A previously used sign-in token was presented again. The session was signed out.',
        data: { ip: client.ip, userAgent: client.userAgent?.slice(0, 200) },
      });
      throw this.unauth();
    }
    const user = await this.users.findById(session.userId).lean<any>();
    if (!user) throw this.unauth();
    const next = randomToken(32);
    // Conditional update: preserve previousRefreshHash for rotation grace period.
    const r = await this.sessions.updateOne(
      { _id: sid, refreshHash: session.refreshHash },
      { $set: { previousRefreshHash: session.refreshHash, refreshHash: sha256(next), lastUsedAt: new Date(), ip: client.ip } },
    );
    if (r.modifiedCount !== 1) throw this.unauth();
    return { ...(await this.accessFor(user, sid)), refreshToken: `${sid}.${next}`, sessionId: sid, user };
  }

  async revoke(sessionId: string, reason: string, userId?: string): Promise<boolean> {
    const filter: Record<string, unknown> = { _id: sessionId, revokedAt: null };
    if (userId) filter.userId = userId;
    const r = await this.sessions.updateOne(filter, { $set: { revokedAt: new Date(), revokedReason: reason } });
    return r.modifiedCount === 1;
  }

  async revokeAll(userId: unknown, reason: string, exceptSessionId?: string): Promise<number> {
    const filter: Record<string, unknown> = { userId, revokedAt: null };
    if (exceptSessionId) filter._id = { $ne: exceptSessionId };
    const r = await this.sessions.updateMany(filter, { $set: { revokedAt: new Date(), revokedReason: reason } });
    return r.modifiedCount;
  }

  async markReauth(sessionId: string): Promise<void> {
    await this.sessions.updateOne({ _id: sessionId }, { $set: { reauthAt: new Date() } });
  }

  setCookie(res: Response, refreshToken: string, days?: number): void {
    const isProd = this.env.APP_ENV === 'production';
    res.cookie(REFRESH_COOKIE, refreshToken, {
      httpOnly: true,
      secure: isProd || this.env.COOKIE_SECURE,
      sameSite: isProd ? 'none' : this.env.COOKIE_SAME_SITE,
      path: `/${this.env.API_PREFIX}/v1/auth`,
      maxAge: (days ?? 30) * 86400_000,
    });
  }

  clearCookie(res: Response): void {
    res.clearCookie(REFRESH_COOKIE, {
      path: `/${this.env.API_PREFIX}/v1/auth`,
      secure: this.env.COOKIE_SECURE,
      sameSite: this.env.COOKIE_SAME_SITE,
    });
  }

  private async trackDevice(user: any, client: ClientInfo): Promise<void> {
    await this.devices.updateOne(
      { organizationId: user.organizationId, deviceId: client.deviceId },
      {
        $addToSet: { userIds: user._id },
        $set: { lastSeenAt: new Date(), userAgent: client.userAgent?.slice(0, 300) },
        $setOnInsert: { firstSeenAt: new Date() },
      },
      { upsert: true },
    );
  }

  private unauth(): ApiError {
    return new ApiError(HttpStatus.UNAUTHORIZED, 'SESSION_EXPIRED', 'Your session ended. Sign in again.');
  }
}
