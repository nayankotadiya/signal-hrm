import { Logger, HttpStatus, Inject, Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { ROLES, RoleKey, parseGrant } from '../../common/authz/catalog';
import { PermissionsService } from '../../common/authz/permissions.service';
import { hashPassword, randomToken, sha256, temporaryPassword } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { badRequest, conflict, escapeRegex, forbidden, ListQuery, notFound, oid, Paged, sortSpec } from '../../common/http/validation';
import { MailService } from '../../common/mail/mail.service';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { SessionService } from '../auth/session.service';
import { NotificationsService } from '../notifications/notifications.service';

export const createUserInput = z.object({
  fullName: z.string().trim().min(2).max(120),
  email: z.string().trim().toLowerCase().email().optional(),
  phone: z.string().regex(/^\+[1-9]\d{7,14}$/).optional(),
  role: z.enum(ROLES).default('employee'),
  employeeId: z.string().optional(),
  sendInvitation: z.boolean().default(true),
  password: z.string().min(6).max(128).optional(),
});

const PUBLIC_FIELDS = { passwordHash: 0, googleSub: 0, appleSub: 0 };

@Injectable()
export class UsersService {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly mail: MailService,
    private readonly perms: PermissionsService,
    private readonly sessions: SessionService,
    private readonly notifications: NotificationsService,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Invitation') private readonly invitations: Model<any>,
    @InjectModel('UserPermission') private readonly userPerms: Model<any>,
    @InjectModel('PermissionChange') private readonly changes: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
  ) {}

  async list(ctx: Ctx, q: ListQuery & { role?: string }): Promise<Paged<any>> {
    PermissionsService.require(ctx, 'users', 'view', 'organization');
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!ctx.authz.isSuperAdmin) {
      filter.role = { $ne: 'super_admin' };
    }
    if (q.status) filter.status = q.status;
    if (q.role) {
      if (q.role === 'super_admin' && !ctx.authz.isSuperAdmin) {
        return { items: [], page: q.page, limit: q.limit, total: 0, hasMore: false };
      }
      filter.role = q.role;
    }
    if (q.q) {
      const rx = new RegExp(escapeRegex(q.q), 'i');
      filter.$or = [{ fullName: rx }, { email: rx }, { phone: rx }];
    }
    const [items, total] = await Promise.all([
      this.users.find(filter, PUBLIC_FIELDS).sort(sortSpec(q.sort, ['fullName', 'createdAt', 'lastLoginAt', 'role'], { fullName: 1 })).skip((q.page - 1) * q.limit).limit(q.limit).lean(),
      this.users.countDocuments(filter),
    ]);
    return { items: serialize(items), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    if (id !== ctx.user.userId) PermissionsService.require(ctx, 'users', 'view', 'organization');
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }, PUBLIC_FIELDS).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin && String(user._id) !== ctx.user.userId) {
      throw notFound('User');
    }
    return serialize(user);
  }

  /** Creates an account (status "invited") and emails a one-time invitation link. */
  async create(ctx: Ctx, input: z.infer<typeof createUserInput>): Promise<any> {
    PermissionsService.require(ctx, 'users', 'create', 'organization');
    if (!input.email && !input.phone) throw badRequest('CONTACT_REQUIRED', 'Add an email address or phone number.', 'email');
    if (input.role === 'super_admin') throw forbidden('USE_SUPER_ADMIN_FLOW', 'Create Super Admins from Security with re-authentication.');
    if (!PermissionsService.canAssignRole(ctx, input.role)) throw forbidden('GRANT_AUTHORITY', "You can't assign a role with permissions you don't hold.");
    if (input.email && (await this.users.exists({ organizationId: ctx.orgOid, email: input.email }))) {
      throw conflict('EMAIL_TAKEN', 'An account with this email already exists.');
    }
    if (input.employeeId) {
      const emp = await this.employees.findOne({ _id: oid(input.employeeId), organizationId: ctx.orgOid }).lean<any>();
      if (!emp) throw notFound('Employee');
      if (emp.userId) throw conflict('EMPLOYEE_HAS_ACCOUNT', 'This employee already has an account.');
    }
    const hasPassword = Boolean(input.password && input.password.trim().length >= 6);
    const pwdHash = hasPassword ? hashPassword(input.password!.trim()) : undefined;
    const user = await this.users.create({
      organizationId: ctx.orgOid,
      fullName: input.fullName,
      email: input.email,
      phone: input.phone,
      role: input.role,
      status: hasPassword ? 'active' : 'invited',
      passwordHash: pwdHash,
      passwordSetAt: hasPassword ? new Date() : undefined,
      mustChangePassword: false,
      employeeId: input.employeeId ? oid(input.employeeId) : undefined,
      invitedBy: ctx.userOid,
      createdBy: ctx.userOid,
    });
    if (input.employeeId) await this.employees.updateOne({ _id: oid(input.employeeId) }, { $set: { userId: user._id } });
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, targetUserId: user._id, roleKey: input.role, change: 'role_assigned', after: { role: input.role } });
    await this.audit.record(ctx, { action: 'user.create', resourceType: 'user', resourceId: user._id, changes: { role: { from: null, to: input.role } } });
    let invitation: { link: string } | undefined;
    if (!hasPassword && input.sendInvitation && this.mail.canSend) {
      invitation = await this.invite(ctx, user);
    } else if (hasPassword && user.email && this.mail.canSend && input.sendInvitation) {
      const org = await this.orgs.findById(ctx.orgOid, { name: 1 }).lean<any>();
      await this.mail.send({
        to: user.email,
        subject: `Your Signal HRM account has been created`,
        text: `Hello ${user.fullName},\n\nYour account on ${org?.name ?? 'Signal HRM'} has been created.\n\nLogin ID / Email: ${user.email}\nYour password has been set by the administrator.\n\nSign in here: ${this.env.PUBLIC_WEB_URL}/login`,
      }).catch((e) => this.mail.canSend && new Logger('Users').warn(`Welcome email failed: ${e?.message}`));
    }
    return { ...serialize({ ...user.toObject(), passwordHash: undefined }), hasPassword, invitationSent: !!invitation, emailConfigured: this.mail.canSend };
  }

  async invite(ctx: Ctx, user: any): Promise<{ link: string }> {
    if (user.email && !this.mail.canSend) {
      throw conflict('EMAIL_NOT_CONFIGURED', "Email isn't set up on this server, so invitations can't be sent. Set a temporary password instead.");
    }
    const token = randomToken(32);
    await this.invitations.updateMany({ organizationId: ctx.orgOid, userId: user._id, status: 'pending' }, { $set: { status: 'revoked' } });
    await this.invitations.create({
      organizationId: ctx.orgOid,
      email: user.email,
      phone: user.phone,
      role: user.role,
      userId: user._id,
      employeeId: user.employeeId,
      tokenHash: sha256(token),
      expiresAt: new Date(Date.now() + 7 * 86400_000),
      invitedBy: ctx.userOid,
    });
    const org = await this.orgs.findById(ctx.orgOid, { name: 1 }).lean<any>();
    const link = `${this.env.PUBLIC_WEB_URL}/invite/${token}`;
    // Development only (same switch as OTP echo): print the link so invitations can be tested without SMTP.
    if (this.env.OTP_DEV_ECHO && this.env.APP_ENV === 'development') new Logger('Users').warn(`[dev] Invitation for ${user.email ?? user.phone}: ${link}`);
    if (user.email) {
      await this.mail.send({
        to: user.email,
        subject: `You're invited to ${org?.name ?? 'Signal HRM'}`,
        text: `${ctx.user.name} invited you to ${org?.name ?? 'Signal HRM'} on Signal HRM.\n\nAccept the invitation: ${link}\n\nThe link works for 7 days.`,
      });
    }
    await this.audit.record(ctx, { action: 'user.invite', resourceType: 'user', resourceId: user._id });
    return { link };
  }

  async resendInvitation(ctx: Ctx, id: string): Promise<{ sent: true }> {
    PermissionsService.require(ctx, 'users', 'create', 'organization');
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    if (user.status !== 'invited') throw conflict('ALREADY_ACTIVE', 'This person already accepted their invitation.');
    await this.invite(ctx, user);
    return { sent: true };
  }

  /** suspended | active | inactive. Super Admin accounts can only be changed by a Super Admin. */
  /**
   * Issues a one-time temporary password (shown once to the administrator, never stored in plain
   * text). Activates an invited account, signs the person out everywhere and makes them choose
   * their own password at the next sign-in. Requires password sign-in to be on.
   */
  async setTemporaryPassword(ctx: Ctx, id: string): Promise<{ temporaryPassword: string; user: any }> {
    PermissionsService.require(ctx, 'users', 'manage', 'organization');
    const org = await this.orgs.findById(ctx.orgOid, { settings: 1 }).lean<any>();
    const passwordLoginOn = this.env.PASSWORD_LOGIN || !!org?.settings?.security?.passwordLogin;
    if (!passwordLoginOn) throw conflict('PASSWORD_LOGIN_DISABLED', 'Turn on password sign-in first (server setting PASSWORD_LOGIN or Security settings).');
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    if (String(user._id) === ctx.user.userId) throw forbidden('SELF_TEMP_PASSWORD', 'Change your own password from your account page.');
    if (['suspended', 'blocked', 'inactive'].includes(user.status)) throw conflict('ACCOUNT_NOT_ACTIVE', 'Reactivate this account before setting a password.');
    const temporary = temporaryPassword();
    const set: Record<string, unknown> = { passwordHash: hashPassword(temporary), mustChangePassword: true, passwordSetAt: new Date(), failedLogins: 0, lockedUntil: null };
    if (user.status === 'invited') set.status = 'active';
    await this.users.updateOne({ _id: user._id }, { $set: set });
    if (user.status === 'invited') await this.invitations.updateMany({ organizationId: ctx.orgOid, userId: user._id, status: 'pending' }, { $set: { status: 'revoked' } });
    await this.sessions.revokeAll(user._id, 'temporary_password');
    await this.audit.record(ctx, { action: 'user.temporary_password', resourceType: 'user', resourceId: user._id, changes: user.status === 'invited' ? { status: { from: 'invited', to: 'active' } } : undefined });
    return { temporaryPassword: temporary, user: await this.get(ctx, id) };
  }

  async setStatus(ctx: Ctx, id: string, status: 'active' | 'suspended' | 'inactive', reason?: string): Promise<any> {
    PermissionsService.require(ctx, 'users', 'manage', 'organization');
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    if (String(user._id) === ctx.user.userId) throw forbidden('SELF_STATUS', "You can't change your own account status.");
    if (user.role === 'super_admin' && status !== 'active') {
      const others = await this.users.countDocuments({ organizationId: ctx.orgOid, role: 'super_admin', status: 'active', _id: { $ne: user._id } });
      if (others === 0) throw conflict('LAST_SUPER_ADMIN', 'The last active Super Admin cannot be suspended.');
    }
    await this.users.updateOne({ _id: user._id }, { $set: { status } });
    if (status !== 'active') await this.sessions.revokeAll(user._id, `status_${status}`);
    await this.audit.record(ctx, { action: `user.${status}`, resourceType: 'user', resourceId: user._id, changes: { status: { from: user.status, to: status }, ...(reason ? { reason: { from: null, to: reason } } : {}) } });
    return this.get(ctx, id);
  }

  /** Role change: validated against the caller's grant authority, audited, sessions keep working with refreshed permissions. */
  async setRole(ctx: Ctx, id: string, role: RoleKey): Promise<any> {
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    if (String(user._id) === ctx.user.userId) throw forbidden('SELF_ROLE', "You can't change your own role.");
    if (role === 'super_admin') throw forbidden('USE_SUPER_ADMIN_FLOW', 'Create Super Admins from Security with re-authentication.');
    if (!PermissionsService.canAssignRole(ctx, role)) throw forbidden('GRANT_AUTHORITY', "You can't assign a role with permissions you don't hold.");
    if (user.role === 'super_admin') {
      const others = await this.users.countDocuments({ organizationId: ctx.orgOid, role: 'super_admin', status: 'active', _id: { $ne: user._id } });
      if (others === 0) throw conflict('LAST_SUPER_ADMIN', 'The last Super Admin cannot be demoted.');
    }
    await this.users.updateOne({ _id: user._id }, { $set: { role }, $inc: { permissionsVersion: 1 } });
    this.perms.invalidate(String(user._id));
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, targetUserId: user._id, roleKey: role, change: 'role_assigned', before: { role: user.role }, after: { role } });
    await this.audit.record(ctx, { action: 'user.role_change', resourceType: 'user', resourceId: user._id, changes: { role: { from: user.role, to: role } } });
    return this.get(ctx, id);
  }

  async addGrant(ctx: Ctx, id: string, grant: string, recordIds: string[] | undefined, reason: string | undefined, expiresAt?: Date): Promise<any> {
    if (!parseGrant(grant)) throw badRequest('GRANT_INVALID', 'That permission is not valid.', 'grant');
    if (!PermissionsService.canGrant(ctx, grant)) throw forbidden('GRANT_AUTHORITY', "You can't grant a permission you don't hold at that scope.");
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    await this.userPerms.updateOne(
      { organizationId: ctx.orgOid, userId: user._id, grant },
      { $set: { recordIds, reason, expiresAt, grantedBy: ctx.userOid } },
      { upsert: true },
    );
    await this.users.updateOne({ _id: user._id }, { $inc: { permissionsVersion: 1 } });
    this.perms.invalidate(String(user._id));
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, targetUserId: user._id, change: 'grant_added', after: { grant, recordIds, expiresAt } });
    await this.audit.record(ctx, { action: 'permission.grant', resourceType: 'user', resourceId: user._id, changes: { grant: { from: null, to: grant } } });
    return this.permissionsOf(ctx, id);
  }

  async removeGrant(ctx: Ctx, id: string, grant: string): Promise<any> {
    if (!PermissionsService.canGrant(ctx, grant)) throw forbidden('GRANT_AUTHORITY', "You can't remove a permission you couldn't grant.");
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    const r = await this.userPerms.deleteOne({ organizationId: ctx.orgOid, userId: oid(id), grant });
    if (!r.deletedCount) throw notFound('Permission');
    await this.users.updateOne({ _id: oid(id) }, { $inc: { permissionsVersion: 1 } });
    this.perms.invalidate(id);
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, targetUserId: oid(id), change: 'grant_removed', before: { grant } });
    await this.audit.record(ctx, { action: 'permission.revoke', resourceType: 'user', resourceId: id, changes: { grant: { from: grant, to: null } } });
    return this.permissionsOf(ctx, id);
  }

  /** "Who can do what" preview for one user: role grants + individual grants. */
  async permissionsOf(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'roles', 'view', 'organization');
    const user = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!user) throw notFound('User');
    if (user.role === 'super_admin' && !ctx.authz.isSuperAdmin && String(user._id) !== ctx.user.userId) throw notFound('User');
    const grants = await this.perms.grantsFor({ userId: String(user._id), orgId: ctx.user.orgId, role: user.role, sessionId: '', name: user.fullName }, user.permissionsVersion);
    const extras = await this.userPerms.find({ organizationId: ctx.orgOid, userId: user._id }).lean();
    return { role: user.role, effective: PermissionsService.describe(PermissionsService.build(grants, user.role)), individual: serialize(extras) };
  }

  /**
   * Super Admin creation: existing Super Admin only, after strong re-authentication (enforced by the
   * controller), audited, and every Super Admin receives a security notification.
   */
  async createSuperAdmin(ctx: Ctx, input: { fullName: string; email: string }): Promise<any> {
    if (!ctx.authz.isSuperAdmin) throw forbidden('SUPER_ADMIN_ONLY', 'Only a Super Admin can create another Super Admin.');
    if (await this.users.exists({ organizationId: ctx.orgOid, email: input.email.toLowerCase() })) throw conflict('EMAIL_TAKEN', 'An account with this email already exists.');
    const user = await this.users.create({ organizationId: ctx.orgOid, fullName: input.fullName, email: input.email.toLowerCase(), role: 'super_admin', status: 'invited', invitedBy: ctx.userOid, createdBy: ctx.userOid });
    await this.invite(ctx, user);
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, targetUserId: user._id, roleKey: 'super_admin', change: 'role_assigned', after: { role: 'super_admin' } });
    await this.audit.record(ctx, { action: 'user.super_admin_created', resourceType: 'user', resourceId: user._id });
    await this.alerts.create({ organizationId: ctx.orgOid, type: 'new_super_admin', severity: 'high', userId: user._id, message: `${ctx.user.name} created a new Super Admin (${input.email}).` });
    const admins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin', status: 'active' }, { _id: 1 }).lean();
    await this.notifications.notify(ctx.orgOid, admins.map((a: any) => a._id), {
      event: 'security_alert',
      title: 'New Super Admin created',
      body: `${ctx.user.name} invited ${input.fullName} as Super Admin.`,
      link: '/security',
      priority: 'essential',
    });
    return serialize({ ...user.toObject(), passwordHash: undefined });
  }

  static ensure(cond: unknown, code: string, message: string): void {
    if (!cond) throw new ApiError(HttpStatus.BAD_REQUEST, code, message);
  }

  static oid = (s: string) => new Types.ObjectId(s);
}
