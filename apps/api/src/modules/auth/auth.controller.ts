import { Body, Controller, Delete, Get, HttpCode, Param, Post, Req, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import type { Request, Response } from 'express';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { AllowStatuses, C, Ctx, Public, RequireReauth } from '../../common/auth/context';
import { notFound, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';
import { AuthService } from './auth.service';
import { ClientInfo, IssuedSession, REFRESH_COOKIE, SessionService } from './session.service';

const identifier = z.object({ identifier: z.string().min(3).max(120) });
const verify = identifier.extend({
  code: z.string().regex(/^\d{6}$/, 'Enter the 6-digit code'),
  deviceName: z.string().max(80).optional(),
  rememberMe: z.boolean().optional(),
});
const idToken = z.object({ idToken: z.string().min(20).max(5000), deviceName: z.string().max(80).optional() });
const password = identifier.extend({
  password: z.string().min(8).max(200),
  rememberMe: z.boolean().optional(),
});
const accept = z.object({ token: z.string().min(20).max(200), code: z.string().regex(/^\d{6}$/) });
const recover = identifier.extend({ recoveryCode: z.string().min(6).max(20) });
const code = z.object({ code: z.string().regex(/^\d{6}$/) });
const refresh = z.object({ refreshToken: z.string().optional() });

function client(req: Request, deviceName?: string): ClientInfo {
  return { ip: req.ip, userAgent: req.header('user-agent') ?? undefined, deviceId: req.header('x-device-id') ?? undefined, deviceName };
}

@ApiTags('auth')
@Controller({ path: 'auth', version: '1' })
export class AuthController {
  constructor(
    private readonly auth: AuthService,
    private readonly sessions: SessionService,
    private readonly audit: AuditService,
    @InjectModel('Session') private readonly sessionModel: Model<any>,
  ) {}

  /** Response body for every successful sign-in. The refresh token goes in an httpOnly cookie and body. */
  private async signedIn(res: Response, s: IssuedSession & { user: any }, includeRefresh = true, rememberMe = true) {
    this.sessions.setCookie(res, s.refreshToken, rememberMe ? 30 : undefined);
    return {
      accessToken: s.accessToken,
      expiresIn: s.expiresIn,
      sessionId: s.sessionId,
      ...(includeRefresh ? { refreshToken: s.refreshToken } : {}),
      me: await this.auth.me(String(s.user._id)),
    };
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('otp/request')
  @HttpCode(200)
  requestOtp(@Body() body: unknown, @Req() req: Request) {
    const b = parse(identifier, body);
    return this.auth.requestOtp(b.identifier, 'login', req.ip);
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('otp/verify')
  @HttpCode(200)
  async verifyOtp(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(verify, body);
    return this.signedIn(res, await this.auth.verifyOtp(b.identifier, b.code, client(req, b.deviceName)), true, b.rememberMe ?? true);
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('google')
  @HttpCode(200)
  async google(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(idToken, body);
    return this.signedIn(res, await this.auth.google(b.idToken, client(req, b.deviceName)), true);
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('apple')
  @HttpCode(200)
  async apple(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(idToken, body);
    return this.signedIn(res, await this.auth.apple(b.idToken, client(req, b.deviceName)), true);
  }

  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('password')
  @HttpCode(200)
  async password(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(password, body);
    return this.signedIn(res, await this.auth.password(b.identifier, b.password, client(req)), true, b.rememberMe ?? true);
  }

  @Public()
  @Get('invitations/:token')
  invitation(@Param('token') token: string) {
    return this.auth.invitationInfo(token);
  }

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('invitations/accept')
  @HttpCode(200)
  async acceptInvitation(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(accept, body);
    return this.signedIn(res, await this.auth.acceptInvitation(b.token, b.code, client(req)), true);
  }

  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('recover')
  @HttpCode(200)
  async recover(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(recover, body);
    return this.signedIn(res, await this.auth.recover(b.identifier, b.recoveryCode, client(req)), true);
  }

  @Public()
  @Throttle({ default: { limit: 30, ttl: 60_000 } })
  @Post('refresh')
  @HttpCode(200)
  async refresh(@Body() body: unknown, @Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const b = parse(refresh, body);
    const presented = b.refreshToken ?? (req as any).cookies?.[REFRESH_COOKIE] ?? cookieFrom(req, REFRESH_COOKIE);
    try {
      const s = await this.sessions.refresh(presented, client(req));
      return this.signedIn(res, s, true, true);
    } catch (e) {
      this.sessions.clearCookie(res);
      throw e;
    }
  }

  @AllowStatuses('pending')
  @Post('logout')
  @HttpCode(200)
  async logout(@C() ctx: Ctx, @Res({ passthrough: true }) res: Response) {
    await this.sessions.revoke(ctx.user.sessionId, 'logout', ctx.user.userId);
    this.sessions.clearCookie(res);
    return { signedOut: true };
  }

  @AllowStatuses('pending')
  @Get('me')
  me(@C() ctx: Ctx) {
    return this.auth.me(ctx.user.userId);
  }

  // ---- re-authentication for sensitive actions
  @Post('reauth/request')
  @HttpCode(200)
  reauthRequest(@C() ctx: Ctx) {
    return this.auth.requestReauth(ctx);
  }

  @Post('reauth/verify')
  @HttpCode(200)
  reauthVerify(@C() ctx: Ctx, @Body() body: unknown) {
    return this.auth.verifyReauth(ctx, parse(code, body).code);
  }

  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('reauth/password')
  @HttpCode(200)
  reauthPassword(@C() ctx: Ctx, @Body() body: unknown, @Req() req: Request) {
    return this.auth.reauthWithPassword(ctx, parse(z.object({ password: z.string().min(1).max(200) }), body).password, client(req));
  }

  /** Set or change my own password. */
  @AllowStatuses('pending')
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('password/change')
  @HttpCode(200)
  changePassword(@C() ctx: Ctx, @Body() body: unknown, @Req() req: Request) {
    const b = parse(z.object({ currentPassword: z.string().max(200).optional(), newPassword: z.string().min(1).max(200) }), body);
    return this.auth.changePassword(ctx, b.currentPassword, b.newPassword, client(req), ctx.user.reauthAt);
  }

  @RequireReauth()
  @Post('recovery-codes')
  @HttpCode(200)
  recoveryCodes(@C() ctx: Ctx) {
    return this.auth.generateRecoveryCodes(ctx);
  }

  // ---- my sessions and devices
  @Get('sessions')
  async mySessions(@C() ctx: Ctx) {
    const rows = await this.sessionModel
      .find({ userId: ctx.userOid, revokedAt: null, expiresAt: { $gt: new Date() } }, { refreshHash: 0, family: 0 })
      .sort({ lastUsedAt: -1 })
      .lean();
    return { items: serialize(rows).map((s: any) => ({ ...s, current: s.id === ctx.user.sessionId })) };
  }

  @Delete('sessions/:id')
  async revokeSession(@C() ctx: Ctx, @Param('id') id: string) {
    if (!(await this.sessions.revoke(id, 'user_revoked', ctx.user.userId))) throw notFound('Session');
    await this.audit.record(ctx, { action: 'session.revoke', resourceType: 'session', resourceId: id });
    return { revoked: true };
  }

  @Post('sessions/revoke-others')
  @HttpCode(200)
  async revokeOthers(@C() ctx: Ctx) {
    const n = await this.sessions.revokeAll(ctx.userOid, 'user_revoked_others', ctx.user.sessionId);
    await this.audit.record(ctx, { action: 'session.revoke_others', resourceType: 'user', resourceId: ctx.user.userId, changes: { revoked: { from: null, to: n } } });
    return { revoked: n };
  }
}

/** Minimal cookie reader (avoids a dependency on cookie-parser). */
export function cookieFrom(req: Request, name: string): string | undefined {
  const raw = req.header('cookie');
  if (!raw) return undefined;
  for (const part of raw.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return decodeURIComponent(v.join('='));
  }
  return undefined;
}
