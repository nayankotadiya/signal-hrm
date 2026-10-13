import { Injectable, OnModuleInit } from '@nestjs/common';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { randomToken } from '../../common/crypto/crypto';
import { badRequest, conflict, dayString, forbidden, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';

export const travelInput = z.object({
  destination: z.string().trim().min(2).max(120),
  purpose: z.string().trim().min(5).max(1000),
  departureDate: dayString,
  returnDate: dayString,
  transport: z.object({ mode: z.enum(['flight', 'train', 'bus', 'car', 'other']).optional(), details: z.string().max(500).optional() }).default({}),
  accommodation: z.object({ details: z.string().max(500).optional(), nights: z.number().int().min(0).max(90).optional() }).default({}),
  estimatedCost: z.number().min(0).max(1e9).default(0),
  currency: z.string().length(3).default('INR'),
  attachmentFileIds: z.array(objectId).max(10).default([]),
});

export const meetingInput = z.object({
  title: z.string().trim().min(2).max(160),
  participantUserIds: z.array(objectId).max(50).default([]),
  externalParticipants: z.array(z.object({ name: z.string().max(80), email: z.string().email() })).max(20).default([]),
  startAt: z.coerce.date(),
  endAt: z.coerce.date(),
  timezone: z.string().max(60).optional(),
  meetingType: z.enum(['video', 'audio', 'in_person', 'external_link']).default('video'),
  meetingUrl: z.string().url().max(500).optional().nullable(),
  relatedTaskId: objectId.optional().nullable(),
  relatedLeadId: objectId.optional().nullable(),
  notes: z.string().max(5000).optional(),
  recordingEnabled: z.boolean().default(false),
});

@Injectable()
export class TravelService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly approvals: ApprovalEngine,
    private readonly files: FilesService,
    private readonly notifications: NotificationsService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('TravelRequest') private readonly travel: Model<any>,
    @InjectModel('Expense') private readonly expenses: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('travel', {
      onApproved: async (a) => {
        await this.travel.updateOne({ _id: a.requestId, status: 'pending' }, { $set: { status: 'approved' } });
        await this.notifyOwner(a.requestId, 'Travel approved');
      },
      onRejected: async (a, _c, comment) => {
        await this.travel.updateOne({ _id: a.requestId, status: 'pending' }, { $set: { status: 'rejected' } });
        await this.notifyOwner(a.requestId, 'Travel not approved', comment);
      },
      onCancelled: async (a) => void (await this.travel.updateOne({ _id: a.requestId }, { $set: { status: 'cancelled' } })),
    });
    this.files.registerAuthorizer('travel', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || this.scope.covers(ctx, 'travel', 'view', f.ownerEmployeeId));
  }

  private async notifyOwner(id: any, title: string, body?: string): Promise<void> {
    const t = await this.travel.findById(id).lean<any>();
    const u = t ? await this.users.findOne({ organizationId: t.organizationId, employeeId: t.employeeId }, { _id: 1 }).lean<any>() : null;
    if (u) await this.notifications.notify(t.organizationId, [u._id], { event: 'travel_decided', title: `${title}: ${t.destination}`, body, link: '/work/travel' });
  }

  async create(ctx: Ctx, b: z.infer<typeof travelInput>): Promise<any> {
    PermissionsService.require(ctx, 'travel', 'create');
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    if (b.returnDate < b.departureDate) throw badRequest('DATES_INVALID', 'The return date is before departure.', 'returnDate');
    const org = await this.orgSettings.get(ctx.orgOid);
    if (b.departureDate < localParts(new Date(), org.timezone).day) throw badRequest('PAST_DATE', 'Departure must be today or later.', 'departureDate');
    const files = [];
    for (const f of b.attachmentFileIds) files.push(await this.files.requireOwnUpload(ctx, f, 'attachment'));
    const t = await this.travel.create({ ...b, attachmentFileIds: files.map((f) => f._id), organizationId: ctx.orgOid, employeeId: ctx.employeeOid, status: 'pending' });
    for (const f of files) await this.files.link(f._id, { type: 'travel', id: t._id });
    const a = await this.approvals.start(ctx, {
      requestType: 'travel',
      requestId: t._id,
      subjectEmployeeId: ctx.employeeOid,
      title: `Travel to ${b.destination}: ${ctx.user.name}`,
      summary: `${b.departureDate} to ${b.returnDate} · est. ${b.currency} ${b.estimatedCost} · ${b.purpose.slice(0, 100)}`,
      amount: b.estimatedCost,
      link: '/work/travel',
    });
    await this.travel.updateOne({ _id: t._id }, { $set: { approvalId: a._id } });
    await this.audit.record(ctx, { action: 'travel.request', resourceType: 'travel_request', resourceId: t._id });
    return serialize(await this.travel.findById(t._id).lean());
  }

  async list(ctx: Ctx, q: { mine?: boolean; status?: string; from?: string; to?: string; page: number; limit: number }): Promise<Paged<any>> {
    const filter: Record<string, any> = q.mine ? { organizationId: ctx.orgOid, employeeId: ctx.employeeOid ?? null } : await this.scope.filter(ctx, 'travel', 'view');
    if (q.status) filter.status = q.status;
    if (q.from) filter.returnDate = { $gte: q.from };
    if (q.to) filter.departureDate = { $lte: q.to };
    const [rows, total] = await Promise.all([this.travel.find(filter).sort({ departureDate: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.travel.countDocuments(filter)]);
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const n = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    return { items: serialize(rows).map((r: any) => ({ ...r, employeeName: n.get(r.employeeId) })), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const t = await this.travel.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t || !(String(t.employeeId) === ctx.user.employeeId || (await this.scope.covers(ctx, 'travel', 'view', t.employeeId)))) throw notFound('Travel request');
    const exp = await this.expenses.find({ organizationId: ctx.orgOid, travelRequestId: t._id, status: { $ne: 'cancelled' } }).lean<any[]>();
    return { ...serialize(t), expenses: serialize(exp), expenseTotal: exp.filter((e) => e.status !== 'rejected').reduce((a, e) => a + e.amount, 0) };
  }

  async book(ctx: Ctx, id: string, b: { reference: string; details?: string }): Promise<any> {
    PermissionsService.require(ctx, 'travel', 'manage');
    const t = await this.travel.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid, status: 'approved' }, { $set: { status: 'booked', booking: { ...b, bookedBy: ctx.userOid, bookedAt: new Date() } } }, { new: true }).lean();
    if (!t) throw conflict('TRAVEL_NOT_APPROVED', 'Only approved travel can be booked.');
    await this.audit.record(ctx, { action: 'travel.book', resourceType: 'travel_request', resourceId: id });
    return serialize(t);
  }

  /** After the trip: the employee marks it complete; expenses linked to it form the settlement. */
  async complete(ctx: Ctx, id: string): Promise<any> {
    const t = await this.travel.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t) throw notFound('Travel request');
    if (String(t.employeeId) !== ctx.user.employeeId && !ctx.authz.can('travel', 'manage')) throw forbidden('FORBIDDEN', 'Only the traveller can complete the trip.');
    if (!['approved', 'booked'].includes(t.status)) throw conflict('TRAVEL_NOT_ACTIVE', 'This trip is not active.');
    await this.travel.updateOne({ _id: t._id }, { $set: { status: 'completed', settlementStatus: 'pending' } });
    return this.get(ctx, id);
  }

  async settle(ctx: Ctx, id: string, note?: string): Promise<any> {
    PermissionsService.require(ctx, 'travel', 'manage');
    const t = await this.travel.findOne({ _id: oid(id), organizationId: ctx.orgOid, status: 'completed' }).lean<any>();
    if (!t) throw conflict('TRAVEL_NOT_COMPLETED', 'Complete the trip before settling it.');
    const pending = await this.expenses.countDocuments({ organizationId: ctx.orgOid, travelRequestId: t._id, status: { $in: ['draft', 'submitted'] } });
    if (pending) throw conflict('EXPENSES_PENDING', `${pending} expense(s) for this trip still need a decision.`);
    const exp = await this.expenses.find({ organizationId: ctx.orgOid, travelRequestId: t._id, status: 'approved' }).lean<any[]>();
    const actual = exp.reduce((a, e) => a + e.amount, 0);
    await this.travel.updateOne({ _id: t._id }, { $set: { status: 'settled', settlementStatus: 'settled', settledAt: new Date(), actualCost: actual, settlementNote: note } });
    await this.audit.record(ctx, { action: 'travel.settle', resourceType: 'travel_request', resourceId: id, changes: { actualCost: { from: null, to: actual } } });
    return this.get(ctx, id);
  }

  async cancel(ctx: Ctx, id: string): Promise<any> {
    const t = await this.travel.findOne({ _id: oid(id), organizationId: ctx.orgOid, employeeId: ctx.employeeOid }).lean<any>();
    if (!t) throw notFound('Travel request');
    if (t.status === 'pending') await this.approvals.cancel(ctx, 'travel', t._id);
    else if (['approved', 'booked'].includes(t.status)) await this.travel.updateOne({ _id: t._id }, { $set: { status: 'cancelled' } });
    else throw conflict('TRAVEL_CLOSED', `This trip is already ${t.status}.`);
    return this.get(ctx, id);
  }
}

@Injectable()
export class MeetingsService {
  constructor(
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('Meeting') private readonly meetings: Model<any>,
    @InjectModel('CallLog') private readonly calls: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  private visible(ctx: Ctx): Record<string, unknown> {
    return { organizationId: ctx.orgOid, $or: [{ organizerId: ctx.userOid }, { participantUserIds: ctx.userOid }] };
  }

  async list(ctx: Ctx, from: Date, to: Date): Promise<any[]> {
    const rows = await this.meetings.find({ ...this.visible(ctx), startAt: { $lte: to }, endAt: { $gte: from }, status: { $ne: 'cancelled' } }).sort({ startAt: 1 }).limit(300).lean<any[]>();
    const ids = [...new Set(rows.flatMap((m) => [String(m.organizerId), ...(m.participantUserIds ?? []).map(String)]))];
    const users = await this.users.find({ _id: { $in: ids.map(oid) } }, { fullName: 1, photoFileId: 1 }).lean<any[]>();
    const u = new Map(users.map((x) => [String(x._id), { id: String(x._id), name: x.fullName, photoFileId: x.photoFileId ? String(x.photoFileId) : null }]));
    // Notes are visible to participants only; that's already the filter.
    return serialize(rows).map((m: any) => ({ ...m, organizer: u.get(m.organizerId), participants: (m.participantUserIds ?? []).map((p: string) => u.get(p)).filter(Boolean) }));
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const m = await this.meetings.findOne({ _id: oid(id), ...this.visible(ctx) }).lean<any>();
    if (!m) throw notFound('Meeting');
    const history = await this.calls.find({ meetingId: m._id }).sort({ joinedAt: -1 }).limit(100).lean();
    return { ...serialize(m), callHistory: serialize(history) };
  }

  async create(ctx: Ctx, b: z.infer<typeof meetingInput>): Promise<any> {
    PermissionsService.require(ctx, 'meetings', 'create');
    if (b.endAt <= b.startAt) throw badRequest('DATES_INVALID', 'The meeting must end after it starts.', 'endAt');
    if (b.endAt.getTime() - b.startAt.getTime() > 12 * 3600_000) throw badRequest('TOO_LONG', 'Meetings can be at most 12 hours.', 'endAt');
    if (b.meetingType === 'external_link' && !b.meetingUrl) throw badRequest('URL_REQUIRED', 'Add the meeting link.', 'meetingUrl');
    const participants = await this.users.find({ _id: { $in: b.participantUserIds.map(oid) }, organizationId: ctx.orgOid, status: 'active' }, { _id: 1 }).lean<any[]>();
    if (participants.length !== b.participantUserIds.length) throw badRequest('PARTICIPANT_INVALID', 'Some participants are not active users.', 'participantUserIds');
    const org = await this.orgSettings.get(ctx.orgOid);
    const m = await this.meetings.create({
      ...b,
      organizationId: ctx.orgOid,
      organizerId: ctx.userOid,
      participantUserIds: participants.map((p) => p._id),
      timezone: b.timezone ?? org.timezone,
      roomId: ['video', 'audio'].includes(b.meetingType) ? randomToken(12) : undefined,
      relatedTaskId: b.relatedTaskId ? oid(b.relatedTaskId) : undefined,
      relatedLeadId: b.relatedLeadId ? oid(b.relatedLeadId) : undefined,
      // Recording: only when enabled and disclosed to every participant up front.
      recording: b.recordingEnabled ? { enabled: true, disclosedAt: new Date() } : { enabled: false },
    });
    await this.notifications.notify(ctx.orgOid, participants.map((p) => p._id), {
      event: 'meeting_scheduled',
      title: `${ctx.user.name} invited you: ${b.title}`,
      body: `${b.startAt.toISOString()}${b.recordingEnabled ? ' · This meeting will be recorded.' : ''}`,
      link: `/work/meetings/${m._id}`,
    });
    await this.audit.record(ctx, { action: 'meeting.create', resourceType: 'meeting', resourceId: m._id });
    return this.get(ctx, String(m._id));
  }

  async update(ctx: Ctx, id: string, b: Partial<z.infer<typeof meetingInput>> & { status?: 'cancelled' | 'ended' }): Promise<any> {
    const m = await this.meetings.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!m) throw notFound('Meeting');
    const isOrganizer = String(m.organizerId) === ctx.user.userId;
    // Participants may add notes; only the organizer changes the meeting itself.
    const keys = Object.keys(b);
    if (!isOrganizer && !(keys.length === 1 && keys[0] === 'notes' && (m.participantUserIds ?? []).some((p: any) => String(p) === ctx.user.userId))) throw forbidden('ORGANIZER_ONLY', 'Only the organizer can change this meeting.');
    const set: Record<string, unknown> = { ...b };
    delete set.recordingEnabled;
    if (b.participantUserIds) set.participantUserIds = b.participantUserIds.map(oid);
    if (b.status === 'ended') set.endedAt = new Date();
    if (b.recordingEnabled !== undefined && b.recordingEnabled !== !!m.recording?.enabled) set.recording = b.recordingEnabled ? { enabled: true, disclosedAt: new Date() } : { enabled: false };
    await this.meetings.updateOne({ _id: m._id }, { $set: set });
    if (b.status === 'cancelled') await this.notifications.notify(ctx.orgOid, m.participantUserIds ?? [], { event: 'meeting_scheduled', title: `Cancelled: ${m.title}`, link: `/work/meetings/${id}` });
    return this.get(ctx, id);
  }

  /** Call history: join/leave and failures (permission denied, network lost) reported by the client. */
  async logCall(ctx: Ctx, id: string, b: { event: 'joined' | 'left'; outcome?: 'completed' | 'failed' | 'permission_denied' | 'network_lost' }): Promise<{ ok: true }> {
    const m = await this.meetings.findOne({ _id: oid(id), ...this.visible(ctx) }).lean<any>();
    if (!m) throw notFound('Meeting');
    if (b.event === 'joined') await this.calls.create({ organizationId: ctx.orgOid, meetingId: m._id, roomId: m.roomId, userId: ctx.userOid, joinedAt: new Date() });
    else await this.calls.findOneAndUpdate({ meetingId: m._id, userId: ctx.userOid, leftAt: null }, { $set: { leftAt: new Date(), outcome: b.outcome ?? 'completed' } }, { sort: { joinedAt: -1 } });
    return { ok: true };
  }

  static readonly conflict = conflict;
}
