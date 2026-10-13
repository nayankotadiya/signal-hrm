import { HttpStatus, Injectable, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { randomToken } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { badRequest, conflict, dayString, forbidden, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { addDays, daysBetween, localParts, OrgSettingsService, weekdayOf } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from '../system/jobs.service';
import { AttendanceService } from './attendance.service';

export const applyInput = z.object({
  leaveTypeId: objectId,
  startDate: dayString,
  endDate: dayString,
  partialDay: z.enum(['none', 'first_half', 'second_half']).default('none'),
  reason: z.string().trim().max(1000).optional(),
  attachmentFileId: objectId.optional(),
});

export const leaveTypeInput = z.object({
  code: z.string().trim().min(1).max(6).regex(/^[A-Za-z]+$/),
  name: z.string().trim().min(2).max(60),
  paid: z.boolean().default(true),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(),
  allowHalfDay: z.boolean().default(true),
  requiresAttachmentAfterDays: z.number().int().min(1).max(60).optional().nullable(),
  active: z.boolean().default(true),
});

export const policyInput = z.object({
  name: z.string().trim().min(2).max(80),
  leaveTypeId: objectId,
  annualQuota: z.number().min(0).max(365),
  accrual: z.enum(['upfront', 'monthly']).default('upfront'),
  carryForwardMax: z.number().min(0).max(365).default(0),
  maxConsecutiveDays: z.number().int().min(1).max(365).optional().nullable(),
  minNoticeDays: z.number().int().min(0).max(90).default(0),
  allowNegative: z.boolean().default(false),
  requireHrApproval: z.boolean().default(false),
  appliesTo: z.object({ employmentTypes: z.array(z.string()).optional(), departmentIds: z.array(objectId).optional(), locationIds: z.array(objectId).optional(), afterProbationOnly: z.boolean().optional() }).default({}),
  active: z.boolean().default(true),
});

const round = (n: number): number => Math.round(n * 2) / 2;

@Injectable()
export class LeaveService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly orgSettings: OrgSettingsService,
    private readonly approvals: ApprovalEngine,
    private readonly notifications: NotificationsService,
    private readonly attendance: AttendanceService,
    private readonly files: FilesService,
    private readonly jobs: JobsService,
    @InjectModel('LeaveType') private readonly types: Model<any>,
    @InjectModel('LeavePolicy') private readonly policies: Model<any>,
    @InjectModel('LeaveBalance') private readonly balances: Model<any>,
    @InjectModel('LeaveLedger') private readonly ledger: Model<any>,
    @InjectModel('LeaveRequest') private readonly requests: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('leave', {
      onApproved: async (a) => this.onApproved(a.requestId, a.organizationId),
      onRejected: async (a, _actor, comment) => this.release(a.requestId, 'rejected', comment),
      onCancelled: async (a) => this.release(a.requestId, 'cancelled'),
      onClarification: async (a, _actor, comment) => void (await this.requests.updateOne({ _id: a.requestId, status: 'pending' }, { $set: { status: 'clarification', decisionComment: comment } })),
    });
    this.files.registerAuthorizer('leave_request', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || this.scope.covers(ctx, 'leave', 'view', f.ownerEmployeeId));
  }

  // ------------------------------------------------------------------ policy resolution

  async policyFor(orgId: Types.ObjectId, emp: any, leaveTypeId: Types.ObjectId): Promise<any | null> {
    const list = await this.policies.find({ organizationId: orgId, leaveTypeId, active: true }).lean<any[]>();
    const fits = (p: any) => {
      const a = p.appliesTo ?? {};
      if (a.employmentTypes?.length && !a.employmentTypes.includes(emp.employmentType)) return false;
      if (a.departmentIds?.length && !a.departmentIds.map(String).includes(String(emp.departmentId))) return false;
      if (a.locationIds?.length && !a.locationIds.map(String).includes(String(emp.locationId))) return false;
      if (a.afterProbationOnly && ['onboarding', 'probation'].includes(emp.status)) return false;
      return true;
    };
    // Most specific policy first.
    const score = (p: any) => (p.appliesTo?.departmentIds?.length ? 4 : 0) + (p.appliesTo?.locationIds?.length ? 2 : 0) + (p.appliesTo?.employmentTypes?.length ? 1 : 0);
    return list.filter(fits).sort((a, b) => score(b) - score(a))[0] ?? null;
  }

  /** Entitlement for the year, prorated by joining date for upfront policies. */
  private entitlement(policy: any, emp: any, year: number): number {
    const quota = policy?.annualQuota ?? 0;
    const joined = emp.joiningDate ? new Date(emp.joiningDate) : null;
    if (joined && joined.getUTCFullYear() === year) {
      const monthsLeft = 12 - joined.getUTCMonth() - (joined.getUTCDate() > 15 ? 1 : 0);
      return round((quota * Math.max(0, monthsLeft)) / 12);
    }
    if (joined && joined.getUTCFullYear() > year) return 0;
    return quota;
  }

  /** Accrued so far this year for monthly policies (what can be used today). */
  private accrued(policy: any, entitled: number, year: number, today: string): number {
    if (policy?.accrual !== 'monthly') return entitled;
    const [y, m] = today.split('-').map(Number);
    const months = y > year ? 12 : y < year ? 0 : m;
    return round((entitled * months) / 12);
  }

  async ensureBalance(orgId: Types.ObjectId, emp: any, leaveTypeId: Types.ObjectId, year: number): Promise<any> {
    const existing = await this.balances.findOne({ organizationId: orgId, employeeId: emp._id, leaveTypeId, year }).lean<any>();
    if (existing) return existing;
    const policy = await this.policyFor(orgId, emp, leaveTypeId);
    try {
      return (await this.balances.create({ organizationId: orgId, employeeId: emp._id, leaveTypeId, year, entitled: this.entitlement(policy, emp, year) })).toObject();
    } catch (e: any) {
      if (e?.code === 11000) return this.balances.findOne({ organizationId: orgId, employeeId: emp._id, leaveTypeId, year }).lean();
      throw e;
    }
  }

  /**
   * Applies one balance movement exactly once. The ledger's unique movementKey is the guard:
   * a retried approval tries the same key, the insert fails, and the balance is untouched.
   */
  private async move(orgId: Types.ObjectId, employeeId: Types.ObjectId, leaveTypeId: Types.ObjectId, year: number, field: 'used' | 'pending' | 'adjusted' | 'carriedForward', delta: number, movementKey: string, extra: Record<string, unknown> = {}): Promise<boolean> {
    if (!delta) return false;
    try {
      await this.ledger.create({ organizationId: orgId, employeeId, leaveTypeId, year, field, delta, movementKey, ...extra });
    } catch (e: any) {
      if (e?.code === 11000) return false; // already applied
      throw e;
    }
    await this.balances.updateOne({ organizationId: orgId, employeeId, leaveTypeId, year }, { $inc: { [field]: delta } });
    return true;
  }

  // ------------------------------------------------------------------ balances

  async balancesFor(ctx: Ctx, employeeId: string, year?: number): Promise<any[]> {
    if (!(await this.scope.covers(ctx, 'leave', 'view', employeeId))) throw notFound('Employee');
    const emp = await this.employees.findOne({ _id: oid(employeeId), organizationId: ctx.orgOid }).lean<any>();
    if (!emp) throw notFound('Employee');
    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    const y = year ?? Number(today.slice(0, 4));
    const types = await this.types.find({ organizationId: ctx.orgOid, active: true }).sort({ code: 1 }).lean<any[]>();
    const out = [];
    for (const t of types) {
      const policy = await this.policyFor(ctx.orgOid, emp, t._id);
      if (!policy) continue;
      const b = await this.ensureBalance(ctx.orgOid, emp, t._id, y);
      const accrued = this.accrued(policy, b.entitled, y, today);
      const available = round(accrued + b.carriedForward + b.adjusted - b.used - b.pending);
      out.push({ leaveTypeId: String(t._id), code: t.code, name: t.name, color: t.color, paid: t.paid, year: y, entitled: b.entitled, accrued, carriedForward: b.carriedForward, adjusted: b.adjusted, used: b.used, pending: b.pending, available, allowNegative: policy.allowNegative, allowHalfDay: t.allowHalfDay });
    }
    return out;
  }

  async adjust(ctx: Ctx, b: { employeeId: string; leaveTypeId: string; year: number; delta: number; reason: string }): Promise<any> {
    PermissionsService.require(ctx, 'leave', 'manage');
    await this.scope.requireCovers(ctx, 'leave', 'manage', b.employeeId);
    const emp = await this.employees.findOne({ _id: oid(b.employeeId), organizationId: ctx.orgOid }).lean<any>();
    if (!emp) throw notFound('Employee');
    await this.ensureBalance(ctx.orgOid, emp, oid(b.leaveTypeId), b.year);
    await this.move(ctx.orgOid, emp._id, oid(b.leaveTypeId), b.year, 'adjusted', b.delta, `adj:${ctx.idempotencyKey ?? randomToken(8)}`, { byUserId: ctx.userOid, note: b.reason });
    await this.audit.record(ctx, { action: 'leave.balance_adjust', resourceType: 'employee', resourceId: b.employeeId, changes: { adjusted: { from: null, to: b.delta }, reason: { from: null, to: b.reason } } });
    return this.balancesFor(ctx, b.employeeId, b.year);
  }

  // ------------------------------------------------------------------ apply

  /** Working days in a range: skips weekly offs and holidays unless the organization counts them. */
  async countUnits(orgId: Types.ObjectId, emp: any, start: string, end: string, partialDay: string): Promise<{ units: number; days: string[] }> {
    const org = await this.orgSettings.get(orgId);
    const s = org.settings?.leave ?? {};
    const hols = await this.holidays.find({ organizationId: orgId, date: { $gte: start, $lte: end }, optional: { $ne: true }, $or: [{ locationIds: { $size: 0 } }, { locationIds: emp.locationId }] }, { date: 1 }).lean<any[]>();
    const holidaySet = new Set(hols.map((h) => h.date));
    const working = org.workingDays ?? [1, 2, 3, 4, 5, 6];
    const days = daysBetween(start, end).filter((d) => (s.countWeekends || working.includes(weekdayOf(d))) && (s.countHolidays || !holidaySet.has(d)));
    let units = days.length;
    if (partialDay !== 'none') units = days.length ? 0.5 : 0;
    return { units, days };
  }

  async apply(ctx: Ctx, input: z.infer<typeof applyInput>, forEmployeeId?: string): Promise<any> {
    PermissionsService.require(ctx, 'leave', 'create');
    const employeeId = forEmployeeId ?? ctx.user.employeeId;
    if (!employeeId) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    if (forEmployeeId && forEmployeeId !== ctx.user.employeeId) PermissionsService.require(ctx, 'leave', 'manage');
    const emp = await this.employees.findOne({ _id: oid(employeeId), organizationId: ctx.orgOid }).lean<any>();
    if (!emp || ['exited', 'archived'].includes(emp.status)) throw notFound('Employee');

    if (input.endDate < input.startDate) throw badRequest('DATES_INVALID', 'The end date is before the start date.', 'endDate');
    if (input.partialDay !== 'none' && input.startDate !== input.endDate) throw badRequest('HALF_DAY_RANGE', 'A half day must be a single date.', 'partialDay');
    const type = await this.types.findOne({ _id: oid(input.leaveTypeId), organizationId: ctx.orgOid, active: true }).lean<any>();
    if (!type) throw badRequest('LEAVE_TYPE_INVALID', 'Choose a leave type.', 'leaveTypeId');
    if (input.partialDay !== 'none' && !type.allowHalfDay) throw badRequest('HALF_DAY_NOT_ALLOWED', `${type.name} can't be taken as a half day.`, 'partialDay');
    const policy = await this.policyFor(ctx.orgOid, emp, type._id);
    if (!policy) throw badRequest('NO_POLICY', `${type.name} isn't available to you.`, 'leaveTypeId');

    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    if (input.startDate < addDays(today, -30)) throw badRequest('TOO_OLD', 'Leave can be recorded up to 30 days back.', 'startDate');
    if (input.startDate.slice(0, 4) !== input.endDate.slice(0, 4)) throw badRequest('CROSSES_YEAR', 'Split leave that crosses the new year into two requests.', 'endDate');
    if (policy.minNoticeDays && input.startDate >= today && daysBetween(today, input.startDate).length - 1 < policy.minNoticeDays) {
      throw badRequest('NOTICE_TOO_SHORT', `${type.name} needs ${policy.minNoticeDays} days' notice.`, 'startDate');
    }
    const { units, days } = await this.countUnits(ctx.orgOid, emp, input.startDate, input.endDate, input.partialDay);
    if (!units) throw badRequest('NO_WORKING_DAYS', 'These dates are all holidays or weekly offs.', 'startDate');
    if (policy.maxConsecutiveDays && units > policy.maxConsecutiveDays) throw badRequest('TOO_MANY_DAYS', `${type.name} allows at most ${policy.maxConsecutiveDays} days at a time.`, 'endDate');
    if (type.requiresAttachmentAfterDays && units > type.requiresAttachmentAfterDays && !input.attachmentFileId) {
      throw badRequest('ATTACHMENT_REQUIRED', `Attach a document for ${type.name} longer than ${type.requiresAttachmentAfterDays} days.`, 'attachmentFileId');
    }

    const overlap = await this.requests.findOne({ organizationId: ctx.orgOid, employeeId: emp._id, status: { $in: ['pending', 'approved', 'clarification'] }, startDate: { $lte: input.endDate }, endDate: { $gte: input.startDate } }).lean<any>();
    if (overlap) {
      const halfOk = overlap.startDate === overlap.endDate && input.startDate === input.endDate && overlap.partialDay !== 'none' && input.partialDay !== 'none' && overlap.partialDay !== input.partialDay;
      if (!halfOk) throw new ApiError(HttpStatus.CONFLICT, 'LEAVE_OVERLAP', `These dates overlap a ${overlap.status} request (${overlap.startDate} to ${overlap.endDate}).`, [{ field: 'startDate', message: 'Overlaps another request' }]);
    }

    const year = Number(input.startDate.slice(0, 4));
    const bal = await this.ensureBalance(ctx.orgOid, emp, type._id, year);
    const available = round(this.accrued(policy, bal.entitled, year, today) + bal.carriedForward + bal.adjusted - bal.used - bal.pending);
    const allowNegative = policy.allowNegative || org.settings?.leave?.allowNegative;
    if (!allowNegative && units > available) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'INSUFFICIENT_BALANCE', `You have ${available} day(s) of ${type.name} available; this request needs ${units}.`, [{ field: 'endDate', message: `${available} available` }], { available, requested: units });
    }

    let attachment: any;
    if (input.attachmentFileId) attachment = await this.files.requireOwnUpload(ctx, input.attachmentFileId, 'document');
    const req = await this.requests.create({ organizationId: ctx.orgOid, employeeId: emp._id, leaveTypeId: type._id, startDate: input.startDate, endDate: input.endDate, partialDay: input.partialDay, units, reason: input.reason, attachmentFileId: attachment?._id, status: 'pending' });
    if (attachment) await this.files.link(attachment._id, { type: 'leave_request', id: req._id });
    await this.move(ctx.orgOid, emp._id, type._id, year, 'pending', units, `req:${req._id}:reserve`, { requestId: req._id, byUserId: ctx.userOid });

    try {
      const approval = await this.approvals.start(ctx, {
        requestType: 'leave',
        requestId: req._id,
        subjectEmployeeId: emp._id,
        title: `${type.name}: ${emp.firstName} ${emp.lastName ?? ''}`.trim(),
        summary: `${input.startDate}${input.endDate !== input.startDate ? ` to ${input.endDate}` : ''} · ${units} day${units === 1 ? '' : 's'}${input.reason ? ` · ${input.reason}` : ''}`,
        attributes: { requireHr: !!(policy.requireHrApproval || org.settings?.leave?.approvalByHr), leaveTypeId: String(type._id), units },
        link: '/time/leave',
      });
      await this.requests.updateOne({ _id: req._id }, { $set: { approvalId: approval._id } });
    } catch (e) {
      await this.release(req._id, 'cancelled');
      throw e;
    }
    await this.audit.record(ctx, { action: 'leave.apply', resourceType: 'leave_request', resourceId: req._id, changes: { units: { from: null, to: units }, dates: { from: null, to: `${input.startDate}..${input.endDate}` } } });
    return { ...serialize(await this.requests.findById(req._id).lean()), days };
  }

  /** Approval effects: reserve -> used, attendance marked on_leave, employee notified. Idempotent. */
  private async onApproved(requestId: Types.ObjectId, orgId: Types.ObjectId): Promise<void> {
    const r = await this.requests.findOne({ _id: requestId, organizationId: orgId }).lean<any>();
    if (!r) return;
    const year = Number(r.startDate.slice(0, 4));
    await this.move(orgId, r.employeeId, r.leaveTypeId, year, 'pending', -r.units, `req:${r._id}:unreserve`, { requestId: r._id });
    await this.move(orgId, r.employeeId, r.leaveTypeId, year, 'used', r.units, `req:${r._id}:use`, { requestId: r._id });
    await this.requests.updateOne({ _id: r._id }, { $set: { status: 'approved', decidedAt: new Date() } });
    const emp = await this.employees.findById(r.employeeId).lean<any>();
    const { days } = await this.countUnits(orgId, emp, r.startDate, r.endDate, r.partialDay);
    if (r.partialDay === 'none') await this.attendance.markLeave(orgId, r.employeeId, days, r._id);
    const user = await this.users.findOne({ organizationId: orgId, employeeId: r.employeeId }, { _id: 1 }).lean<any>();
    if (user) await this.notifications.notify(orgId, [user._id], { event: 'leave_decided', title: 'Leave approved', body: `${r.startDate}${r.endDate !== r.startDate ? ` to ${r.endDate}` : ''} (${r.units} day${r.units === 1 ? '' : 's'})`, link: '/time/leave' });
  }

  private async release(requestId: Types.ObjectId, status: 'rejected' | 'cancelled', comment?: string): Promise<void> {
    const r = await this.requests.findById(requestId).lean<any>();
    if (!r) return;
    const year = Number(r.startDate.slice(0, 4));
    await this.move(r.organizationId, r.employeeId, r.leaveTypeId, year, 'pending', -r.units, `req:${r._id}:unreserve`, { requestId: r._id });
    await this.requests.updateOne({ _id: r._id }, { $set: { status, decisionComment: comment, decidedAt: new Date() } });
    if (status === 'rejected') {
      const user = await this.users.findOne({ organizationId: r.organizationId, employeeId: r.employeeId }, { _id: 1 }).lean<any>();
      if (user) await this.notifications.notify(r.organizationId, [user._id], { event: 'leave_decided', title: 'Leave not approved', body: comment ?? `${r.startDate} to ${r.endDate}`, link: '/time/leave' });
    }
  }

  /** Employee cancels: pending -> withdraw approval; approved future leave -> give the days back. */
  async cancel(ctx: Ctx, id: string): Promise<any> {
    const r = await this.requests.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!r) throw notFound('Leave request');
    const own = String(r.employeeId) === ctx.user.employeeId;
    if (!own && !(await this.scope.covers(ctx, 'leave', 'manage', r.employeeId))) throw notFound('Leave request');
    if (['pending', 'clarification'].includes(r.status)) {
      await this.approvals.cancel(ctx, 'leave', r._id);
    } else if (r.status === 'approved') {
      const org = await this.orgSettings.get(ctx.orgOid);
      const today = localParts(new Date(), org.timezone).day;
      if (r.startDate <= today && !ctx.authz.can('leave', 'manage')) throw forbidden('LEAVE_STARTED', 'Leave that has started can only be changed by HR.');
      const year = Number(r.startDate.slice(0, 4));
      await this.move(ctx.orgOid, r.employeeId, r.leaveTypeId, year, 'used', -r.units, `req:${r._id}:return`, { requestId: r._id, byUserId: ctx.userOid });
      await this.requests.updateOne({ _id: r._id }, { $set: { status: 'cancelled', decidedAt: new Date() } });
      await this.attendance.unmarkLeave(ctx.orgOid, r._id);
    } else {
      throw conflict('LEAVE_CLOSED', `This request is already ${r.status}.`);
    }
    await this.audit.record(ctx, { action: 'leave.cancel', resourceType: 'leave_request', resourceId: id, changes: { status: { from: r.status, to: 'cancelled' } } });
    return serialize(await this.requests.findById(r._id).lean());
  }

  // ------------------------------------------------------------------ lists and calendars

  async list(ctx: Ctx, q: { mine?: boolean; employeeId?: string; status?: string; from?: string; to?: string; page: number; limit: number }): Promise<Paged<any>> {
    const filter: Record<string, any> = q.mine ? { organizationId: ctx.orgOid, employeeId: ctx.employeeOid ?? null } : await this.scope.filter(ctx, 'leave', 'view');
    if (q.employeeId) {
      await this.scope.requireCovers(ctx, 'leave', 'view', q.employeeId);
      filter.employeeId = oid(q.employeeId);
    }
    if (q.status) filter.status = q.status;
    if (q.from) filter.endDate = { $gte: q.from };
    if (q.to) filter.startDate = { $lte: q.to };
    const [rows, total] = await Promise.all([this.requests.find(filter).sort({ startDate: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.requests.countDocuments(filter)]);
    return { items: await this.decorate(rows), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  private async decorate(rows: any[]): Promise<any[]> {
    const [emps, types] = await Promise.all([
      this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1, photoFileId: 1 }).lean<any[]>(),
      this.types.find({ _id: { $in: rows.map((r) => r.leaveTypeId) } }, { name: 1, code: 1, color: 1 }).lean<any[]>(),
    ]);
    const e = new Map(emps.map((x) => [String(x._id), x]));
    const t = new Map(types.map((x) => [String(x._id), x]));
    return serialize(rows).map((r: any) => ({
      ...r,
      employeeName: e.has(r.employeeId) ? `${e.get(r.employeeId).firstName} ${e.get(r.employeeId).lastName ?? ''}`.trim() : null,
      leaveType: t.has(r.leaveTypeId) ? { code: t.get(r.leaveTypeId).code, name: t.get(r.leaveTypeId).name, color: t.get(r.leaveTypeId).color } : null,
    }));
  }

  /** Team leave calendar (approved and pending) within the caller's scope. */
  async calendar(ctx: Ctx, from: string, to: string): Promise<any[]> {
    const filter = await this.scope.filter(ctx, 'leave', 'view');
    filter.status = { $in: ['approved', 'pending'] };
    filter.startDate = { $lte: to };
    filter.endDate = { $gte: from };
    return this.decorate(await this.requests.find(filter).sort({ startDate: 1 }).limit(500).lean<any[]>());
  }

  // ------------------------------------------------------------------ configuration

  async listTypes(ctx: Ctx): Promise<any[]> {
    return serialize(await this.types.find({ organizationId: ctx.orgOid }).sort({ code: 1 }).lean());
  }

  async upsertType(ctx: Ctx, b: z.infer<typeof leaveTypeInput>, id?: string): Promise<any> {
    PermissionsService.require(ctx, 'leave', 'manage', 'organization');
    const doc = { ...b, code: b.code.toUpperCase() };
    if (id) {
      const r = await this.types.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: doc });
      if (!r.matchedCount) throw notFound('Leave type');
    } else {
      if (await this.types.exists({ organizationId: ctx.orgOid, code: doc.code })) throw conflict('CODE_TAKEN', `Code ${doc.code} is already used.`);
      id = String((await this.types.create({ ...doc, organizationId: ctx.orgOid }))._id);
    }
    await this.audit.record(ctx, { action: 'leave.type_save', resourceType: 'leave_type', resourceId: id });
    return serialize(await this.types.findById(id).lean());
  }

  async listPolicies(ctx: Ctx): Promise<any[]> {
    return serialize(await this.policies.find({ organizationId: ctx.orgOid }).sort({ name: 1 }).lean());
  }

  async upsertPolicy(ctx: Ctx, b: z.infer<typeof policyInput>, id?: string): Promise<any> {
    PermissionsService.require(ctx, 'leave', 'manage', 'organization');
    const doc = { ...b, leaveTypeId: oid(b.leaveTypeId), appliesTo: { ...b.appliesTo, departmentIds: b.appliesTo.departmentIds?.map(oid), locationIds: b.appliesTo.locationIds?.map(oid) } };
    if (id) {
      const r = await this.policies.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: doc });
      if (!r.matchedCount) throw notFound('Policy');
    } else {
      id = String((await this.policies.create({ ...doc, organizationId: ctx.orgOid }))._id);
    }
    await this.audit.record(ctx, { action: 'leave.policy_save', resourceType: 'leave_policy', resourceId: id });
    return serialize(await this.policies.findById(id).lean());
  }

  /** January 1st: carry forward unused balance up to each policy's limit. Keyed, so it runs once per year. */
  @Cron('30 0 1 1 *')
  async carryForward(): Promise<void> {
    await this.jobs.run('leave.carry_forward', async () => {
      const year = new Date().getUTCFullYear();
      const prev = await this.balances.find({ year: year - 1 }).lean<any[]>();
      let n = 0;
      for (const b of prev) {
        const emp = await this.employees.findById(b.employeeId).lean<any>();
        if (!emp || ['exited', 'archived'].includes(emp.status)) continue;
        const policy = await this.policyFor(b.organizationId, emp, b.leaveTypeId);
        if (!policy?.carryForwardMax) continue;
        const left = Math.max(0, b.entitled + b.carriedForward + b.adjusted - b.used - b.pending);
        const carry = Math.min(left, policy.carryForwardMax);
        if (!carry) continue;
        await this.ensureBalance(b.organizationId, emp, b.leaveTypeId, year);
        if (await this.move(b.organizationId, b.employeeId, b.leaveTypeId, year, 'carriedForward', carry, `cf:${b.employeeId}:${b.leaveTypeId}:${year}`)) n++;
      }
      return `${n} carried forward`;
    });
  }
}
