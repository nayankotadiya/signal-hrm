import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { OAuth2Client } from 'google-auth-library';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { Model, Types } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { hashPassword, hmac, numericCode, passwordProblem, randomToken, safeEqual, sha256, verifyPassword } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { MailService } from '../../common/mail/mail.service';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { SmsService } from '../../common/sms/sms.service';
import { APP_CONFIG } from '../../config/config.module';
import { AppEnv, secretOf } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { ClientInfo, IssuedSession, SessionService } from './session.service';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^\+[1-9]\d{7,14}$/;

export function normalizeIdentifier(raw: string): { channel: 'email' | 'phone'; value: string } {
  const v = raw.trim();
  if (EMAIL_RE.test(v)) return { channel: 'email', value: v.toLowerCase() };
  const phone = v.replace(/[\s()-]/g, '');
  if (PHONE_RE.test(phone)) return { channel: 'phone', value: phone };
  throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', 'Enter a valid email address or a phone number with country code.', [
    { field: 'identifier', message: 'Use name@company.com or +91XXXXXXXXXX' },
  ]);
}

export const maskIdentifier = (v: string): string =>
  v.includes('@') ? v.replace(/^(.)(.*)(@.*)$/, (_m, a, b, c) => `${a}${'•'.repeat(Math.min(6, b.length))}${c}`) : `${v.slice(0, 3)}••••${v.slice(-2)}`;

@Injectable()
export class AuthService {
  private readonly logger = new Logger('Auth');
  private googleClient?: OAuth2Client;
  private appleJwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));

  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly sessions: SessionService,
    private readonly mail: MailService,
    private readonly sms: SmsService,
    private readonly audit: AuditService,
    private readonly perms: PermissionsService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Otp') private readonly otps: Model<any>,
    @InjectModel('Invitation') private readonly invitations: Model<any>,
    @InjectModel('LoginEvent') private readonly loginEvents: Model<any>,
    @InjectModel('RecoveryCode') private readonly recoveryCodes: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('UserPreferences') private readonly prefs: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
  ) {
    if (env.GOOGLE_CLIENT_IDS.length) this.googleClient = new OAuth2Client();
  }

  private codeHash(identifier: string, code: string): string {
    return hmac(secretOf(this.env, 'OTP_PEPPER'), `${identifier}:${code}`);
  }

  // ------------------------------------------------------------------ OTP

  /**
   * Sends a one-time code when the identifier belongs to an existing account or an open invitation.
   * The response is the same either way (no account enumeration). Codes are hashed, single use,
   * expire, and are rate-limited per identifier.
   */
  async requestOtp(raw: string, purpose: 'login' | 'reauth', ip?: string, userForReauth?: any): Promise<{ sent: true; resendAfterSeconds: number; channel: string; destination: string }> {
    const { channel, value } = normalizeIdentifier(raw);
    const generic = { sent: true as const, resendAfterSeconds: this.env.OTP_RESEND_SECONDS, channel, destination: maskIdentifier(value) };

    const recent = await this.otps.findOne({ identifier: value, purpose }).sort({ createdAt: -1 }).lean<any>();
    if (recent && Date.now() - new Date(recent.createdAt).getTime() < this.env.OTP_RESEND_SECONDS * 1000) {
      throw new ApiError(HttpStatus.TOO_MANY_REQUESTS, 'OTP_RESEND_TOO_SOON', `Wait ${this.env.OTP_RESEND_SECONDS} seconds before asking for a new code.`);
    }
    const hourCount = await this.otps.countDocuments({ identifier: value, createdAt: { $gt: new Date(Date.now() - 3600_000) } });
    if (hourCount >= 5) throw new ApiError(HttpStatus.TOO_MANY_REQUESTS, 'OTP_RATE_LIMITED', 'Too many codes requested. Try again in an hour.');

    const user = userForReauth ?? (await this.findUserByIdentifier(channel, value));
    const invitation = user ? null : await this.invitations.findOne({ [channel]: value, status: 'pending', expiresAt: { $gt: new Date() } }).lean<any>();
    if (!user && !invitation) {
      // Record the attempt (masked) but answer like a success.
      await this.loginEvents.create({ identifier: maskIdentifier(value), outcome: 'failure', reason: 'unknown_identifier', ip, at: new Date(), organizationId: new Types.ObjectId('000000000000000000000000') });
      return generic;
    }
    if (channel === 'phone') {
      if (!this.sms.canSend) {
        throw new ApiError(HttpStatus.CONFLICT, 'SMS_NOT_CONFIGURED', "SMS codes aren't set up on this server yet. Sign in with your password or email.");
      }
      const code = numericCode(6);
      await this.otps.create({
        organizationId: user?.organizationId ?? invitation?.organizationId,
        channel,
        identifier: value,
        purpose,
        codeHash: this.codeHash(value, code),
        expiresAt: new Date(Date.now() + this.env.OTP_TTL_SECONDS * 1000),
        ip,
      });
      const minutes = Math.round(this.env.OTP_TTL_SECONDS / 60);
      await this.sms.send({
        to: value,
        message: `Your Signal HRM ${purpose === 'reauth' ? 'confirmation' : 'sign-in'} code is ${code}. Valid for ${minutes} minutes.`,
      });
      if (this.env.OTP_DEV_ECHO && this.env.APP_ENV === 'development') this.logger.warn(`[dev] OTP for ${value}: ${code}`);
      return generic;
    }

    if (!this.mail.canSend) {
      throw new ApiError(HttpStatus.CONFLICT, 'EMAIL_NOT_CONFIGURED', "Email codes aren't set up on this server yet. Sign in with your password.");
    }
    const code = numericCode(6);
    await this.otps.create({
      organizationId: user?.organizationId ?? invitation?.organizationId,
      channel,
      identifier: value,
      purpose,
      codeHash: this.codeHash(value, code),
      expiresAt: new Date(Date.now() + this.env.OTP_TTL_SECONDS * 1000),
      ip,
    });
    const minutes = Math.round(this.env.OTP_TTL_SECONDS / 60);
    try {
      await this.mail.send({
        to: value,
        subject: `${code} is your Signal HRM code`,
        text: `Your Signal HRM ${purpose === 'reauth' ? 'confirmation' : 'sign-in'} code is ${code}. It expires in ${minutes} minutes. If you didn't ask for it, ignore this email.`,
      });
    } catch (e: any) {
      this.logger.error(`Failed to send OTP email to ${maskIdentifier(value)}: ${e?.message ?? e}`);
      throw new ApiError(HttpStatus.SERVICE_UNAVAILABLE, 'EMAIL_DELIVERY_FAILED', `Failed to deliver verification code email (${e?.message ?? 'SMTP error'}). Please try again or use your password.`);
    }
    if (this.env.OTP_DEV_ECHO && this.env.APP_ENV === 'development') this.logger.warn(`[dev] OTP for ${value}: ${code}`);
    return generic;
  }

  /** Verifies the latest code for the identifier. Returns true or throws with attempts remaining. */
  private async consumeOtp(value: string, code: string, purpose: string): Promise<void> {
    const otp = await this.otps.findOne({ identifier: value, purpose, consumedAt: null }).sort({ createdAt: -1 });
    if (!otp || otp.expiresAt < new Date()) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'OTP_EXPIRED', 'This code expired. Ask for a new one.', [{ field: 'code', message: 'Expired' }]);
    }
    if (otp.attempts >= this.env.OTP_MAX_ATTEMPTS) {
      throw new ApiError(HttpStatus.TOO_MANY_REQUESTS, 'OTP_TOO_MANY_ATTEMPTS', 'Too many wrong codes. Ask for a new one.');
    }
    // Count the attempt first so parallel guesses can't exceed the limit.
    const r = await this.otps.updateOne({ _id: otp._id, attempts: otp.attempts, consumedAt: null }, { $inc: { attempts: 1 } });
    if (r.modifiedCount !== 1) throw new ApiError(HttpStatus.CONFLICT, 'OTP_RETRY', 'Try the code again.');
    if (!/^\d{6}$/.test(code) || !safeEqual(otp.codeHash, this.codeHash(value, code))) {
      const left = this.env.OTP_MAX_ATTEMPTS - otp.attempts - 1;
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'OTP_INVALID', left > 0 ? `That code is not right. ${left} ${left === 1 ? 'try' : 'tries'} left.` : 'That code is not right. Ask for a new one.', [
        { field: 'code', message: 'Incorrect code' },
      ]);
    }
    const c = await this.otps.updateOne({ _id: otp._id, consumedAt: null }, { $set: { consumedAt: new Date() } });
    if (c.modifiedCount !== 1) throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'OTP_USED', 'This code was already used. Ask for a new one.');
  }

  async verifyOtp(raw: string, code: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const { channel, value } = normalizeIdentifier(raw);
    const user = await this.findUserByIdentifier(channel, value);
    if (user) await this.assertNotLocked(user);
    try {
      await this.consumeOtp(value, code, 'login');
    } catch (e) {
      if (user) await this.recordFailure(user, 'otp', 'bad_code', client);
      throw e;
    }
    if (!user) {
      // A valid code for an invitation only. Sign-in requires accepting the invitation (no account from an OTP alone).
      throw new ApiError(HttpStatus.FORBIDDEN, 'INVITATION_NOT_ACCEPTED', 'Open the invitation link from your email to activate your account.');
    }
    if (channel === 'email' && !user.emailVerified) await this.users.updateOne({ _id: user._id }, { $set: { emailVerified: true } });
    return this.completeLogin(user, 'otp', client);
  }

  // ------------------------------------------------------------------ Google and Apple

  async google(idToken: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    if (!this.googleClient) throw new ApiError(HttpStatus.NOT_IMPLEMENTED, 'GOOGLE_NOT_CONFIGURED', 'Google sign-in is not set up for this server.');
    let payload: any;
    try {
      const ticket = await this.googleClient.verifyIdToken({ idToken, audience: this.env.GOOGLE_CLIENT_IDS });
      payload = ticket.getPayload();
    } catch {
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'GOOGLE_TOKEN_INVALID', 'Google sign-in could not be verified. Try again.');
    }
    return this.federated('google', payload?.sub, payload?.email, payload?.email_verified === true, client);
  }

  async apple(idToken: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    if (!this.env.APPLE_CLIENT_IDS.length) throw new ApiError(HttpStatus.NOT_IMPLEMENTED, 'APPLE_NOT_CONFIGURED', 'Apple sign-in is not set up for this server.');
    let payload: any;
    try {
      ({ payload } = await jwtVerify(idToken, this.appleJwks, { issuer: 'https://appleid.apple.com', audience: this.env.APPLE_CLIENT_IDS }));
    } catch {
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'APPLE_TOKEN_INVALID', 'Apple sign-in could not be verified. Try again.');
    }
    const verified = payload.email_verified === true || payload.email_verified === 'true';
    return this.federated('apple', payload.sub, payload.email, verified, client);
  }

  /** Links a provider identity to an existing account only. Never creates one. */
  private async federated(provider: 'google' | 'apple', sub: string | undefined, email: string | undefined, emailVerified: boolean, client: ClientInfo) {
    if (!sub) throw new ApiError(HttpStatus.UNAUTHORIZED, 'PROVIDER_TOKEN_INVALID', 'Sign-in could not be verified.');
    const field = provider === 'google' ? 'googleSub' : 'appleSub';
    let user = await this.users.findOne({ [field]: sub }).lean<any>();
    if (!user && email && emailVerified) {
      user = await this.users.findOne({ email: email.toLowerCase() }).lean<any>();
      if (user) await this.users.updateOne({ _id: user._id, [field]: null }, { $set: { [field]: sub, emailVerified: true } });
    }
    if (!user) throw new ApiError(HttpStatus.FORBIDDEN, 'NO_ACCOUNT', "There's no Signal HRM account for this sign-in. Ask your administrator for an invitation.");
    if (user.status === 'invited') {
      throw new ApiError(HttpStatus.FORBIDDEN, 'INVITATION_NOT_ACCEPTED', 'Open the invitation link from your email to activate your account.');
    }
    return this.completeLogin(user, provider, client);
  }

  // ------------------------------------------------------------------ optional password

  async password(raw: string, password: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const { channel, value } = normalizeIdentifier(raw);
    const user = await this.users.findOne(channel === 'email' ? { email: value } : { phone: value }).select('+passwordHash').lean<any>();
    const org = user ? await this.orgSettings.get(user.organizationId) : null;
    const passwordAllowed = this.env.PASSWORD_LOGIN !== false || !!org?.settings?.security?.passwordLogin || Boolean(user?.passwordHash);
    if (!passwordAllowed) {
      throw new ApiError(HttpStatus.NOT_IMPLEMENTED, 'PASSWORD_LOGIN_DISABLED', 'Password sign-in is turned off. Use a one-time code.');
    }
    if (user) await this.assertNotLocked(user);
    if (user && !user.passwordHash) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'NO_PASSWORD', 'Your account has no password set. Sign in with a one-time code.');
    }
    if (!user || !user.passwordHash || !verifyPassword(password, user.passwordHash)) {
      if (user) await this.recordFailure(user, 'password', 'bad_password', client);
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'INVALID_CREDENTIALS', 'Email or password is not right.');
    }
    return this.completeLogin(user, 'password', client);
  }

  /** Password sign-in is on for the whole server (PASSWORD_LOGIN) or for this organization (Security settings). */
  async passwordLoginOn(orgId: unknown): Promise<boolean> {
    if (this.env.PASSWORD_LOGIN) return true;
    const org = await this.orgSettings.get(orgId as any);
    return !!org?.settings?.security?.passwordLogin;
  }

  /** Confirms a sensitive action with the account password (servers without email codes). */
  async reauthWithPassword(ctx: Ctx, password: string, client: ClientInfo): Promise<{ reauthenticated: true; validForMinutes: number }> {
    const user = await this.users.findById(ctx.userOid).select('+passwordHash').lean<any>();
    if (!user?.passwordHash) throw new ApiError(HttpStatus.CONFLICT, 'NO_PASSWORD', "Your account doesn't have a password. Confirm with an email code instead.");
    await this.assertNotLocked(user);
    if (!verifyPassword(password, user.passwordHash)) {
      await this.recordFailure(user, 'reauth_password', 'bad_password', client);
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'INVALID_CREDENTIALS', 'That password is not right.');
    }
    await this.users.updateOne({ _id: user._id }, { $set: { failedLogins: 0 } });
    await this.sessions.markReauth(ctx.user.sessionId);
    await this.audit.record(ctx, { action: 'auth.reauth', resourceType: 'session', resourceId: ctx.user.sessionId });
    const org = await this.orgSettings.get(ctx.orgOid);
    return { reauthenticated: true, validForMinutes: org?.settings?.security?.reauthMinutes ?? 10 };
  }

  /**
   * Sets or changes the signed-in user's own password. With an existing password the current one
   * is required; without one (email-code accounts) a recent re-authentication is required.
   * Other sessions are signed out.
   */
  async changePassword(ctx: Ctx, currentPassword: string | undefined, newPassword: string, client: ClientInfo, reauthAt?: Date): Promise<{ changed: true; otherSessionsSignedOut: number }> {
    const user = await this.users.findById(ctx.userOid).select('+passwordHash').lean<any>();
    if (!user) throw new ApiError(HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Sign in to continue.');
    if (user.passwordHash) {
      await this.assertNotLocked(user);
      if (!currentPassword || !verifyPassword(currentPassword, user.passwordHash)) {
        await this.recordFailure(user, 'password_change', 'bad_password', client);
        throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', 'Your current password is not right.', [{ field: 'currentPassword', message: 'Not right' }]);
      }
    } else {
      const org = await this.orgSettings.get(ctx.orgOid);
      const windowMs = (org?.settings?.security?.reauthMinutes ?? 10) * 60_000;
      if (!reauthAt || Date.now() - new Date(reauthAt).getTime() > windowMs) {
        throw new ApiError(HttpStatus.FORBIDDEN, 'REAUTH_REQUIRED', 'Confirm it is you to continue.');
      }
    }
    const problem = passwordProblem(newPassword, [user.email, user.fullName, ...(user.fullName ?? '').split(' ')]);
    if (problem) throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', problem, [{ field: 'newPassword', message: problem }]);
    if (user.passwordHash && verifyPassword(newPassword, user.passwordHash)) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', 'Choose a password different from the current one.', [{ field: 'newPassword', message: 'Same as current' }]);
    }
    await this.users.updateOne({ _id: user._id }, { $set: { passwordHash: hashPassword(newPassword), mustChangePassword: false, passwordSetAt: new Date(), failedLogins: 0 } });
    const revoked = await this.sessions.revokeAll(user._id, 'password_changed', ctx.user.sessionId);
    await this.audit.record(ctx, { action: user.passwordHash ? 'auth.password_changed' : 'auth.password_set', resourceType: 'user', resourceId: user._id });
    return { changed: true, otherSessionsSignedOut: revoked };
  }

  // ------------------------------------------------------------------ invitations

  async invitationInfo(token: string): Promise<{ email?: string; organization: string; role: string; expiresAt: Date }> {
    const inv = await this.invitations.findOne({ tokenHash: sha256(token) }).lean<any>();
    if (!inv || inv.status !== 'pending' || inv.expiresAt < new Date()) {
      throw new ApiError(HttpStatus.GONE, 'INVITATION_INVALID', 'This invitation is no longer valid. Ask your administrator to send a new one.');
    }
    const org = await this.orgSettings.get(inv.organizationId);
    return { email: inv.email ? maskIdentifier(inv.email) : undefined, organization: org?.name ?? '', role: inv.role, expiresAt: inv.expiresAt };
  }

  /** Accepting needs both the link token and a code sent to the invited email: proves control of the address. */
  async acceptInvitation(token: string, code: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const inv = await this.invitations.findOne({ tokenHash: sha256(token) }).lean<any>();
    if (!inv || inv.status !== 'pending' || inv.expiresAt < new Date()) {
      throw new ApiError(HttpStatus.GONE, 'INVITATION_INVALID', 'This invitation is no longer valid. Ask your administrator to send a new one.');
    }
    await this.consumeOtp(inv.email, code, 'login');
    const user = await this.users.findOne({ _id: inv.userId, organizationId: inv.organizationId }).lean<any>();
    if (!user) throw new ApiError(HttpStatus.GONE, 'INVITATION_INVALID', 'This invitation is no longer valid.');
    if (['suspended', 'blocked', 'inactive'].includes(user.status)) {
      throw new ApiError(HttpStatus.FORBIDDEN, 'ACCOUNT_SUSPENDED', 'This account is not active. Contact your administrator.');
    }
    const r = await this.invitations.updateOne({ _id: inv._id, status: 'pending' }, { $set: { status: 'accepted', acceptedAt: new Date() } });
    if (r.modifiedCount !== 1) throw new ApiError(HttpStatus.CONFLICT, 'INVITATION_USED', 'This invitation was already accepted.');
    await this.users.updateOne({ _id: user._id }, { $set: { status: 'active', emailVerified: true } });
    await this.audit.record(null, { action: 'invitation.accept', resourceType: 'user', resourceId: user._id }, user.organizationId);
    return this.completeLogin({ ...user, status: 'active' }, 'invitation', client);
  }

  // ------------------------------------------------------------------ re-authentication

  async requestReauth(ctx: Ctx): Promise<unknown> {
    const user = await this.users.findById(ctx.userOid).lean<any>();
    if (!user?.email) throw new ApiError(HttpStatus.BAD_REQUEST, 'NO_EMAIL', 'Add an email address to your profile first.');
    return this.requestOtp(user.email, 'reauth', ctx.ip, user);
  }

  async verifyReauth(ctx: Ctx, code: string): Promise<{ reauthenticated: true; validForMinutes: number }> {
    const user = await this.users.findById(ctx.userOid).lean<any>();
    await this.consumeOtp(user.email, code, 'reauth');
    await this.sessions.markReauth(ctx.user.sessionId);
    await this.audit.record(ctx, { action: 'auth.reauth', resourceType: 'session', resourceId: ctx.user.sessionId });
    const org = await this.orgSettings.get(ctx.orgOid);
    return { reauthenticated: true, validForMinutes: org?.settings?.security?.reauthMinutes ?? 10 };
  }

  // ------------------------------------------------------------------ recovery codes

  /** Generates 10 one-time recovery codes. Returned once; only hashes are stored. */
  async generateRecoveryCodes(ctx: Ctx): Promise<{ codes: string[] }> {
    const codes = Array.from({ length: 10 }, () => randomToken(8).replace(/[^A-Za-z0-9]/g, '').slice(0, 10).toUpperCase());
    await this.recoveryCodes.deleteMany({ userId: ctx.userOid });
    await this.recoveryCodes.insertMany(codes.map((c) => ({ organizationId: ctx.orgOid, userId: ctx.userOid, codeHash: hmac(secretOf(this.env, 'OTP_PEPPER'), c) })));
    await this.users.updateOne({ _id: ctx.userOid }, { $set: { recoveryCodesGeneratedAt: new Date() } });
    await this.audit.record(ctx, { action: 'auth.recovery_codes_generated', resourceType: 'user', resourceId: ctx.user.userId });
    return { codes };
  }

  /** Recovers the existing account (never creates a replacement): revokes every session, then signs in. */
  async recover(raw: string, recoveryCode: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const { channel, value } = normalizeIdentifier(raw);
    const user = await this.findUserByIdentifier(channel, value);
    if (!user) throw new ApiError(HttpStatus.UNAUTHORIZED, 'RECOVERY_INVALID', 'That recovery code is not valid.');
    await this.assertNotLocked(user);
    const hash = hmac(secretOf(this.env, 'OTP_PEPPER'), recoveryCode.trim().toUpperCase());
    const used = await this.recoveryCodes.findOneAndUpdate({ userId: user._id, codeHash: hash, usedAt: null }, { $set: { usedAt: new Date() } });
    if (!used) {
      await this.recordFailure(user, 'recovery', 'bad_recovery_code', client);
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'RECOVERY_INVALID', 'That recovery code is not valid.');
    }
    const revoked = await this.sessions.revokeAll(user._id, 'account_recovery');
    await this.alerts.create({ organizationId: user.organizationId, type: 'account_recovery', severity: 'high', userId: user._id, message: `Account recovered with a recovery code; ${revoked} session(s) signed out.`, data: { ip: client.ip } });
    await this.audit.record(null, { action: 'auth.recovered', resourceType: 'user', resourceId: user._id }, user.organizationId);
    return this.completeLogin(user, 'recovery', client);
  }

  // ------------------------------------------------------------------ shared

  private async findUserByIdentifier(channel: 'email' | 'phone', value: string): Promise<any | null> {
    const matches = await this.users.find(channel === 'email' ? { email: value } : { phone: value }).limit(2).lean<any[]>();
    // Single-organization deployment: one match. Multi-org: the client passes the organization (future).
    return matches[0] ?? null;
  }

  private async assertNotLocked(user: any): Promise<void> {
    if (user.lockedUntil && new Date(user.lockedUntil) > new Date()) {
      const mins = Math.ceil((new Date(user.lockedUntil).getTime() - Date.now()) / 60_000);
      throw new ApiError(HttpStatus.TOO_MANY_REQUESTS, 'ACCOUNT_LOCKED', `Too many failed attempts. Try again in ${mins} minute${mins === 1 ? '' : 's'}.`);
    }
  }

  private async recordFailure(user: any, provider: string, reason: string, client: ClientInfo): Promise<void> {
    const org = await this.orgSettings.get(user.organizationId);
    const max = org?.settings?.security?.maxFailedLogins ?? 5;
    const lockMinutes = org?.settings?.security?.lockMinutes ?? 15;
    const updated = await this.users.findOneAndUpdate({ _id: user._id }, { $inc: { failedLogins: 1 } }, { new: true }).lean<any>();
    const lock = (updated?.failedLogins ?? 0) >= max;
    if (lock) {
      await this.users.updateOne({ _id: user._id }, { $set: { lockedUntil: new Date(Date.now() + lockMinutes * 60_000), failedLogins: 0 } });
      await this.alerts.create({ organizationId: user.organizationId, type: 'failed_logins', severity: 'medium', userId: user._id, message: `Account locked for ${lockMinutes} minutes after ${max} failed sign-in attempts.`, data: { ip: client.ip } });
    }
    await this.loginEvents.create({ organizationId: user.organizationId, userId: user._id, identifier: maskIdentifier(user.email ?? user.phone ?? ''), provider, outcome: lock ? 'locked' : 'failure', reason, ip: client.ip, userAgent: client.userAgent?.slice(0, 300), deviceId: client.deviceId, at: new Date() });
  }

  /** Account status checks happen here: authenticating successfully is not enough. */
  private async completeLogin(user: any, provider: string, client: ClientInfo): Promise<IssuedSession & { user: any }> {
    const org = await this.orgSettings.get(user.organizationId);
    const blocked: Record<string, [string, string]> = {
      suspended: ['ACCOUNT_SUSPENDED', 'Your account is suspended. Contact your administrator.'],
      blocked: ['ACCOUNT_SUSPENDED', 'Your account is blocked. Contact your administrator.'],
      inactive: ['ACCOUNT_INACTIVE', 'Your account is no longer active.'],
      invited: ['INVITATION_NOT_ACCEPTED', 'Open the invitation link from your email to activate your account.'],
    };
    const deny = blocked[user.status] ?? (org?.status !== 'active' ? ['ORGANIZATION_SUSPENDED', 'This organization is suspended.'] : null);
    if (deny) {
      await this.loginEvents.create({ organizationId: user.organizationId, userId: user._id, provider, outcome: 'blocked', reason: deny[0], ip: client.ip, userAgent: client.userAgent?.slice(0, 300), at: new Date() });
      throw new ApiError(HttpStatus.FORBIDDEN, deny[0], deny[1]);
    }
    const issued = await this.sessions.issue(user, provider, client);
    await this.loginEvents.create({ organizationId: user.organizationId, userId: user._id, identifier: maskIdentifier(user.email ?? user.phone ?? ''), provider, outcome: 'success', ip: client.ip, userAgent: client.userAgent?.slice(0, 300), deviceId: client.deviceId, at: new Date() });
    return { ...issued, user };
  }

  /** Everything the client needs after sign-in: who, which organization, which permissions, which modules. */
  async me(userId: string): Promise<Record<string, unknown>> {
    const user = await this.users.findById(userId).select('+passwordHash').lean<any>();
    if (!user) throw new ApiError(HttpStatus.UNAUTHORIZED, 'UNAUTHENTICATED', 'Sign in to continue.');
    const [org, employee, prefs] = await Promise.all([
      this.orgSettings.get(user.organizationId),
      user.employeeId ? this.employees.findById(user.employeeId, { sensitive: 0 }).lean<any>() : null,
      this.prefs.findOne({ organizationId: user.organizationId, userId: user._id }).lean<any>(),
    ]);
    const authUser = { userId: String(user._id), orgId: String(user.organizationId), role: user.role, sessionId: '', name: user.fullName };
    const grants = await this.perms.grantsFor(authUser, user.permissionsVersion ?? 1);
    const authz = PermissionsService.build(grants, user.role);
    return {
      user: serialize({ ...user, hasPassword: !!user.passwordHash, mustChangePassword: !!user.mustChangePassword, passwordHash: undefined, googleSub: undefined, appleSub: undefined, failedLogins: undefined }),
      employee: serialize(employee),
      organization: serialize({
        _id: org._id,
        name: org.name,
        logoFileId: org.logoFileId,
        timezone: org.timezone,
        currency: org.currency,
        dateFormat: org.dateFormat,
        timeFormat: org.timeFormat,
        weekStart: org.weekStart,
        features: this.orgSettings.features(org),
        nuiDefaults: org.nuiDefaults ?? {},
        nuiPresets: org.nuiPresets ?? [],
        attendance: org.settings?.attendance,
      }),
      role: user.role,
      permissions: PermissionsService.describe(authz),
      preferences: prefs?.nui ?? null,
      dashboard: prefs?.dashboard ?? null,
      profileComplete: !!(user.displayName && user.timezone),
    };
  }
}
