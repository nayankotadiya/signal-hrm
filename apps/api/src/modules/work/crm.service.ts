import { Injectable } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, escapeRegex, forbidden, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from '../system/jobs.service';
import { LEAD_STATUSES } from '../../schemas/work.schemas';

export const leadInput = z.object({
  name: z.string().trim().min(2).max(120),
  company: z.string().trim().max(120).optional().nullable(),
  phone: z.string().trim().max(20).optional().nullable(),
  email: z.string().trim().toLowerCase().email().optional().nullable(),
  source: z.string().trim().max(30).default('manual'),
  campaignRef: z.string().max(120).optional().nullable(),
  ownerEmployeeId: objectId.optional().nullable(),
  status: z.enum(LEAD_STATUSES).default('new'),
  priority: z.enum(['low', 'medium', 'high']).default('medium'),
  interest: z.enum(['cold', 'warm', 'hot']).default('warm'),
  estimatedValue: z.number().min(0).max(1e12).optional().nullable(),
  nextFollowUpAt: z.coerce.date().optional().nullable(),
  notes: z.string().max(5000).optional().nullable(),
  consent: z.object({ marketing: z.boolean().optional(), whatsapp: z.boolean().optional(), call: z.boolean().optional() }).optional(),
});
export const activityInput = z.object({
  type: z.enum(['call', 'email', 'whatsapp', 'meeting', 'note', 'follow_up']),
  outcome: z.string().max(80).optional(),
  note: z.string().max(5000).optional(),
  at: z.coerce.date().optional(),
  dueAt: z.coerce.date().optional(),
});

/** Digits only, last 10 for Indian numbers, so +91 98765 43210 and 09876543210 match. */
export function normalizePhone(p?: string | null): string | undefined {
  if (!p) return undefined;
  const d = p.replace(/\D/g, '');
  return d.length >= 10 ? d.slice(-10) : d || undefined;
}

@Injectable()
export class CrmService {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly notifications: NotificationsService,
    private readonly jobs: JobsService,
    @InjectModel('Lead') private readonly leads: Model<any>,
    @InjectModel('LeadActivity') private readonly activities: Model<any>,
    @InjectModel('LeadAssignment') private readonly assignments: Model<any>,
    @InjectModel('LeadSource') private readonly sources: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  private async filter(ctx: Ctx): Promise<Record<string, unknown>> {
    return this.scope.filter(ctx, 'crm', 'view', 'ownerEmployeeId');
  }

  private async load(ctx: Ctx, id: string, action: 'view' | 'edit' = 'view'): Promise<any> {
    const l = await this.leads.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!l) throw notFound('Lead');
    const scope = PermissionsService.require(ctx, 'crm', action);
    if (scope !== 'organization' && !(l.ownerEmployeeId && (await this.scope.covers(ctx, 'crm', action, l.ownerEmployeeId)))) throw notFound('Lead');
    return l;
  }

  /** Duplicate detection on normalized phone, email and external id. */
  async findDuplicates(orgId: Types.ObjectId, b: { phone?: string | null; email?: string | null; externalId?: string; source?: string }, excludeId?: Types.ObjectId): Promise<any[]> {
    const or: Record<string, unknown>[] = [];
    const phone = normalizePhone(b.phone);
    if (phone) or.push({ phoneNormalized: phone });
    if (b.email) or.push({ email: b.email.toLowerCase() });
    if (b.externalId && b.source) or.push({ source: b.source, externalId: b.externalId });
    if (!or.length) return [];
    const filter: Record<string, unknown> = { organizationId: orgId, $or: or };
    if (excludeId) filter._id = { $ne: excludeId };
    return this.leads.find(filter, { name: 1, phone: 1, email: 1, status: 1, ownerEmployeeId: 1 }).limit(5).lean();
  }

  async list(ctx: Ctx, q: { status?: string; ownerId?: string; source?: string; q?: string; followUpDue?: boolean; page: number; limit: number; sort?: string }): Promise<Paged<any>> {
    const filter: Record<string, any> = await this.filter(ctx);
    if (q.status) filter.status = { $in: q.status.split(',') };
    if (q.ownerId) filter.ownerEmployeeId = oid(q.ownerId);
    if (q.source) filter.source = q.source;
    if (q.followUpDue) filter.nextFollowUpAt = { $lte: new Date() };
    if (q.q) {
      const rx = new RegExp(escapeRegex(q.q), 'i');
      filter.$or = [{ name: rx }, { company: rx }, { email: rx }, { phone: rx }];
    }
    const [rows, total] = await Promise.all([this.leads.find(filter).sort(q.followUpDue ? { nextFollowUpAt: 1 } : { updatedAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.leads.countDocuments(filter)]);
    return { items: await this.decorate(rows), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  private async decorate(rows: any[]): Promise<any[]> {
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.ownerEmployeeId).filter(Boolean) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const n = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    return serialize(rows).map((r: any) => ({ ...r, ownerName: n.get(r.ownerEmployeeId) ?? null }));
  }

  /** Board: counts and value per pipeline stage. */
  async pipeline(ctx: Ctx): Promise<any> {
    const filter = await this.filter(ctx);
    const rows = await this.leads.aggregate([{ $match: filter }, { $group: { _id: '$status', count: { $sum: 1 }, value: { $sum: { $ifNull: ['$estimatedValue', 0] } } } }]);
    const by = new Map(rows.map((r: any) => [r._id, r]));
    return { stages: LEAD_STATUSES.map((s) => ({ status: s, count: by.get(s)?.count ?? 0, value: by.get(s)?.value ?? 0 })) };
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const l = await this.load(ctx, id);
    const [decorated] = await this.decorate([l]);
    const acts = await this.activities.find({ leadId: l._id }).sort({ at: -1 }).limit(300).lean<any[]>();
    const users = await this.users.find({ _id: { $in: acts.map((a) => a.actorId).filter(Boolean) } }, { fullName: 1 }).lean<any[]>();
    const un = new Map(users.map((u) => [String(u._id), u.fullName]));
    const duplicates = await this.findDuplicates(ctx.orgOid, l, l._id);
    return { ...decorated, activities: serialize(acts).map((a: any) => ({ ...a, actorName: un.get(a.actorId) })), duplicates: serialize(duplicates) };
  }

  async create(ctx: Ctx, b: z.infer<typeof leadInput>, opts: { allowDuplicate?: boolean; externalId?: string } = {}): Promise<any> {
    PermissionsService.require(ctx, 'crm', 'create');
    const dups = await this.findDuplicates(ctx.orgOid, { ...b, externalId: opts.externalId, source: b.source });
    if (dups.length && !opts.allowDuplicate) {
      throw conflict('LEAD_DUPLICATE', `This looks like an existing lead: ${dups[0].name}. Open it, or create anyway.`);
    }
    const owner = b.ownerEmployeeId ?? ctx.user.employeeId;
    if (owner && owner !== ctx.user.employeeId) await this.assertCanAssign(ctx, owner);
    const lead = await this.leads.create({ ...b, organizationId: ctx.orgOid, phoneNormalized: normalizePhone(b.phone), ownerEmployeeId: owner ? oid(owner) : undefined, externalId: opts.externalId, createdBy: ctx.userOid });
    await this.activities.create({ organizationId: ctx.orgOid, leadId: lead._id, type: 'note', note: 'Lead created', actorId: ctx.userOid });
    await this.audit.record(ctx, { action: 'lead.create', resourceType: 'lead', resourceId: lead._id });
    return this.get(ctx, String(lead._id));
  }

  private async assertCanAssign(ctx: Ctx, employeeId: string): Promise<void> {
    PermissionsService.require(ctx, 'crm', 'assign');
    if (!(await this.scope.covers(ctx, 'crm', 'assign', employeeId))) throw forbidden('ASSIGN_OUT_OF_SCOPE', "You can't assign leads to that person.");
  }

  async update(ctx: Ctx, id: string, b: Partial<z.infer<typeof leadInput>> & { lostReason?: string }): Promise<any> {
    const l = await this.load(ctx, id, 'edit');
    const set: Record<string, any> = { ...b };
    if ('phone' in b) set.phoneNormalized = normalizePhone(b.phone);
    if (b.ownerEmployeeId !== undefined && String(b.ownerEmployeeId) !== String(l.ownerEmployeeId)) {
      if (b.ownerEmployeeId) await this.assertCanAssign(ctx, b.ownerEmployeeId);
      set.ownerEmployeeId = b.ownerEmployeeId ? oid(b.ownerEmployeeId) : null;
      await this.assignments.create({ organizationId: ctx.orgOid, leadId: l._id, fromEmployeeId: l.ownerEmployeeId, toEmployeeId: set.ownerEmployeeId, byUserId: ctx.userOid });
      await this.activities.create({ organizationId: ctx.orgOid, leadId: l._id, type: 'assignment', actorId: ctx.userOid, data: { to: b.ownerEmployeeId } });
      if (b.ownerEmployeeId) {
        const u = await this.users.findOne({ organizationId: ctx.orgOid, employeeId: oid(b.ownerEmployeeId) }, { _id: 1 }).lean<any>();
        if (u) await this.notifications.notify(ctx.orgOid, [u._id], { event: 'lead_assigned', title: `Lead assigned: ${l.name}`, link: `/work/crm/${id}` });
      }
    }
    if (b.status && b.status !== l.status) {
      if (b.status === 'lost' && !b.lostReason && !l.lostReason) throw badRequest('LOST_REASON_REQUIRED', 'Add why the lead was lost.', 'lostReason');
      if (b.status === 'won') set.wonAt = new Date();
      await this.activities.create({ organizationId: ctx.orgOid, leadId: l._id, type: 'status_change', actorId: ctx.userOid, data: { from: l.status, to: b.status } });
    }
    if (b.consent) set.consent = { ...b.consent, recordedAt: new Date() };
    await this.leads.updateOne({ _id: l._id }, { $set: set });
    await this.audit.record(ctx, { action: 'lead.update', resourceType: 'lead', resourceId: id, changes: diff(l, set) });
    return this.get(ctx, id);
  }

  async addActivity(ctx: Ctx, id: string, b: z.infer<typeof activityInput>): Promise<any> {
    const l = await this.load(ctx, id, 'edit');
    const at = b.at ?? new Date();
    const a = await this.activities.create({ organizationId: ctx.orgOid, leadId: l._id, ...b, at, actorId: ctx.userOid, done: b.type === 'follow_up' ? false : undefined });
    const set: Record<string, unknown> = {};
    if (['call', 'email', 'whatsapp', 'meeting'].includes(b.type)) {
      set.lastContactedAt = at;
      if (!l.firstResponseAt) set.firstResponseAt = at;
      if (l.status === 'new') set.status = 'contacted';
    }
    if (b.type === 'follow_up' && b.dueAt) set.nextFollowUpAt = b.dueAt;
    if (Object.keys(set).length) await this.leads.updateOne({ _id: l._id }, { $set: set });
    return serialize(a.toObject());
  }

  async completeFollowUp(ctx: Ctx, leadId: string, activityId: string): Promise<any> {
    const l = await this.load(ctx, leadId, 'edit');
    await this.activities.updateOne({ _id: oid(activityId), leadId: l._id, type: 'follow_up' }, { $set: { done: true } });
    const next = await this.activities.findOne({ leadId: l._id, type: 'follow_up', done: false }).sort({ dueAt: 1 }).lean<any>();
    await this.leads.updateOne({ _id: l._id }, { $set: { nextFollowUpAt: next?.dueAt ?? null } });
    return this.get(ctx, leadId);
  }

  /** Follow-ups due within a day, for the dark action card. */
  async followUpsDue(ctx: Ctx): Promise<any[]> {
    const filter: Record<string, any> = await this.filter(ctx);
    filter.nextFollowUpAt = { $lte: new Date(Date.now() + 86400_000) };
    filter.status = { $nin: ['won', 'lost'] };
    return this.decorate(await this.leads.find(filter).sort({ nextFollowUpAt: 1 }).limit(50).lean<any[]>());
  }

  async listSources(ctx: Ctx): Promise<any[]> {
    return serialize(await this.sources.find({ organizationId: ctx.orgOid }).sort({ name: 1 }).lean());
  }

  async saveSource(ctx: Ctx, key: string, name: string, active: boolean): Promise<any> {
    PermissionsService.require(ctx, 'crm', 'configure', 'organization');
    return serialize(await this.sources.findOneAndUpdate({ organizationId: ctx.orgOid, key }, { $set: { name, active } }, { upsert: true, new: true }).lean());
  }

  /** Imports from an authorized integration (e.g. Meta lead ads); skips duplicates. */
  async importLead(orgId: Types.ObjectId, b: z.infer<typeof leadInput> & { externalId: string }, defaultOwner?: Types.ObjectId): Promise<'created' | 'duplicate'> {
    const dups = await this.findDuplicates(orgId, { ...b, source: b.source });
    if (dups.length) {
      await this.activities.create({ organizationId: orgId, leadId: dups[0]._id, type: 'note', note: `Duplicate inquiry from ${b.source}${b.campaignRef ? ` (${b.campaignRef})` : ''}` });
      return 'duplicate';
    }
    const lead = await this.leads.create({ ...b, organizationId: orgId, phoneNormalized: normalizePhone(b.phone), ownerEmployeeId: defaultOwner });
    await this.activities.create({ organizationId: orgId, leadId: lead._id, type: 'note', note: `Imported from ${b.source}` });
    if (defaultOwner) {
      const u = await this.users.findOne({ organizationId: orgId, employeeId: defaultOwner }, { _id: 1 }).lean<any>();
      if (u) await this.notifications.notify(orgId, [u._id], { event: 'lead_assigned', title: `New lead: ${b.name}`, body: b.campaignRef ?? undefined, link: `/work/crm/${lead._id}` });
    }
    return 'created';
  }

  @Cron('*/30 * * * *')
  async followUpReminders(): Promise<void> {
    await this.jobs.run('crm.follow_ups', async () => {
      const now = new Date();
      const due = await this.activities.find({ type: 'follow_up', done: false, dueAt: { $lte: now, $gt: new Date(now.getTime() - 30 * 60_000) } }).limit(500).lean<any[]>();
      for (const a of due) {
        const l = await this.leads.findById(a.leadId, { name: 1, ownerEmployeeId: 1, organizationId: 1 }).lean<any>();
        const u = l?.ownerEmployeeId ? await this.users.findOne({ organizationId: l.organizationId, employeeId: l.ownerEmployeeId }, { _id: 1 }).lean<any>() : null;
        if (u) await this.notifications.notify(l.organizationId, [u._id], { event: 'follow_up_due', title: `Follow up: ${l.name}`, body: a.note?.slice(0, 120), link: `/work/crm/${l._id}` });
      }
      return `${due.length} reminders`;
    });
  }
}
