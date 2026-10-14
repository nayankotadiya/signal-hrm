import { Body, Controller, Get, HttpCode, Param, Post, Query, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { C, Can, Ctx, Feature } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { badRequest, conflict, escapeRegex, forbidden, listQuery, notFound, objectId, oid, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';
import { SessionService } from '../auth/session.service';
import { NotificationsService } from '../notifications/notifications.service';

// ---------------------------------------------------------------- moderation

const reportBody = z.object({
  contentType: z.enum(['announcement', 'kudos', 'task_comment', 'document', 'profile', 'file', 'other']),
  contentId: objectId.optional(),
  reportedUserId: objectId.optional(),
  reason: z.string().trim().min(5).max(1000),
  severity: z.enum(['low', 'medium', 'high', 'critical']).default('medium'),
});

@ApiTags('moderation')
@Feature('moderation')
@Controller({ path: 'moderation', version: '1' })
export class ModerationController {
  constructor(
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    @InjectModel('ModerationReport') private readonly reports: Model<any>,
    @InjectModel('ModerationAction') private readonly actions: Model<any>,
    @InjectModel('Announcement') private readonly announcements: Model<any>,
    @InjectModel('TaskComment') private readonly comments: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  /** Context with minimal necessary access: only the reported item, never surrounding private content. */
  private async snapshot(orgId: Types.ObjectId, type: string, id?: string): Promise<Record<string, unknown> | undefined> {
    if (!id) return undefined;
    if (type === 'announcement' || type === 'kudos') {
      const a = await this.announcements.findOne({ _id: oid(id), organizationId: orgId }, { title: 1, body: 1, createdBy: 1, publishedAt: 1 }).lean<any>();
      return a ? { title: a.title, body: a.body?.slice(0, 2000), authorId: String(a.createdBy), publishedAt: a.publishedAt } : undefined;
    }
    if (type === 'task_comment') {
      const c = await this.comments.findOne({ _id: oid(id), organizationId: orgId }, { body: 1, authorId: 1, createdAt: 1 }).lean<any>();
      return c ? { body: c.body?.slice(0, 2000), authorId: String(c.authorId), at: c.createdAt } : undefined;
    }
    return undefined;
  }

  /** Anyone can report content; moderators review it. */
  @Post('reports')
  async report(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(reportBody, body);
    const context = await this.snapshot(ctx.orgOid, b.contentType, b.contentId);
    const r = await this.reports.create({ ...b, contentId: b.contentId ? oid(b.contentId) : undefined, reportedUserId: b.reportedUserId ? oid(b.reportedUserId) : context?.authorId ? oid(String(context.authorId)) : undefined, organizationId: ctx.orgOid, reporterId: ctx.userOid, context });
    const mods = await this.users.find({ organizationId: ctx.orgOid, role: 'moderator', status: 'active' }, { _id: 1 }).lean<any[]>();
    if (b.severity === 'critical' || b.severity === 'high') await this.notifications.notify(ctx.orgOid, mods.map((m) => m._id), { event: 'moderation_escalation', title: `New ${b.severity} report`, body: b.reason.slice(0, 140), link: `/moderation/${r._id}` });
    return { reported: true, id: String(r._id) };
  }

  @Get('reports')
  @Can('moderation', 'view')
  async list(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.extend({ severity: z.string().optional() }), q);
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    filter.status = b.status ? b.status : { $in: ['open', 'in_review', 'escalated'] };
    if (b.severity) filter.severity = b.severity;
    const [items, total, bySeverity] = await Promise.all([
      this.reports.find(filter, { context: 0 }).sort({ createdAt: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(),
      this.reports.countDocuments(filter),
      this.reports.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $in: ['open', 'in_review', 'escalated'] } } }, { $group: { _id: '$severity', n: { $sum: 1 } } }]),
    ]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total, bySeverity: Object.fromEntries(bySeverity.map((s: any) => [s._id, s.n])) };
  }

  @Get('reports/:id')
  @Can('moderation', 'view')
  async get(@C() ctx: Ctx, @Param('id') id: string) {
    const r = await this.reports.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!r) throw notFound('Report');
    await this.audit.record(ctx, { action: 'moderation.view', resourceType: 'moderation_report', resourceId: id });
    const history = await this.actions.find({ reportId: r._id }).sort({ createdAt: -1 }).lean();
    if (r.status === 'open') await this.reports.updateOne({ _id: r._id }, { $set: { status: 'in_review', assignedModeratorId: ctx.userOid } });
    return { ...serialize(r), actions: serialize(history) };
  }

  @Post('reports/:id/action')
  @Can('moderation', 'manage')
  @HttpCode(200)
  async act(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ action: z.enum(['dismiss', 'warn', 'hide_content', 'restrict', 'escalate', 'restore']), notes: z.string().trim().min(3).max(1000), restrictDays: z.number().int().min(1).max(90).optional() }), body);
    const r = await this.reports.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!r) throw notFound('Report');
    if (['dismissed', 'actioned'].includes(r.status) && b.action !== 'restore') throw conflict('REPORT_CLOSED', 'This report is already closed.');
    if (r.reportedUserId && String(r.reportedUserId) === ctx.user.userId) throw forbidden('SELF_MODERATION', "You can't decide a report about yourself.");
    if (b.action === 'hide_content' || b.action === 'restore') {
      const hide = b.action === 'hide_content';
      if (['announcement', 'kudos'].includes(r.contentType) && r.contentId) await this.announcements.updateOne({ _id: r.contentId }, { $set: { publishedAt: hide ? null : new Date() } });
      if (r.contentType === 'task_comment' && r.contentId) await this.comments.updateOne({ _id: r.contentId }, hide ? { $set: { body: '[removed by a moderator]' } } : {});
    }
    if (b.action === 'restrict' && r.reportedUserId) {
      // Restriction = cannot post announcements or kudos until it expires (not an account suspension).
      if (!b.restrictDays) throw badRequest('DAYS_REQUIRED', 'Choose how long the restriction lasts.', 'restrictDays');
    }
    if (b.action === 'warn' && r.reportedUserId) {
      await this.notifications.notify(ctx.orgOid, [r.reportedUserId], { event: 'moderation_escalation', title: 'A moderator reviewed your content', body: b.notes.slice(0, 200), priority: 'high' });
    }
    if (b.action === 'escalate') {
      const admins = await this.users.find({ organizationId: ctx.orgOid, role: { $in: ['super_admin', 'admin'] }, status: 'active' }, { _id: 1 }).lean<any[]>();
      await this.notifications.notify(ctx.orgOid, admins.map((a) => a._id), { event: 'moderation_escalation', title: 'Moderation escalation', body: b.notes.slice(0, 200), link: `/moderation/${id}`, priority: 'high' });
    }
    await this.actions.create({ organizationId: ctx.orgOid, reportId: r._id, moderatorId: ctx.userOid, targetUserId: r.reportedUserId, action: b.action, notes: b.notes, expiresAt: b.restrictDays ? new Date(Date.now() + b.restrictDays * 86400_000) : undefined });
    const status = b.action === 'dismiss' ? 'dismissed' : b.action === 'escalate' ? 'escalated' : b.action === 'restore' ? 'open' : 'actioned';
    await this.reports.updateOne({ _id: r._id }, { $set: { status, action: b.action, decisionNotes: b.notes, resolvedAt: ['dismissed', 'actioned'].includes(status) ? new Date() : null } });
    await this.audit.record(ctx, { action: `moderation.${b.action}`, resourceType: 'moderation_report', resourceId: id });
    return this.get(ctx, id);
  }

  @Get('history')
  @Can('moderation', 'view')
  async history(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery, q);
    const [items, total] = await Promise.all([this.actions.find({ organizationId: ctx.orgOid }).sort({ createdAt: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(), this.actions.countDocuments({ organizationId: ctx.orgOid })]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }
}

// ---------------------------------------------------------------- audit logs

const auditQuery = listQuery.extend({
  actorId: objectId.optional(),
  resourceType: z.string().max(40).optional(),
  resourceId: z.string().max(40).optional(),
  action: z.string().max(60).optional(),
  outcome: z.enum(['success', 'failure', 'denied']).optional(),
  from: z.coerce.date().optional(),
  to: z.coerce.date().optional(),
});

@ApiTags('audit')
@Controller({ path: 'audit', version: '1' })
export class AuditController {
  constructor(
    private readonly audit: AuditService,
    @InjectModel('AuditLog') private readonly logs: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  private async filter(ctx: Ctx, b: z.infer<typeof auditQuery>): Promise<Record<string, unknown>> {
    const f: Record<string, any> = { organizationId: ctx.orgOid };
    if (!ctx.authz.isSuperAdmin) {
      const superAdmins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin' }, { _id: 1 }).lean<any[]>();
      const saIds = superAdmins.map((s) => s._id);
      const saIdStrs = superAdmins.map((s) => String(s._id));
      f.actorId = { $nin: saIds };
      f.resourceId = { $nin: saIdStrs };
    }
    if (b.actorId) f.actorId = oid(b.actorId);
    if (b.resourceType) f.resourceType = b.resourceType;
    if (b.resourceId) f.resourceId = b.resourceId;
    if (b.action) f.action = new RegExp(`^${escapeRegex(b.action)}`);
    if (b.outcome) f.outcome = b.outcome;
    if (b.from || b.to) f.at = { ...(b.from ? { $gte: b.from } : {}), ...(b.to ? { $lte: b.to } : {}) };
    return f;
  }

  @Get()
  @Can('audit', 'view', 'organization')
  async list(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(auditQuery, q);
    const f = await this.filter(ctx, b);
    const [items, total] = await Promise.all([this.logs.find(f).sort({ at: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(), this.logs.countDocuments(f)]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  /** Time-travel view: every change to one record, oldest first, with changed fields. */
  @Get('records/:type/:id')
  @Can('audit', 'view', 'organization')
  async replay(@C() ctx: Ctx, @Param('type') type: string, @Param('id') id: string) {
    if (type === 'user' && !ctx.authz.isSuperAdmin) {
      const u = await this.users.findById(id, { role: 1 }).lean<any>();
      if (u?.role === 'super_admin') throw notFound('Record');
    }
    const items = await this.logs.find({ organizationId: ctx.orgOid, resourceType: type, resourceId: id }).sort({ at: 1 }).limit(1000).lean();
    return { items: serialize(items) };
  }

  @Get('export')
  @Can('audit', 'export', 'organization')
  async export(@C() ctx: Ctx, @Query() q: unknown, @Res() res: Response) {
    const b = parse(auditQuery, q);
    const f = await this.filter(ctx, b);
    const rows = await this.logs.find(f).sort({ at: -1 }).limit(50_000).lean<any[]>();
    const cell = (v: unknown) => `"${String(v ?? '').replace(/^[=+\-@]/, "'$&").replace(/"/g, '""')}"`;
    const csv = ['at,actor,action,resource_type,resource_id,outcome,correlation_id,changes', ...rows.map((r) => [new Date(r.at).toISOString(), r.actorName ?? r.actorId, r.action, r.resourceType, r.resourceId, r.outcome, r.correlationId, r.changes ? JSON.stringify(r.changes) : ''].map(cell).join(','))].join('\n');
    await this.audit.record(ctx, { action: 'audit.export', resourceType: 'audit', changes: { rows: { from: null, to: rows.length } } });
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="audit-log.csv"');
    res.setHeader('Cache-Control', 'no-store');
    res.send('﻿' + csv);
  }
}

// ---------------------------------------------------------------- security center

@ApiTags('security')
@Controller({ path: 'security', version: '1' })
export class SecurityController {
  constructor(
    private readonly audit: AuditService,
    private readonly sessions: SessionService,
    @InjectModel('LoginEvent') private readonly logins: Model<any>,
    @InjectModel('Session') private readonly sessionModel: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
    @InjectModel('PermissionChange') private readonly changes: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Device') private readonly devices: Model<any>,
  ) {}

  @Get('overview')
  @Can('security', 'view', 'organization')
  async overview(@C() ctx: Ctx) {
    const day = new Date(Date.now() - 86400_000);
    const [failed24h, locked, openAlerts, activeSessions, superAdmins] = await Promise.all([
      this.logins.countDocuments({ organizationId: ctx.orgOid, outcome: { $in: ['failure', 'locked'] }, at: { $gt: day } }),
      this.users.countDocuments({ organizationId: ctx.orgOid, lockedUntil: { $gt: new Date() } }),
      this.alerts.countDocuments({ organizationId: ctx.orgOid, status: 'open' }),
      this.sessionModel.countDocuments({ organizationId: ctx.orgOid, revokedAt: null, expiresAt: { $gt: new Date() } }),
      this.users.countDocuments({ organizationId: ctx.orgOid, role: 'super_admin', status: 'active' }),
    ]);
    return { failedLogins24h: failed24h, lockedAccounts: locked, openAlerts, activeSessions, superAdmins: ctx.authz.isSuperAdmin ? superAdmins : 0 };
  }

  @Get('logins')
  @Can('security', 'view', 'organization')
  async logins_(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.extend({ userId: objectId.optional(), outcome: z.string().optional() }), q);
    const f: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!ctx.authz.isSuperAdmin) {
      const superAdmins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin' }, { _id: 1 }).lean<any[]>();
      const superAdminIds = superAdmins.map((s) => s._id);
      if (b.userId && superAdminIds.some((id) => String(id) === String(b.userId))) {
        return { items: [], page: b.page, limit: b.limit, total: 0, hasMore: false };
      }
      f.userId = { $nin: superAdminIds };
    }
    if (b.userId) f.userId = oid(b.userId);
    if (b.outcome) f.outcome = b.outcome;
    const [items, total] = await Promise.all([this.logins.find(f).sort({ at: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(), this.logins.countDocuments(f)]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  /** Active sessions across the organization (no tokens or hashes ever leave the server). */
  @Get('sessions')
  @Can('security', 'view', 'organization')
  async allSessions(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.extend({ userId: objectId.optional() }), q);
    const f: Record<string, unknown> = { organizationId: ctx.orgOid, revokedAt: null, expiresAt: { $gt: new Date() } };
    if (!ctx.authz.isSuperAdmin) {
      const superAdmins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin' }, { _id: 1 }).lean<any[]>();
      const superAdminIds = superAdmins.map((s) => s._id);
      if (b.userId && superAdminIds.some((id) => String(id) === String(b.userId))) {
        return { items: [], page: b.page, limit: b.limit, total: 0, hasMore: false };
      }
      f.userId = { $nin: superAdminIds };
    }
    if (b.userId) f.userId = oid(b.userId);
    const [rows, total] = await Promise.all([this.sessionModel.find(f, { refreshHash: 0, family: 0 }).sort({ lastUsedAt: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean<any[]>(), this.sessionModel.countDocuments(f)]);
    const users = await this.users.find({ _id: { $in: rows.map((r) => r.userId) } }, { fullName: 1, role: 1 }).lean<any[]>();
    const u = new Map(users.map((x) => [String(x._id), x]));
    return { items: serialize(rows).map((s: any) => ({ ...s, userName: u.get(s.userId)?.fullName, role: u.get(s.userId)?.role })), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  @Post('sessions/:id/revoke')
  @Can('security', 'manage', 'organization')
  @HttpCode(200)
  async revoke(@C() ctx: Ctx, @Param('id') id: string) {
    const s = await this.sessionModel.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!s) throw notFound('Session');
    const target = await this.users.findById(s.userId, { role: 1 }).lean<any>();
    if (target?.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('Session');
    await this.sessions.revoke(id, 'admin_revoked');
    await this.audit.record(ctx, { action: 'session.admin_revoke', resourceType: 'session', resourceId: id });
    return { revoked: true };
  }

  @Post('users/:id/sign-out-everywhere')
  @Can('security', 'manage', 'organization')
  @HttpCode(200)
  async signOutUser(@C() ctx: Ctx, @Param('id') id: string) {
    const target = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }, { role: 1 }).lean<any>();
    if (!target) throw notFound('User');
    if (target.role === 'super_admin' && !ctx.authz.isSuperAdmin) throw notFound('User');
    const n = await this.sessions.revokeAll(target._id, 'admin_revoked_all');
    await this.audit.record(ctx, { action: 'session.revoke_all', resourceType: 'user', resourceId: id, changes: { sessions: { from: null, to: n } } });
    return { revoked: n };
  }

  @Post('users/:id/unlock')
  @Can('security', 'manage', 'organization')
  @HttpCode(200)
  async unlock(@C() ctx: Ctx, @Param('id') id: string) {
    const target = await this.users.findOne({ _id: oid(id), organizationId: ctx.orgOid }, { role: 1 }).lean<any>();
    if (!target || (target.role === 'super_admin' && !ctx.authz.isSuperAdmin)) throw notFound('User');
    const r = await this.users.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { lockedUntil: null, failedLogins: 0 } });
    await this.audit.record(ctx, { action: 'user.unlock', resourceType: 'user', resourceId: id });
    return { unlocked: true };
  }

  @Get('alerts')
  @Can('security', 'view', 'organization')
  async listAlerts(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery, q);
    const f: Record<string, unknown> = { organizationId: ctx.orgOid, status: b.status ?? { $in: ['open', 'acknowledged'] } };
    if (!ctx.authz.isSuperAdmin) {
      const superAdmins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin' }, { _id: 1 }).lean<any[]>();
      const saIds = superAdmins.map((s) => s._id);
      f.userId = { $nin: saIds };
      f.type = { $ne: 'new_super_admin' };
    }
    const [items, total] = await Promise.all([this.alerts.find(f).sort({ createdAt: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(), this.alerts.countDocuments(f)]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  @Post('alerts/:id/:status')
  @Can('security', 'manage', 'organization')
  @HttpCode(200)
  async alertStatus(@C() ctx: Ctx, @Param('id') id: string, @Param('status') status: string) {
    const s = parse(z.enum(['acknowledged', 'resolved']), status);
    const r = await this.alerts.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { status: s, ...(s === 'resolved' ? { resolvedBy: ctx.userOid, resolvedAt: new Date() } : {}) } });
    if (!r.matchedCount) throw notFound('Alert');
    await this.audit.record(ctx, { action: `security_alert.${s}`, resourceType: 'security_alert', resourceId: id });
    return { ok: true };
  }

  @Get('permission-changes')
  @Can('security', 'view', 'organization')
  async permissionChanges(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery, q);
    const f: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!ctx.authz.isSuperAdmin) {
      const superAdmins = await this.users.find({ organizationId: ctx.orgOid, role: 'super_admin' }, { _id: 1 }).lean<any[]>();
      const saIds = superAdmins.map((s) => s._id);
      f.actorId = { $nin: saIds };
      f.targetUserId = { $nin: saIds };
      f.roleKey = { $ne: 'super_admin' };
    }
    const [items, total] = await Promise.all([this.changes.find(f).sort({ at: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(), this.changes.countDocuments(f)]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  @Get('devices')
  @Can('security', 'view', 'organization')
  async listDevices(@C() ctx: Ctx) {
    const rows = await this.devices.find({ organizationId: ctx.orgOid }).sort({ lastSeenAt: -1 }).limit(500).lean<any[]>();
    return { items: serialize(rows).map((d: any) => ({ ...d, sharedBy: d.userIds?.length ?? 0 })) };
  }

  static readonly require = PermissionsService.require;
}
